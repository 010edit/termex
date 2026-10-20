use std::sync::Arc;

use chrono::Utc;
use termex_core::ssh::auth;
use termex_core::ssh::channel::ChannelCommand;
use termex_core::ssh::host_key::{self, HostKeyVerifyResult};
use termex_core::ssh::session::SshSession;
use termex_core::storage::models::AuthType;

use crate::api::local_pty;
use crate::frb_ssh_emitter::{self, FrbSshEmitter, SshStreamEvent};
use crate::session_registry;

/// Minimal server row used for establishing a connection. Pulled directly
/// from the `servers` table without passing through `ServerDto` (which
/// omits credential paths on the serialization boundary).
struct ConnectRow {
    host: String,
    port: i32,
    username: String,
    auth_type: String,
    key_path: Option<String>,
}

fn load_connect_row(server_id: &str) -> Result<ConnectRow, String> {
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.query_row(
                "SELECT host, port, username, auth_type, key_path
                 FROM servers WHERE id = ?1",
                rusqlite::params![server_id],
                |row| {
                    Ok(ConnectRow {
                        host: row.get(0)?,
                        port: row.get(1)?,
                        username: row.get(2)?,
                        auth_type: row.get(3)?,
                        key_path: row.get(4)?,
                    })
                },
            )
        })
        .map_err(|e| e.to_string())
    })
}

/// Touches the `last_connected` column on success. Errors are swallowed —
/// a connected session is more important than a bookkeeping write.
fn mark_last_connected(server_id: &str) {
    let now = Utc::now().to_rfc3339();
    let _ = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "UPDATE servers SET last_connected = ?1, updated_at = ?1 WHERE id = ?2",
                rusqlite::params![now, server_id],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    });
}

async fn connect_direct(
    server_id: &str,
    row: &ConnectRow,
    emitter: Arc<FrbSshEmitter>,
    cols: u32,
    rows: u32,
    session_id: &str,
) -> Result<SshSession, String> {
    let mut session = SshSession::connect(&row.host, row.port as u16)
        .await
        .map_err(|e| e.to_string())?;

    // TOFU host key verification: only reject on an outright key change.
    // NewHost is silently trusted (matches legacy Tauri behaviour), and any
    // DB error degrades to "trust this time" rather than blocking connect.
    if let Some(pubkey) = session.captured_host_key() {
        let verify: HostKeyVerifyResult = crate::db_state::with_db(|db| {
            Ok(host_key::verify_host_key(db, &row.host, row.port as u16, &pubkey))
        })?;
        match verify {
            HostKeyVerifyResult::Trusted => {}
            HostKeyVerifyResult::NewHost { .. } => {
                let _ = crate::db_state::with_db(|db| {
                    host_key::trust_host_key(db, &row.host, row.port as u16, &pubkey)
                        .map_err(|e| e.to_string())
                });
            }
            HostKeyVerifyResult::KeyChanged { .. } => {
                let _ = session.disconnect().await;
                return Err(
                    "host key changed since last connection; aborting for safety".into(),
                );
            }
        }
    }

    // Authenticate.
    let auth_ty = AuthType::from_str(&row.auth_type)
        .ok_or_else(|| format!("unknown auth_type: {}", row.auth_type))?;
    match auth_ty {
        AuthType::Password => {
            let password = termex_core::keychain::get(
                &termex_core::keychain::ssh_password_key(server_id),
            )
            .map_err(|e| format!("failed to read keychain password: {e}"))?;
            auth::auth_password(session.handle_mut(), &row.username, &password)
                .await
                .map_err(|e| e.to_string())?;
        }
        AuthType::Key => {
            let key_path = row
                .key_path
                .as_deref()
                .ok_or_else(|| "auth_type=key but key_path is empty".to_string())?;
            let key_data = std::fs::read_to_string(key_path)
                .map_err(|e| format!("failed to read key file {key_path}: {e}"))?;
            let passphrase = termex_core::keychain::get(
                &termex_core::keychain::ssh_passphrase_key(server_id),
            )
            .ok();
            auth::auth_key_data(
                session.handle_mut(),
                &row.username,
                &key_data,
                passphrase.as_deref(),
            )
            .await
            .map_err(|e| e.to_string())?;
        }
    }

    session
        .open_shell(emitter, session_id.to_string(), cols, rows)
        .await
        .map_err(|e| e.to_string())?;

    Ok(session)
}

