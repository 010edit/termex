/// Session recording management exposed to Flutter via FRB (v0.47 spec §5).
///
/// Metadata persists to the `recordings` table (V13 + V17 team columns + V23
/// encryption/part_linkage).  The actual `.cast` file is stored on the
/// filesystem under `{app_data_dir}/recordings/`.
///
/// When the database is not unlocked the API falls back to a process-local
/// in-memory registry so UI flows can be exercised in unit tests without a DB.
use std::collections::HashMap;
use std::sync::Mutex;

use once_cell::sync::Lazy;

use crate::db_state;
use termex_core::recording::recorder::RecorderRegistry;

/// The live recorder — the piece the Flutter build was missing.
///
/// `recording_start` used to only insert a database row, so the list panel
/// showed entries whose `.cast` files were never written and whose terminal
/// output was never captured. The legacy Tauri build kept this registry in
/// AppState and fed it from the SSH read loop; this is the equivalent, fed
/// from `frb_ssh_emitter`.
pub static RECORDER: Lazy<RecorderRegistry> = Lazy::new(RecorderRegistry::new);

// ─── DTOs ────────────────────────────────────────────────────────────────────

/// Full recording metadata (v0.47 spec §9.5.2).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingDto {
    pub id: String,
    pub session_id: String,
    pub server_id: String,
    pub server_name: String,
    pub file_path: String,
    pub file_size: u64,
    pub duration_ms: u64,
    pub cols: u16,
    pub rows: u16,
    pub event_count: u32,
    pub summary: Option<String>,
    pub auto_recorded: bool,
    pub started_at: String,
    pub ended_at: Option<String>,
    pub parent_id: Option<String>,
    pub is_encrypted: bool,
}

/// Legacy simpler DTO for v0.46-era Dart tests.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecordingEntry {
    pub id: String,
    pub session_id: String,
    pub title: Option<String>,
    pub file_path: String,
    pub duration_seconds: u64,
    pub size_bytes: u64,
    pub created_at: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AsciicastHeader {
    pub version: u16,
    pub width: u16,
    pub height: u16,
    pub timestamp: u64,
    pub title: Option<String>,
    pub env: HashMap<String, String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CastEvent {
    pub relative_time: f64,
    pub kind: String,
    pub data: String,
}

// ─── Registry (in-memory fallback) ──────────────────────────────────────────

static RECORDING_REGISTRY: Lazy<Mutex<HashMap<String, RecordingEntry>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));

// ─── Filename rendering (§5.5) ──────────────────────────────────────────────

fn sanitize_server_name(name: &str) -> String {
    name.chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' { c } else { '_' })
        .collect()
}

fn random_hex6() -> String {
    use ring::rand::{SecureRandom, SystemRandom};
    let rng = SystemRandom::new();
    let mut bytes = [0u8; 3];
    let _ = rng.fill(&mut bytes);
    bytes.iter().map(|b| format!("{:02x}", b)).collect()
}

/// Renders the canonical `.cast` filename for a new recording.
pub fn recording_render_filename(server_name: &str) -> String {
    let safe = sanitize_server_name(server_name);
    let ts = chrono::Utc::now().format("%Y%m%dT%H%M%S");
    let rand = random_hex6();
    format!("{}_{}_{}.cast", safe, ts, rand)
}

/// Renders the filename for an auto-split part (part2+).
pub fn recording_render_part_filename(basename: &str, part_n: u32) -> String {
    let trimmed = basename.trim_end_matches(".cast");
    format!("{}_part{}.cast", trimmed, part_n)
}

// ─── Core API ───────────────────────────────────────────────────────────────

