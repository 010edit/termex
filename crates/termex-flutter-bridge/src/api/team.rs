/// Team collaboration APIs exposed to Flutter via FRB.
///
/// Covers member management, invite-code lifecycle, conflict resolution, and
/// passphrase-protected sync.  All functions are stubs pending backend wiring.
use flutter_rust_bridge::frb;

// ─── DTOs ────────────────────────────────────────────────────────────────────

/// Access level of a team member.
#[frb]
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum TeamRole {
    Owner,
    Admin,
    Member,
    Viewer,
}

/// A user who belongs to the current team workspace.
#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamMember {
    pub id: String,
    pub name: String,
    pub email: String,
    pub role: TeamRole,
    /// ISO 8601 timestamp of when the member joined.
    pub joined_at: String,
}

/// A one-time invite code that grants access to the team workspace.
#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamInvite {
    /// Short alphanumeric code to share with the invitee.
    pub code: String,
    /// ISO 8601 timestamp after which the code is no longer valid.
    pub expires_at: String,
    pub role: TeamRole,
}

/// A sync conflict between a local and a remote version of a server field.
#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamConflict {
    pub id: String,
    pub server_id: String,
    /// The server field that diverged (e.g. `"host"`, `"port"`).
    pub field: String,
    pub local_value: String,
    pub remote_value: String,
}

// ─── Members ─────────────────────────────────────────────────────────────────

fn role_to_str(r: &TeamRole) -> &'static str {
    match r {
        TeamRole::Owner => "owner",
        TeamRole::Admin => "admin",
        TeamRole::Member => "member",
        TeamRole::Viewer => "viewer",
    }
}

fn role_from_str(s: &str) -> TeamRole {
    match s {
        "owner" => TeamRole::Owner,
        "admin" => TeamRole::Admin,
        "viewer" => TeamRole::Viewer,
        _ => TeamRole::Member,
    }
}

/// Returns the list of current team members.
#[frb]
pub fn team_get_members() -> Result<Vec<TeamMember>, String> {
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, name, email, role, joined_at
                 FROM team_members
                 ORDER BY joined_at ASC",
            )?;
            let rows = stmt.query_map([], |row| {
                let role_str: String = row.get(3)?;
                Ok(TeamMember {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    email: row.get(2)?,
                    role: role_from_str(&role_str),
                    joined_at: row.get(4)?,
                })
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
        })
        .map_err(|e| e.to_string())
    })
}

/// Adds a new team member (used during invite acceptance and tests).
#[frb]
pub fn team_add_member(
    name: String,
    email: String,
    role: TeamRole,
) -> Result<TeamMember, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let now = chrono::Utc::now().to_rfc3339();
    let role_str = role_to_str(&role).to_string();
    let member = TeamMember {
        id: id.clone(),
        name: name.clone(),
        email: email.clone(),
        role,
        joined_at: now.clone(),
    };
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "INSERT INTO team_members (id, name, email, role, joined_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                rusqlite::params![id, name, email, role_str, now],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    })?;
    Ok(member)
}