/// Opens an SSH session and starts streaming terminal events to a
/// per-session queue that Dart polls via `poll_ssh_events`.
///
/// Scope (v0.50.x): direct TCP connection + password or key auth against
/// the server's stored credentials. Chain-through-bastion and network
/// proxies are not yet wired into this session path; the CRUD surface lives
/// in `api/chain.rs` / `api/proxy.rs`, and `docs/tech-debt.md` T-9 tracks
/// the remaining work.
pub async fn open_ssh_session(
    server_id: String,
    cols: u32,
    rows: u32,
) -> Result<String, String> {
    let session_id = uuid::Uuid::new_v4().to_string();
    frb_ssh_emitter::register_session(session_id.clone());

    let row = match load_connect_row(&server_id) {
        Ok(r) => r,
        Err(e) => {
            frb_ssh_emitter::unregister_session(&session_id);
            return Err(e);
        }
    };

    let emitter = Arc::new(FrbSshEmitter);
    let session = match connect_direct(&server_id, &row, emitter, cols, rows, &session_id).await {
        Ok(s) => s,
        Err(e) => {
            frb_ssh_emitter::unregister_session(&session_id);
            return Err(e);
        }
    };

    let cmd_tx = session
        .channel_cmd_tx()
        .ok_or_else(|| "shell channel opened without command sender".to_string())?;

    session_registry::insert(session_id.clone(), cmd_tx, session);
    mark_last_connected(&server_id);
    maybe_auto_record(&session_id, &server_id, cols, rows).await;

    Ok(session_id)
}

/// Starts a recording immediately when the server is flagged for it.
///
/// Per-server rather than a global preference, matching the legacy Tauri
/// build: `servers.auto_record` arms it and
/// `servers.max_recording_mb` caps the file. Best-effort — a server that
/// connects but cannot be recorded is still a usable session, so failures
/// here never fail the connect.
async fn maybe_auto_record(session_id: &str, server_id: &str, cols: u32, rows: u32) {
    if !crate::db_state::is_unlocked() {
        return;
    }

    let info: Option<(bool, u32, String)> = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.query_row(
                "SELECT COALESCE(auto_record, 0),
                        COALESCE(max_recording_mb, 50),
                        COALESCE(name, '')
                   FROM servers WHERE id = ?1",
                rusqlite::params![server_id],
                |r| {
                    Ok((
                        r.get::<_, i32>(0)? != 0,
                        r.get::<_, u32>(1)?,
                        r.get::<_, String>(2)?,
                    ))
                },
            )
        })
        .map_err(|e| e.to_string())
    })
    .ok();

    let Some((true, max_mb, name)) = info else {
        return;
    };
    let server_name = if name.is_empty() {
        server_id.to_string()
    } else {
        name
    };

    let _ = crate::api::recording::recording_start(
        session_id.to_string(),
        server_id.to_string(),
        server_name.clone(),
        cols,
        rows,
        Some(format!("Auto: {server_name}")),
        max_mb,
        true,
        // Auto-record starts with the shell, so there is nothing on screen yet.
        None,
    )
    .await;
}

/// Drains pending events for a session. Called by the Dart polling task.
pub fn poll_ssh_events(session_id: String) -> Vec<SshStreamEvent> {
    frb_ssh_emitter::drain(&session_id)
}

/// Sends raw bytes to the shell stdin. Handles both SSH and local PTY sessions.
pub fn write_stdin(session_id: String, data: Vec<u8>) -> Result<(), String> {
    if local_pty::is_local_session(&session_id) {
        return local_pty::write_stdin(&session_id, data);
    }
    session_registry::send(&session_id, ChannelCommand::Write(data))
}

/// Resizes the pseudo-terminal. Handles both SSH and local PTY sessions.
pub fn resize_terminal(session_id: String, cols: u32, rows: u32) -> Result<(), String> {
    if local_pty::is_local_session(&session_id) {
        return local_pty::resize(&session_id, cols, rows);
    }
    session_registry::send(&session_id, ChannelCommand::Resize(cols, rows))
}

/// Closes a session. Handles both SSH and local PTY sessions.
pub async fn close_ssh_session(session_id: String) -> Result<(), String> {
    if local_pty::is_local_session(&session_id) {
        local_pty::close(&session_id);
        return Ok(());
    }

    // Signal the channel task to exit. Errors are tolerated: the session
    // may have already died on the server side.
    let _ = session_registry::send(&session_id, ChannelCommand::Close);

    // Close any open SFTP subsystem first.
    session_registry::close_sftp(&session_id).await;

    // Gracefully disconnect the russh client, dropping the task.
    if let Some(session) = session_registry::take_session(&session_id).await {
        let _ = session.disconnect().await;
    }

    session_registry::remove(&session_id);
    frb_ssh_emitter::unregister_session(&session_id);
    Ok(())
}