/// Begins recording terminal output for `session_id`.  Returns a new recording id.
/// Starts recording `session_id`, capturing terminal output to an asciicast
/// file.
///
/// `auto_recorded` marks the row so the list can badge it AUTO, matching the
/// Tauri list. `initial_screen` is the terminal's current contents, written as
/// the first frame so playback does not begin blank.
///
/// Mirrors the Tauri command's shape (session + server identity + geometry)
/// rather than the id-only stub this replaces — the recorder keys everything
/// by session, and the header needs the real terminal size to replay
/// correctly.
pub async fn recording_start(
    session_id: String,
    server_id: String,
    server_name: String,
    cols: u32,
    rows: u32,
    title: Option<String>,
    max_recording_mb: u32,
    auto_recorded: bool,
    initial_screen: Option<String>,
) -> Result<String, String> {
    crate::frb_ssh_emitter::ACTIVE_RECORDINGS.insert(session_id.clone());
    let (id, file_path) = RECORDER
        .start(
            &session_id,
            &server_id,
            &server_name,
            cols,
            rows,
            title.clone(),
            auto_recorded,
            max_recording_mb,
        )
        .await
        .map_err(|e| e.to_string())?;

    // Seed the recording with whatever is already on screen. An asciicast
    // holds only what arrives after capture starts, so a replay would open on
    // a black screen and stay blank until the session next produced output.
    if let Some(screen) = initial_screen.filter(|s| !s.is_empty()) {
        RECORDER.record_output(&session_id, &screen).await;
    }

    let path_str = file_path.to_string_lossy().to_string();
    let now = chrono::Utc::now().to_rfc3339();

    if db_state::is_unlocked() {
        let auto = auto_recorded;
        let (id2, sid, name, path, started) = (
            id.clone(),
            session_id.clone(),
            title.clone().unwrap_or_else(|| server_name.clone()),
            path_str.clone(),
            now.clone(),
        );
        db_state::with_db(|db| {
            db.with_conn(|conn| {
                conn.execute(
                    "INSERT INTO recordings
                       (id, session_id, server_id, server_name, file_path, file_size,
                        duration_ms, cols, rows, event_count, summary, auto_recorded,
                        started_at, ended_at, created_at, parent_id, is_encrypted)
                     VALUES (?1, ?2, ?3, ?4, ?5, 0, 0, ?6, ?7, 0, NULL, ?9, ?8, NULL, ?8, NULL, 0)",
                    rusqlite::params![
                        id2, sid, server_id, name, path, cols, rows, started,
                        if auto { 1 } else { 0 },
                    ],
                )?;
                Ok(())
            })
            .map_err(|e| e.to_string())
        })?;
    } else {
        RECORDING_REGISTRY.lock().unwrap().insert(
            id.clone(),
            RecordingEntry {
                id: id.clone(),
                session_id,
                title,
                file_path: path_str,
                duration_seconds: 0,
                size_bytes: 0,
                created_at: now,
            },
        );
    }

    Ok(id)
}

/// Whether `session_id` is currently being recorded. Used by the UI to render
/// the correct control after a rebuild or a tab switch.
pub async fn recording_is_active(session_id: String) -> bool {
    RECORDER.is_recording(&session_id).await
}