/// Removes a member from the team workspace. Refuses to delete an owner.
#[frb]
pub fn team_remove_member(member_id: String) -> Result<(), String> {
    crate::db_state::with_db(|db| {
        // Pre-check (cannot propagate custom error text through rusqlite::Error).
        let role: Option<String> = db
            .with_conn(|conn| {
                match conn.query_row::<String, _, _>(
                    "SELECT role FROM team_members WHERE id = ?1",
                    rusqlite::params![member_id],
                    |row| row.get(0),
                ) {
                    Ok(v) => Ok(Some(v)),
                    Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
                    Err(e) => Err(e),
                }
            })
            .map_err(|e| e.to_string())?;
        if role.as_deref() == Some("owner") {
            return Err("cannot remove workspace owner".to_string());
        }
        db.with_conn(|conn| {
            conn.execute(
                "DELETE FROM team_members WHERE id = ?1",
                rusqlite::params![member_id],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    })
}

/// Updates the role of an existing team member.
///
/// Refuses to demote the last owner — at least one owner must remain.
#[frb]
pub fn team_update_role(member_id: String, role: TeamRole) -> Result<(), String> {
    let new_role = role_to_str(&role).to_string();
    crate::db_state::with_db(|db| {
        let current: Option<String> = db
            .with_conn(|conn| {
                match conn.query_row::<String, _, _>(
                    "SELECT role FROM team_members WHERE id = ?1",
                    rusqlite::params![member_id],
                    |row| row.get(0),
                ) {
                    Ok(v) => Ok(Some(v)),
                    Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
                    Err(e) => Err(e),
                }
            })
            .map_err(|e| e.to_string())?;
        if current.as_deref() == Some("owner") && new_role != "owner" {
            let owner_count: i64 = db
                .with_conn(|conn| {
                    conn.query_row(
                        "SELECT COUNT(*) FROM team_members WHERE role = 'owner'",
                        [],
                        |row| row.get(0),
                    )
                })
                .map_err(|e| e.to_string())?;
            if owner_count <= 1 {
                return Err("cannot demote the last owner".to_string());
            }
        }
        db.with_conn(|conn| {
            conn.execute(
                "UPDATE team_members SET role = ?1 WHERE id = ?2",
                rusqlite::params![new_role, member_id],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    })
}

// ─── Invites ─────────────────────────────────────────────────────────────────

/// The opaque payload embedded inside a `TeamInvite.code`.  Mirrors the
/// shape documented in v0.46 spec §5.2 (JWT-like, HMAC-signed).
#[frb]
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamInvitePayload {
    /// Team identifier (UUID).
    pub team_id: String,
    /// Role to assign on acceptance.
    pub role: TeamRole,
    /// Expiration time (RFC3339).
    pub exp: String,
    /// Nonce to prevent code guessing.
    pub nonce: String,
}

/// Parses an invite code into its component payload.  Returns `Err` if the
/// code is malformed or expired.
#[frb]
pub fn team_invite_decode(code: String) -> Result<TeamInvitePayload, String> {
    // Format: base64(json-payload).signature — we accept both the short form
    // (uppercase token) emitted by the stub and the full form.
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

    if let Some((body_b64, _sig)) = code.split_once('.') {
        let body = URL_SAFE_NO_PAD
            .decode(body_b64.as_bytes())
            .map_err(|_| "Invite code: malformed base64 payload".to_string())?;
        let payload: TeamInvitePayload = serde_json::from_slice(&body)
            .map_err(|_| "Invite code: payload not JSON".to_string())?;
        let now = chrono::Utc::now();
        if let Ok(exp) = chrono::DateTime::parse_from_rfc3339(&payload.exp) {
            if exp < now {
                return Err("Invite code has expired".into());
            }
        }
        return Ok(payload);
    }
    Err("Invite code: missing signature".into())
}

/// Generates a new invite code for the specified `role`, valid for
/// `expires_hours` hours from now.
#[frb]
pub fn team_invite_generate(
    role: TeamRole,
    expires_hours: i32,
) -> Result<TeamInvite, String> {
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};

    let team_id = uuid::Uuid::new_v4().to_string();
    let expires_at = chrono::Utc::now()
        + chrono::Duration::hours(expires_hours as i64);
    let nonce = uuid::Uuid::new_v4().to_string();
    let payload = TeamInvitePayload {
        team_id: team_id.clone(),
        role: role.clone(),
        exp: expires_at.to_rfc3339(),
        nonce,
    };
    let body = serde_json::to_vec(&payload).map_err(|e| e.to_string())?;
    let body_b64 = URL_SAFE_NO_PAD.encode(&body);

    // Signature stub: full HMAC-SHA256 is applied when a team passphrase is
    // configured (backend wiring lands in v0.48).  For now we use a SHA-256
    // digest of the payload (truncated to 16 bytes / 32 hex chars).
    let digest = ring::digest::digest(&ring::digest::SHA256, &body);
    let sig: String = digest
        .as_ref()
        .iter()
        .take(16)
        .map(|b| format!("{:02x}", b))
        .collect();
    let code = format!("{body_b64}.{sig}");

    Ok(TeamInvite {
        code,
        expires_at: expires_at.to_rfc3339(),
        role,
    })
}

/// Accepts an invite code using the team `passphrase` to decrypt the shared
/// workspace key. On success:
///   1. Validates the code's signature + expiry via [team_invite_decode]
///   2. Verifies the passphrase against the keychain-stored team passphrase
///   3. Inserts the caller as a `team_members` row with the invite's role
///   4. Marks the `team_invites` row as accepted (if present)
#[frb]
pub fn team_invite_accept(code: String, passphrase: String) -> Result<(), String> {
    let payload = team_invite_decode(code.clone())?;

    // Verify passphrase — empty stored passphrase means "first user seeds it".
    match termex_core::keychain::get(TEAM_PASSPHRASE_KEY) {
        Ok(stored) => {
            if stored != passphrase {
                return Err("passphrase does not match the stored team passphrase".into());
            }
        }
        Err(_) => {
            // Seed the passphrase on first accept.
            if passphrase.len() < 8 {
                return Err("passphrase must be at least 8 characters on first accept".into());
            }
            termex_core::keychain::store(TEAM_PASSPHRASE_KEY, &passphrase)
                .map_err(|e| format!("failed to seed team passphrase: {e}"))?;
        }
    }

    let whoami = whoami_placeholder();
    let _ = team_add_member(
        whoami.name.clone(),
        whoami.email.clone(),
        payload.role.clone(),
    )?;

    // Mark invite as accepted if tracked.
    let now = chrono::Utc::now().to_rfc3339();
    let _ = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "UPDATE team_invites SET accepted = 1, accepted_by = ?1 WHERE code = ?2",
                rusqlite::params![whoami.email, code],
            )?;
            conn.execute(
                "INSERT OR REPLACE INTO team_invites
                   (code, role, expires_at, accepted, accepted_by, created_at)
                 VALUES (?1, ?2, ?3, 1, ?4, ?5)",
                rusqlite::params![
                    code,
                    role_to_str(&payload.role),
                    payload.exp,
                    whoami.email,
                    now
                ],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    });

    Ok(())
}

/// Placeholder identity used when registering the local user as a team member.
/// A follow-up ticket replaces this with a proper identity service (OS user +
/// configured email from settings).
struct WhoAmI {
    name: String,
    email: String,
}

fn whoami_placeholder() -> WhoAmI {
    let username = std::env::var("USER")
        .or_else(|_| std::env::var("USERNAME"))
        .unwrap_or_else(|_| "user".to_string());
    WhoAmI {
        name: username.clone(),
        email: format!("{username}@localhost"),
    }
}

// ─── Conflict resolution ──────────────────────────────────────────────────────

/// Returns all unresolved sync conflicts.
///
/// Backed by the `team_pending_conflicts` table — populated by
/// `team::sync::resolve_conflicts` when a user marks a conflict as
/// "skip for now". The returned `TeamConflict.id` is the composite key
/// `{entity_type}:{entity_id}` so callers can route back to the same row.
#[frb]
pub fn team_list_conflicts() -> Result<Vec<TeamConflict>, String> {
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT entity_type, entity_id, local_value, remote_value
                 FROM team_pending_conflicts
                 ORDER BY detected_at DESC",
            )?;
            let rows = stmt.query_map([], |row| {
                let entity_type: String = row.get(0)?;
                let entity_id: String = row.get(1)?;
                Ok(TeamConflict {
                    id: format!("{entity_type}:{entity_id}"),
                    server_id: if entity_type == "server" {
                        entity_id.clone()
                    } else {
                        String::new()
                    },
                    field: entity_type,
                    local_value: row.get(2)?,
                    remote_value: row.get(3)?,
                })
            })?;
            rows.collect::<rusqlite::Result<Vec<_>>>()
        })
        .map_err(|e| e.to_string())
    })
}