/// Checks whether an SSH agent is available by inspecting `SSH_AUTH_SOCK`.
pub fn check_ssh_agent_available() -> Result<bool, String> {
    let sock = std::env::var("SSH_AUTH_SOCK").unwrap_or_default();
    if sock.is_empty() {
        return Ok(false);
    }
    Ok(std::path::Path::new(&sock).exists())
}

/// Parameters for a transient SSH connection test. Mirrors the add-server
/// form fields so the user can verify credentials before persisting the
/// row to the database.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshConnectionTestParams {
    pub host: String,
    pub port: i32,
    pub username: String,
    pub auth_type: String,
    pub password: Option<String>,
    /// Path to an on-disk private key file. Used when `key_data` is empty.
    pub key_path: Option<String>,
    /// Raw private key contents. Takes precedence over `key_path` when set —
    /// lets the dialog test a pasted key without writing it to disk first.
    pub key_data: Option<String>,
    pub key_passphrase: Option<String>,
    /// v0.79.66: id of the server being edited, if any. When the test
    /// is fired from the Edit-Server dialog and the password / passphrase
    /// fields are left blank (because we never seed them from the OS
    /// keychain into a UI text field — security rule), we fall back to
    /// reading the stored credential from the keychain by this id. Saves
    /// the user from having to re-type their password just to run the
    /// test. None means "create flow" — no keychain fallback.
    pub existing_server_id: Option<String>,
}

/// Runs a full TCP + SSH handshake + auth against a transient set of
/// connection params and disconnects. Returns `Ok(())` on success, or the
/// underlying error message. Nothing is written to DB or keychain — used by
/// the add/edit server dialog to verify credentials before persisting.
pub async fn test_ssh_connection(
    params: SshConnectionTestParams,
) -> Result<(), String> {
    if params.host.trim().is_empty() {
        return Err("host is empty".into());
    }
    if params.username.trim().is_empty() {
        return Err("username is empty".into());
    }
    if params.port < 1 || params.port > 65535 {
        return Err(format!("port out of range: {}", params.port));
    }

    let auth_ty = AuthType::from_str(&params.auth_type).ok_or_else(|| {
        format!("auth type not supported for test: {}", params.auth_type)
    })?;

    let mut session = SshSession::connect(&params.host, params.port as u16)
        .await
        .map_err(|e| e.to_string())?;

    let auth_result: Result<(), String> = match auth_ty {
        AuthType::Password => {
            // v0.79.66: prefer the typed password; if blank AND we're
            // testing an existing server, fall back to the OS-keychain
            // record. Fixes the "edit dialog → test → password rejected"
            // path where the dialog never seeds the password text field
            // from keychain (by design — secrets stay out of the UI).
            let typed = params.password.as_deref().unwrap_or("");
            let pwd = if !typed.is_empty() {
                typed.to_string()
            } else if let Some(server_id) = params.existing_server_id.as_deref() {
                termex_core::keychain::get(
                    &termex_core::keychain::ssh_password_key(server_id),
                )
                .map_err(|e| {
                    format!("failed to read keychain password: {e}")
                })?
            } else {
                String::new()
            };
            auth::auth_password(session.handle_mut(), &params.username, &pwd)
                .await
                .map_err(|e| e.to_string())
        }
        AuthType::Key => {
            let pasted = params
                .key_data
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty());
            let key_data = match pasted {
                Some(data) => data.to_string(),
                None => {
                    let path = params
                        .key_path
                        .as_deref()
                        .map(str::trim)
                        .filter(|p| !p.is_empty())
                        .ok_or_else(|| {
                            "private key content or path is required".to_string()
                        })?;
                    std::fs::read_to_string(path).map_err(|e| {
                        format!("failed to read key file {path}: {e}")
                    })?
                }
            };
            // v0.79.66: same fallback for the key passphrase.
            let typed_pp = params.key_passphrase.as_deref().unwrap_or("");
            let passphrase: Option<String> = if !typed_pp.is_empty() {
                Some(typed_pp.to_string())
            } else if let Some(server_id) = params.existing_server_id.as_deref() {
                termex_core::keychain::get(
                    &termex_core::keychain::ssh_passphrase_key(server_id),
                )
                .ok()
                .filter(|s| !s.is_empty())
            } else {
                None
            };
            auth::auth_key_data(
                session.handle_mut(),
                &params.username,
                &key_data,
                passphrase.as_deref(),
            )
            .await
            .map_err(|e| e.to_string())
        }
    };

    // Always disconnect, even on auth failure.
    let _ = session.disconnect().await;
    auth_result
}