/// Duration and event count of a finished asciicast.
///
/// Read back from the file rather than tracked during capture: the recorder
/// owns the event list, and re-deriving here keeps the bridge from
/// second-guessing what it actually wrote.
fn summarise_cast(path: &std::path::Path) -> (u64, u32) {
    let Ok(content) = std::fs::read_to_string(path) else {
        return (0, 0);
    };
    let mut count = 0u32;
    let mut last = 0f64;
    for line in content.lines() {
        if !line.starts_with('[') {
            continue; // header
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(line) {
            if let Some(t) = v.get(0).and_then(|t| t.as_f64()) {
                last = last.max(t);
                count += 1;
            }
        }
    }
    ((last * 1000.0) as u64, count)
}

/// Stops an active recording and returns its metadata.
pub async fn recording_stop(session_id: String) -> Result<RecordingEntry, String> {
    // Flush the asciicast to disk first — this is what actually produces the
    // file the list panel links to. Keyed by session, matching the Tauri
    // command; the previous signature took a recording id and wrote nothing.
    crate::frb_ssh_emitter::ACTIVE_RECORDINGS.remove(&session_id);
    let (recording_id, file_path) = RECORDER
        .stop(&session_id)
        .await
        .map_err(|e| e.to_string())?;
    let path_str = file_path.to_string_lossy().to_string();
    let size = std::fs::metadata(&file_path).map(|m| m.len()).unwrap_or(0);

    // Derived from the file just written. Without this every recording showed
    // "0s · 0 events" in the list no matter how much it captured, because
    // nothing ever updated the zeros inserted at start.
    let (duration_ms, event_count) = summarise_cast(&file_path);

    if db_state::is_unlocked() {
        // Fill in ended_at + return DTO.
        let entry = db_state::with_db(|db| {
            db.with_conn(|conn| {
                let now = chrono::Utc::now().to_rfc3339();
                conn.execute(
                    "UPDATE recordings
                        SET ended_at = ?1, file_path = ?2, file_size = ?3,
                            duration_ms = ?4, event_count = ?5
                      WHERE id = ?6",
                    rusqlite::params![
                        now, path_str, size, duration_ms, event_count,
                        recording_id
                    ],
                )?;
                let row: Option<(String, String, String, u64, u64, String)> = conn
                    .query_row(
                        "SELECT id, session_id, COALESCE(server_name, ''), duration_ms, file_size, created_at
                         FROM recordings WHERE id = ?1",
                        rusqlite::params![recording_id],
                        |r| {
                            Ok((
                                r.get::<_, String>(0)?,
                                r.get::<_, String>(1)?,
                                r.get::<_, String>(2)?,
                                r.get::<_, u64>(3)?,
                                r.get::<_, u64>(4)?,
                                r.get::<_, String>(5)?,
                            ))
                        },
                    )
                    .ok();
                Ok(row.map(|(id, sid, title, dur_ms, sz, created)| RecordingEntry {
                    id,
                    session_id: sid,
                    title: Some(title),
                    file_path: path_str.clone(),
                    duration_seconds: dur_ms / 1000,
                    size_bytes: if sz == 0 { size } else { sz },
                    created_at: created,
                }))
            })
            .map_err(|e| e.to_string())
        })?;
        if let Some(e) = entry {
            return Ok(e);
        }
    }

    // Fallback: in-memory.
    let reg = RECORDING_REGISTRY.lock().unwrap();
    if let Some(entry) = reg.get(&recording_id) {
        Ok(entry.clone())
    } else {
        Ok(RecordingEntry {
            id: recording_id.clone(),
            session_id: String::new(),
            title: None,
            file_path: format!("/tmp/{recording_id}.cast"),
            duration_seconds: 0,
            size_bytes: 0,
            created_at: chrono::Utc::now().to_rfc3339(),
        })
    }
}

/// Lists all known recordings (legacy DTO).
pub fn recording_list() -> Result<Vec<RecordingEntry>, String> {
    if !db_state::is_unlocked() {
        return Ok(vec![]);
    }
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, session_id, COALESCE(server_name, ''), file_path,
                        duration_ms, file_size, created_at
                 FROM recordings ORDER BY created_at DESC",
            )?;
            let iter = stmt.query_map([], |r| {
                Ok(RecordingEntry {
                    id: r.get::<_, String>(0)?,
                    session_id: r.get::<_, String>(1)?,
                    title: {
                        let s: String = r.get(2)?;
                        if s.is_empty() { None } else { Some(s) }
                    },
                    file_path: r.get(3)?,
                    duration_seconds: r.get::<_, u64>(4)? / 1000,
                    size_bytes: r.get(5)?,
                    created_at: r.get(6)?,
                })
            })?;
            let mut out = Vec::new();
            for row in iter {
                if let Ok(e) = row {
                    out.push(e);
                }
            }
            Ok(out)
        })
        .map_err(|e| e.to_string())
    })
}