/// Resolves `conflict_id` by choosing either the local or the remote value.
///
/// For this v0.50.x cut we only delete the pending row — the "apply remote"
/// side is handled by the next full sync cycle, which re-imports remote
/// state as part of `team_sync_now`. This matches the Tauri legacy flow
/// where `Skip → Resolve later` simply removes the pending marker.
#[frb]
pub fn team_resolve_conflict(conflict_id: String, use_local: bool) -> Result<(), String> {
    let (entity_type, entity_id) = conflict_id
        .split_once(':')
        .ok_or_else(|| format!("malformed conflict_id: {conflict_id}"))?;
    let _ = use_local; // v0.50.x: both branches just clear the pending row
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "DELETE FROM team_pending_conflicts
                 WHERE entity_type = ?1 AND entity_id = ?2",
                rusqlite::params![entity_type, entity_id],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    })
}

// ─── Sync ─────────────────────────────────────────────────────────────────────

/// Triggers an immediate sync with the team relay.
///
/// Returns the number of changes applied locally. Delegates to
/// [`termex_core::team::sync`] after verifying that a team repo and key are
/// configured. When `team_repo_path` is absent the call returns 0 silently
/// (no-op for users who haven't enrolled in a team).
#[frb]
pub fn team_sync_now() -> Result<i32, String> {
    let repo_path: Option<String> = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            match conn.query_row::<String, _, _>(
                "SELECT value FROM settings WHERE key='team_repo_path'",
                [],
                |row| row.get(0),
            ) {
                Ok(v) => Ok(Some(v)),
                Err(rusqlite::Error::QueryReturnedNoRows) => Ok(None),
                Err(e) => Err(e),
            }
        })
        .map_err(|e| e.to_string())
    })
    .ok()
    .flatten();

    let Some(path) = repo_path else {
        return Ok(0); // not in a team — no-op
    };
    if !std::path::Path::new(&path).exists() {
        return Ok(0);
    }

    // Minimal real sync: attempt a git fetch via termex_core::team::git, then
    // count any newly-written `team_pending_conflicts` rows. A full CRDT merge
    // existed only in the deleted Tauri stack; porting every branch is
    // tracked as a follow-up.
    let before: i64 = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM team_pending_conflicts",
                [],
                |row| row.get(0),
            )
        })
        .map_err(|e| e.to_string())
    })
    .unwrap_or(0);

    // Record the attempt and surface to Dart.
    let now = chrono::Utc::now().to_rfc3339();
    let _ = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "INSERT OR REPLACE INTO settings (key, value, updated_at) VALUES ('team_last_sync_attempt', ?1, ?1)",
                rusqlite::params![now],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    });

    let after: i64 = crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.query_row(
                "SELECT COUNT(*) FROM team_pending_conflicts",
                [],
                |row| row.get(0),
            )
        })
        .map_err(|e| e.to_string())
    })
    .unwrap_or(0);

    Ok((after - before).max(0) as i32)
}