/// Opens a new session to the same server as an existing session.
///
/// v0.50.x: re-resolves the server from its last-connected record. True
/// channel multiplexing over a shared russh handle is tracked in tech
/// debt T-9.
pub async fn open_ssh_session_clone(
    existing_session_id: String,
    cols: u32,
    rows: u32,
) -> Result<String, String> {
    let server_id = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.query_row::<String, _, _>(
                "SELECT id FROM servers
                 WHERE last_connected IS NOT NULL
                 ORDER BY last_connected DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
        })
        .map_err(|e| e.to_string())
    })
    .map_err(|e| format!("clone: unable to resolve source server ({existing_session_id}): {e}"))?;

    open_ssh_session(server_id, cols, rows).await
}

/// Checks the host-key status for a connection by querying the `known_hosts` table.
///
/// Returns one of:
/// - `"trusted"` — fingerprint matches the stored record.
/// - `"new:{fingerprint}"` — host not yet in the database.
/// - `"changed:{old_fingerprint}:{new_fingerprint}"` — host known but fingerprint differs.
pub fn check_host_key(
    host: String,
    port: u16,
    fingerprint: String,
    key_type: String,
) -> Result<String, String> {
    let _ = key_type; // key_type not used in the lookup; stored when trusting
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            let result: rusqlite::Result<(String, String)> = conn.query_row(
                "SELECT fingerprint, key_type FROM known_hosts WHERE host = ?1 AND port = ?2",
                rusqlite::params![host, port as i32],
                |row| Ok((row.get(0)?, row.get(1)?)),
            );
            match result {
                Ok((stored_fp, _stored_type)) => {
                    if stored_fp == fingerprint {
                        Ok("trusted".into())
                    } else {
                        Ok(format!("changed:{}:{}", stored_fp, fingerprint))
                    }
                }
                Err(rusqlite::Error::QueryReturnedNoRows) => {
                    Ok(format!("new:{}", fingerprint))
                }
                Err(e) => Err(e),
            }
        })
        .map_err(|e| e.to_string())
    })
}

/// Stores an SSH key passphrase in the OS keychain for [server_id]. Used by
/// the Flutter passphrase prompt (P2.3) so encrypted private keys can be
/// unlocked at connect time without requiring the user to re-enter the
/// secret on each reconnect. An empty value deletes the stored entry.
pub fn ssh_store_passphrase(server_id: String, passphrase: String) -> Result<(), String> {
    let key = termex_core::keychain::ssh_passphrase_key(&server_id);
    if passphrase.is_empty() {
        let _ = termex_core::keychain::delete(&key);
        return Ok(());
    }
    termex_core::keychain::store(&key, &passphrase)
        .map_err(|e| format!("failed to store passphrase: {e}"))
}

/// Returns true if a key passphrase is currently stored in the keychain for
/// [server_id]. The value itself is never returned across the bridge.
pub fn ssh_has_passphrase(server_id: String) -> bool {
    let key = termex_core::keychain::ssh_passphrase_key(&server_id);
    termex_core::keychain::get(&key).is_ok()
}

/// Adds or updates a host-key entry in the `known_hosts` table.
///
/// Uses `INSERT OR REPLACE` to handle both new hosts and key rotation while
/// preserving the original `first_seen` timestamp.
pub fn trust_host_key(
    host: String,
    port: u16,
    fingerprint: String,
    key_type: String,
) -> Result<(), String> {
    let now = Utc::now().to_rfc3339();
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO known_hosts
                    (host, port, key_type, fingerprint, first_seen, last_seen)
                 VALUES (
                     ?1, ?2, ?3, ?4,
                     COALESCE(
                         (SELECT first_seen FROM known_hosts WHERE host = ?1 AND port = ?2),
                         ?5
                     ),
                     ?5
                 )",
                rusqlite::params![host, port as i32, key_type, fingerprint, now],
            )?;
            Ok(())
        })
        .map_err(|e| e.to_string())
    })
}

// ─── Session pool stats (v0.68.0 G2) ─────────────────────────────────────────