/// Lists recordings with the full v0.47 DTO shape.
pub fn recording_list_full() -> Result<Vec<RecordingDto>, String> {
    if !db_state::is_unlocked() {
        return Ok(vec![]);
    }
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            let mut stmt = conn.prepare(
                "SELECT id, session_id, COALESCE(server_id, ''), COALESCE(server_name, ''),
                        file_path, file_size, duration_ms, cols, rows, event_count, summary,
                        auto_recorded, started_at, ended_at,
                        parent_id, COALESCE(is_encrypted, 0)
                 FROM recordings ORDER BY started_at DESC",
            )?;
            let iter = stmt.query_map([], |r| {
                Ok(RecordingDto {
                    id: r.get(0)?,
                    session_id: r.get(1)?,
                    server_id: r.get(2)?,
                    server_name: r.get(3)?,
                    file_path: r.get(4)?,
                    file_size: r.get(5)?,
                    duration_ms: r.get(6)?,
                    cols: r.get(7)?,
                    rows: r.get(8)?,
                    event_count: r.get(9)?,
                    summary: r.get(10)?,
                    auto_recorded: r.get::<_, i32>(11)? != 0,
                    started_at: r.get(12)?,
                    ended_at: r.get(13)?,
                    parent_id: r.get(14)?,
                    is_encrypted: r.get::<_, i32>(15)? != 0,
                })
            })?;
            let mut out = Vec::new();
            for row in iter {
                if let Ok(e) = row {
                    out.push(e);
                }
            }
            Ok(out)
        })
        .map_err(|e| e.to_string())
    })
}

/// Registers a follow-up part (part2+) linked to `parent_id`.
pub fn recording_register_part(
    parent_id: String,
    session_id: String,
    file_path: String,
) -> Result<String, String> {
    if !db_state::is_unlocked() {
        return Ok(uuid::Uuid::new_v4().to_string());
    }
    let id = uuid::Uuid::new_v4().to_string();
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            let now = chrono::Utc::now().to_rfc3339();
            conn.execute(
                "INSERT INTO recordings
                   (id, session_id, server_id, server_name, file_path, file_size,
                    duration_ms, cols, rows, event_count, summary, auto_recorded,
                    started_at, ended_at, created_at, parent_id, is_encrypted)
                 VALUES (?1, ?2, '', '', ?3, 0, 0, 80, 24, 0, NULL, 0, ?4, NULL, ?4, ?5, 0)",
                rusqlite::params![id, session_id, file_path, now, parent_id],
            )?;
            Ok(())
        })
        .map_err(|e| e.to_string())
    })?;
    Ok(id)
}

/// Deletes a recording by `id` (cascade to parts is NOT applied — call the
/// helper below to delete a full group).
pub fn recording_delete(id: String) -> Result<(), String> {
    if db_state::is_unlocked() {
        // Read the path before dropping the row — afterwards there is nothing
        // left pointing at the file, which is how deleted recordings used to
        // leave their .cast behind forever.
        let path: Option<String> = db_state::with_db(|db| {
            db.with_conn(|conn| {
                Ok(conn
                    .query_row(
                        "SELECT file_path FROM recordings WHERE id = ?1",
                        rusqlite::params![id],
                        |r| r.get::<_, String>(0),
                    )
                    .ok())
            })
            .map_err(|e| e.to_string())
        })?;

        db_state::with_db(|db| {
            db.with_conn(|conn| {
                conn.execute("DELETE FROM recordings WHERE id = ?1", rusqlite::params![id])?;
                Ok(())
            })
            .map_err(|e| e.to_string())
        })?;

        // Best-effort: the row is already gone, and a file that cannot be
        // removed must not report the delete as failed.
        if let Some(p) = path.filter(|p| !p.is_empty()) {
            let _ = std::fs::remove_file(p);
        }
    } else {
        RECORDING_REGISTRY.lock().unwrap().remove(&id);
    }
    Ok(())
}