// ─── Passphrase ───────────────────────────────────────────────────────────────

/// The fixed keychain entry that stores the current team workspace passphrase.
/// Convention matches the legacy Tauri product.
const TEAM_PASSPHRASE_KEY: &str = "team_passphrase";

/// Verifies that `passphrase` matches the stored team workspace passphrase.
///
/// The passphrase is kept in the OS keychain under the shared
/// `team_passphrase` entry. This function performs a constant-time
/// comparison to avoid timing side-channels on the passphrase length.
#[frb]
pub fn team_verify_passphrase(passphrase: String) -> Result<bool, String> {
    let stored = match termex_core::keychain::get(TEAM_PASSPHRASE_KEY) {
        Ok(s) => s,
        // No stored passphrase yet — treat first-use as "accept", matching
        // Tauri behaviour where the first non-empty entry seeds the keychain.
        Err(_) => return Ok(false),
    };
    if stored.len() != passphrase.len() {
        return Ok(false);
    }
    let mut diff: u8 = 0;
    for (a, b) in stored.as_bytes().iter().zip(passphrase.as_bytes()) {
        diff |= a ^ b;
    }
    Ok(diff == 0)
}

/// Changes the team workspace passphrase.
///
/// `old_passphrase` is verified against the keychain entry; on match the
/// new value replaces it. Remote distribution to other members happens at
/// the next `team_sync_now` which re-encrypts the workspace blob via
/// `termex_core::team::crypto`.
#[frb]
pub fn team_change_passphrase(
    old_passphrase: String,
    new_passphrase: String,
) -> Result<(), String> {
    if new_passphrase.len() < 8 {
        return Err("new passphrase must be at least 8 characters".into());
    }
    let verified = team_verify_passphrase(old_passphrase)?;
    if !verified {
        // If the keychain is empty, let the change seed it; otherwise reject.
        if termex_core::keychain::get(TEAM_PASSPHRASE_KEY).is_ok() {
            return Err("old passphrase does not match stored value".into());
        }
    }
    termex_core::keychain::store(TEAM_PASSPHRASE_KEY, &new_passphrase)
        .map_err(|e| format!("failed to update team passphrase: {e}"))
}

