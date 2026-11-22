//! Cursor agent CLI: `<root>/<md5 of cwd>/<chat id>/meta.json`
//! (`{schemaVersion: 1, createdAtMs, updatedAtMs, title|name, cwd,
//! isSubagent, hasConversation}`). A chat without `meta.json` (older builds)
//! is read from row `"0"` of the `meta` table of its `store.db`: hex-encoded
//! JSON with `name`, `createdAt` and `subagentInfo`. Nothing else in
//! `store.db` is read (the `blobs` table holds the content).

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::{PathRole, argv};
use crate::entry::{AdapterKind, ChatEntry, Resume, TitleSource};
use crate::lines::read_whole_json;
use crate::stamp::FileStamp;
use crate::text::title_field;

pub(super) fn list(root: &Path) -> io::Result<Vec<PathBuf>> {
    let mut out = Vec::new();
    for group in fs::read_dir(root)?.flatten() {
        let Ok(chats) = fs::read_dir(group.path()) else { continue };
        for chat in chats.flatten() {
            let meta = chat.path().join("meta.json");
            let store = chat.path().join("store.db");
            if meta.is_file() {
                out.push(meta);
            } else if store.is_file() {
                out.push(store);
            }
        }
    }
    Ok(out)
}

pub(super) fn read(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> {
    if path.file_name().is_some_and(|name| name == "store.db") {
        return Ok(read_store_meta(path, stamp));
    }
    let Some(meta) = read_whole_json(path)? else { return Ok(None) };
    if meta.get("hasConversation") == Some(&Value::Bool(false))
        || meta.get("isSubagent") == Some(&Value::Bool(true))
    {
        return Ok(None);
    }
    let Some(session_id) =
        path.parent().and_then(Path::file_name).and_then(|name| name.to_str()).map(str::to_owned)
    else {
        return Ok(None);
    };
    let title = title_field(meta.get("name")).or_else(|| title_field(meta.get("title")));
    Ok(Some(ChatEntry {
        harness: AdapterKind::CursorAgent,
        title_source: title.as_ref().map(|_| TitleSource::Ai),
        title,
        cwd: meta
            .get("cwd")
            .and_then(Value::as_str)
            .filter(|cwd| !cwd.is_empty())
            .map(str::to_owned),
        created_ms: meta.get("createdAtMs").and_then(Value::as_i64),
        updated_ms: meta.get("updatedAtMs").and_then(Value::as_i64).unwrap_or(stamp.mtime_ms),
        message_count: None,
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv {
            argv: argv(&["cursor-agent", "--resume", &session_id]),
            cwd_needed: true,
        },
        session_id,
    }))
}

pub(super) fn classify(parts: &[&str]) -> PathRole {
    match parts {
        [_, _, "meta.json"] => PathRole::Session,
        // A chat without meta.json is read from its store's meta row.
        [_, _, "store.db" | "store.db-wal"] => PathRole::Store,
        _ => PathRole::Ignore,
    }
}

/// Row `"0"` of `store.db`'s `meta` table: hex-encoded JSON.
fn read_store_meta(path: &Path, stamp: FileStamp) -> Option<ChatEntry> {
    let conn = crate::sqlite::open_read_only(path).ok()?;
    let hex: String =
        conn.query_row("SELECT value FROM meta WHERE key = '0'", [], |row| row.get(0)).ok()?;
    let bytes = decode_hex(hex.trim())?;
    let meta: Value = serde_json::from_slice(&bytes).ok()?;
    if meta.get("subagentInfo").is_some_and(|info| !info.is_null()) {
        return None;
    }
    let session_id = path.parent()?.file_name()?.to_str()?.to_owned();
    let title = title_field(meta.get("name"));
    // The WAL holds the newest writes.
    let wal = path.with_extension("db-wal");
    let wal_ms = fs::metadata(&wal).map(|meta| FileStamp::of(&meta).mtime_ms).unwrap_or(0);
    Some(ChatEntry {
        harness: AdapterKind::CursorAgent,
        title_source: title.as_ref().map(|_| TitleSource::Ai),
        title,
        cwd: None,
        created_ms: meta.get("createdAt").and_then(Value::as_i64).map(epoch_ms),
        updated_ms: stamp.mtime_ms.max(wal_ms),
        message_count: None,
        source_path: path.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Argv {
            argv: argv(&["cursor-agent", "--resume", &session_id]),
            cwd_needed: true,
        },
        session_id,
    })
}

/// Seconds, milliseconds, microseconds or nanoseconds to milliseconds.
fn epoch_ms(value: i64) -> i64 {
    match value.unsigned_abs() {
        0..100_000_000_000 => value.saturating_mul(1000),
        100_000_000_000..100_000_000_000_000 => value,
        100_000_000_000_000..100_000_000_000_000_000 => value / 1000,
        _ => value / 1_000_000,
    }
}

fn decode_hex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) || text.len() > 1 << 20 {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|at| text.get(at..at + 2).and_then(|pair| u8::from_str_radix(pair, 16).ok()))
        .collect()
}