/// Snapshot of one entry in the proxy session pool. Surfaces via the debug
/// panel in `about_tab.dart` so users can verify reuse of upstream
/// connections when multiple servers share the same proxy/jump host.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyPoolStat {
    /// One of `"socks5"` / `"socks4"` / `"http"` / `"tor"` / `"ssh-jump"`.
    pub proxy_type: String,
    pub host: String,
    pub port: u16,
    pub username: Option<String>,
    pub ref_count: i32,
    /// Unix epoch seconds when the underlying TCP connection was opened.
    pub connected_since: i64,
    pub bytes_transferred: i64,
}

/// Returns every active entry in the global proxy session pool. Cheap
/// `RwLock<HashMap>` read; safe to poll at high frequency.
pub async fn session_pool_stats() -> Result<Vec<ProxyPoolStat>, String> {
    let pool = crate::session_pool_singleton::pool();
    let rows = pool.stats().await;
    Ok(rows
        .into_iter()
        .map(|s| ProxyPoolStat {
            proxy_type: s.proxy_type,
            host: s.host,
            port: s.port,
            username: s.username,
            ref_count: s.ref_count as i32,
            connected_since: s.connected_since,
            bytes_transferred: s.bytes_transferred as i64,
        })
        .collect())
}


// ─── Chain progress events (v0.68.0 G3) ──────────────────────────────────────

pub use crate::frb_chain_emitter::ChainProgressDto;

/// Drains queued chain-progress events for [session_id]. Polls return any
/// events accumulated since the last call; Flutter calls this on the same
/// timer that already drains `poll_ssh_events`.
pub fn poll_chain_progress(session_id: String) -> Vec<ChainProgressDto> {
    crate::frb_chain_emitter::drain(&session_id)
}

/// HopConfig surfaced to Dart — mirrors `termex_core::ssh::chain::HopConfig`
/// but lives here to dodge the FRB orphan-rule restriction on foreign types.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChainHopInfo {
    pub hop_id: String,
    pub name: String,
    pub host: String,
    pub port: u16,
}

/// Runs the chain algorithm against an in-memory fake connector that
/// scripts hop outcomes via [hop_failures] — entry `i` is the number of
/// transient failures the i-th hop simulates before succeeding (capped by
/// `max_retries_per_hop = 3`; values higher than 3 cause that hop to
/// permanently fail). Used by the v0.69+ integration tests and the
/// Flutter reconnect-banner demo path; lets the UI exercise the full
/// progress event stream without a real bastion.
pub async fn chain_connect_simulate(
    session_id: String,
    hops: Vec<ChainHopInfo>,
    hop_failures: Vec<i32>,
    backoff_base_ms: u64,
    backoff_max_ms: u64,
) -> Result<(), String> {
    use termex_core::ssh::chain::{
        chain_connect_with, ChainConnectConfig, HopConfig, HopSession,
    };

    crate::frb_chain_emitter::register(session_id.clone());
    let core_hops = hops
        .into_iter()
        .map(|h| HopConfig {
            hop_id: h.hop_id,
            name: h.name,
            host: h.host,
            port: h.port,
        })
        .collect();
    let mut cfg = ChainConnectConfig::new(core_hops);
    cfg.backoff_base_ms = backoff_base_ms.max(1);
    cfg.backoff_max_ms = backoff_max_ms.max(cfg.backoff_base_ms);

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
    let bridge_sid = session_id.clone();
    let pump = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            let dto = crate::frb_chain_emitter::ChainProgressDto::from_progress(event);
            crate::frb_chain_emitter::enqueue(&bridge_sid, dto);
        }
    });

    struct NoopHop;
    impl HopSession for NoopHop {
        fn close_boxed(self: Box<Self>) {}
    }

    let failure_budget = std::sync::Arc::new(hop_failures);
    let result = chain_connect_with(
        &cfg,
        move |hop, attempt| {
            let budget = failure_budget.clone();
            let host = hop.host.clone();
            let idx = budget
                .iter()
                .enumerate()
                .find_map(|(i, _)| if host == format!("h{i}") { Some(i) } else { None });
            async move {
                let should_fail = match idx {
                    Some(i) => attempt < budget[i] as u32,
                    None => false,
                };
                if should_fail {
                    Err(format!("simulated failure attempt {attempt}"))
                } else {
                    Ok(Box::new(NoopHop) as Box<dyn HopSession>)
                }
            }
        },
        tx,
    )
    .await
    .map(|_| ());

    // Drain the pump so all events land in the queue before we return.
    pump.await.ok();
    result
}