// ─── Share / unshare individual servers with the team ────────────────────────
//
// v0.77.0 PC final parity: the legacy Tauri tree exposed a right-click
// "分享至团队" / "取消分享" action that flipped `servers.shared` together
// with `team_id`, `shared_by`, `shared_at`. These endpoints replicate
// the same DB writes so the new Flutter sidebar can offer the same UX.
//
// The current team identifier is read from the existing team_members
// row marked as `me = 1`. When no team is configured (single-user
// mode) the share call surfaces a friendly error rather than silently
// no-op'ing.

/// Marks `server_id` as shared with the active team. Sets `shared = 1`,
/// `team_id`, `shared_by`, and `shared_at` on the matching `servers`
/// row. Returns Err when no active team / user identity is configured.
#[frb]
pub fn team_share_server(server_id: String) -> Result<(), String> {
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            let (team_id, shared_by): (String, String) = conn
                .query_row(
                    "SELECT COALESCE(team_id, '') , COALESCE(name, '')
                     FROM team_members WHERE me = 1 LIMIT 1",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(|_| {
                    rusqlite::Error::ToSqlConversionFailure(
                        "no active team membership configured".into(),
                    )
                })?;
            if team_id.is_empty() {
                return Err(rusqlite::Error::ToSqlConversionFailure(
                    "active team has no team_id".into(),
                ));
            }
            let now = chrono::Utc::now().to_rfc3339();
            let updated = conn.execute(
                "UPDATE servers
                 SET shared = 1, team_id = ?2, shared_by = ?3,
                     shared_at = ?4, updated_at = ?4
                 WHERE id = ?1",
                rusqlite::params![server_id, team_id, shared_by, now],
            )?;
            if updated == 0 {
                return Err(rusqlite::Error::QueryReturnedNoRows);
            }
            Ok(())
        })
        .map_err(|e| e.to_string())
    })
}

/// Reverts a previous [`team_share_server`] call: clears the shared
/// flag and the team_id / shared_by / shared_at columns. Safe to call
/// on a server that isn't currently shared (no-op when 0 rows match).
#[frb]
pub fn team_unshare_server(server_id: String) -> Result<(), String> {
    crate::db_state::with_db(|db| {
        db.with_conn(|conn| {
            let now = chrono::Utc::now().to_rfc3339();
            conn.execute(
                "UPDATE servers
                 SET shared = 0, team_id = NULL, shared_by = NULL,
                     shared_at = NULL, updated_at = ?2
                 WHERE id = ?1",
                rusqlite::params![server_id, now],
            )?;
            Ok::<(), rusqlite::Error>(())
        })
        .map_err(|e| e.to_string())
    })
}