/// Deletes a recording and every follow-up part linked to it.
pub fn recording_delete_group(parent_id: String) -> Result<u32, String> {
    if !db_state::is_unlocked() {
        return Ok(0);
    }
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            let parts: u32 = conn.execute(
                "DELETE FROM recordings WHERE id = ?1 OR parent_id = ?1",
                rusqlite::params![parent_id],
            )? as u32;
            Ok(parts)
        })
        .map_err(|e| e.to_string())
    })
}

/// Returns the filesystem path for a recording's `.cast` file.
pub fn recording_get_path(id: String) -> Result<String, String> {
    if !db_state::is_unlocked() {
        return Ok(format!("/tmp/{id}.cast"));
    }
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            let row: Option<String> = conn
                .query_row(
                    "SELECT file_path FROM recordings WHERE id = ?1",
                    rusqlite::params![id],
                    |r| r.get(0),
                )
                .ok();
            Ok(row.unwrap_or_else(|| format!("/tmp/{id}.cast")))
        })
        .map_err(|e| e.to_string())
    })
}

/// Exports a recording to `dest_path`.  Copies the underlying `.cast` file.
/// Reads a recording's asciicast content for playback.
///
/// The Tauri build exposed this as `recording_read`; the Flutter bridge had
/// no equivalent, so the list could locate a `.cast` file but nothing could
/// open it.
///
/// Capped at 64 MiB — a recording larger than that is not something to hold
/// in memory and hand to a player in one piece.
pub fn recording_read(path: String) -> Result<String, String> {
    const MAX_BYTES: u64 = 64 * 1024 * 1024;

    let meta = std::fs::metadata(&path)
        .map_err(|e| format!("cannot open recording: {e}"))?;
    if meta.len() > MAX_BYTES {
        return Err(format!(
            "recording is {} MiB, larger than the {} MiB playback limit",
            meta.len() / (1024 * 1024),
            MAX_BYTES / (1024 * 1024)
        ));
    }
    std::fs::read_to_string(&path).map_err(|e| format!("cannot read recording: {e}"))
}

pub fn recording_export(id: String, dest_path: String) -> Result<(), String> {
    let source = recording_get_path(id.clone())?;
    if std::path::Path::new(&source).exists() {
        std::fs::copy(&source, &dest_path)
            .map_err(|e| format!("copy recording: {e}"))?;
    }
    // Audit.
    let _ = crate::api::settings::audit_append(
        "recording.export",
        &format!("id={id} dest={dest_path}"),
    );
    Ok(())
}

/// Marks `id` as encrypted (after caller has re-encrypted the underlying file).
pub fn recording_mark_encrypted(id: String) -> Result<(), String> {
    if !db_state::is_unlocked() {
        return Ok(());
    }
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            conn.execute(
                "UPDATE recordings SET is_encrypted = 1 WHERE id = ?1",
                rusqlite::params![id],
            )?;
            Ok(())
        })
        .map_err(|e| e.to_string())
    })
}

/// Deletes recordings older than `days` days.  Returns count deleted.
pub fn recording_cleanup_expired(days: u32) -> Result<u32, String> {
    if !db_state::is_unlocked() || days == 0 {
        return Ok(0);
    }
    let cutoff =
        (chrono::Utc::now() - chrono::Duration::days(days as i64)).to_rfc3339();
    db_state::with_db(|db| {
        db.with_conn(|conn| {
            let n = conn.execute(
                "DELETE FROM recordings WHERE created_at < ?1",
                rusqlite::params![cutoff],
            )?;
            Ok(n as u32)
        })
        .map_err(|e| e.to_string())
    })
}

/// For tests: clears the in-memory recording registry.
pub fn _test_clear_registry() {
    RECORDING_REGISTRY.lock().unwrap().clear();
}
