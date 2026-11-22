mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, scan};
use rusqlite::{Connection, params};
use serde_json::json;

/// The schema of grok-cli 1.0 (`src/storage/migrations.ts`, user_version 3).
fn grok_db(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE workspaces (id TEXT PRIMARY KEY, scope_key TEXT NOT NULL UNIQUE,
           canonical_path TEXT NOT NULL, git_root TEXT, display_name TEXT NOT NULL, last_seen_at TEXT NOT NULL);
         CREATE TABLE sessions (id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, title TEXT, recap_text TEXT,
           recap_model TEXT, recap_updated_at TEXT, model TEXT NOT NULL, mode TEXT NOT NULL,
           cwd_at_start TEXT NOT NULL, cwd_last TEXT NOT NULL, status TEXT NOT NULL,
           created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
         CREATE TABLE messages (session_id TEXT NOT NULL, seq INTEGER NOT NULL, role TEXT NOT NULL,
           message_json TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (session_id, seq));
         PRAGMA user_version = 3;",
    )
    .unwrap();
    conn
}

fn session(conn: &Connection, id: &str, title: Option<&str>, start: &str, last: &str) {
    conn.execute(
        "INSERT INTO sessions (id, workspace_id, title, model, mode, cwd_at_start, cwd_last, status, created_at, updated_at)
         VALUES (?1, 'w', ?2, 'grok-4', 'agent', ?3, ?4, 'idle', '2026-10-01T10:00:00.000Z', '2026-10-01T11:00:00.000Z')",
        params![id, title, start, last],
    )
    .unwrap();
}

fn message(conn: &Connection, id: &str, seq: i64, role: &str, content: serde_json::Value) {
    conn.execute(
        "INSERT INTO messages (session_id, seq, role, message_json, created_at) VALUES (?1, ?2, ?3, ?4, 'x')",
        params![id, seq, role, json!({"role": role, "content": content}).to_string()],
    )
    .unwrap();
}

#[test]
fn sessions_come_from_grok_db_with_prompt_titles_when_untitled() {
    let dir = tempfile::tempdir().unwrap();
    let db = grok_db(&dir.path().join("grok.db"));
    session(&db, "aaaaaaaaaaaa", Some("Refactor parser"), "/w/a", "/w/a/sub");
    message(&db, "aaaaaaaaaaaa", 1, "user", json!("refactor it"));
    message(&db, "aaaaaaaaaaaa", 2, "assistant", json!("done"));
    message(&db, "aaaaaaaaaaaa", 3, "tool", json!([]));
    session(&db, "bbbbbbbbbbbb", None, "/w/b", "");
    message(&db, "bbbbbbbbbbbb", 2, "user", json!("second"));
    message(&db, "bbbbbbbbbbbb", 1, "user", json!([{"type": "text", "text": "add tests\nnow"}]));

    let chats = by_id(&scan(AdapterKind::GrokCli, dir.path()));
    let a = &chats["aaaaaaaaaaaa"];
    assert_eq!(
        (a.title.as_deref(), a.title_source),
        (Some("Refactor parser"), Some(TitleSource::Ai))
    );
    assert_eq!(a.cwd.as_deref(), Some("/w/a/sub"));
    assert_eq!(a.message_count, Some(2));
    assert_eq!((a.created_ms, a.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(a.resume, Resume::ReadOnly);
    let b = &chats["bbbbbbbbbbbb"];
    assert_eq!(
        (b.title.as_deref(), b.title_source),
        (Some("add tests"), Some(TitleSource::Prompt))
    );
    assert_eq!(b.cwd.as_deref(), Some("/w/b"));
}

#[test]
fn an_older_schema_without_cwd_or_messages_still_lists_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let conn = Connection::open(dir.path().join("grok.db")).unwrap();
    conn.execute_batch(
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, created_at TEXT, updated_at TEXT);
         INSERT INTO sessions VALUES ('old', 'Old chat', '2026-10-01T10:00:00Z', NULL);",
    )
    .unwrap();
    let chats = by_id(&scan(AdapterKind::GrokCli, dir.path()));
    let old = &chats["old"];
    assert_eq!(old.title.as_deref(), Some("Old chat"));
    assert_eq!((old.cwd.as_deref(), old.message_count), (None, None));
    assert_eq!(old.updated_ms, 1_790_848_800_000);
}

#[test]
fn a_root_without_grok_db_is_empty_and_db_writes_rescan() {
    let dir = tempfile::tempdir().unwrap();
    assert!(scan(AdapterKind::GrokCli, dir.path()).entries.is_empty());
    let root = Path::new("/r");
    let role = |rel: &str| classify_path(AdapterKind::GrokCli, root, &root.join(rel));
    assert_eq!(role("grok.db"), PathRole::Store);
    assert_eq!(role("grok.db-wal"), PathRole::Store);
    assert_eq!(role("sessions/x/summary.json"), PathRole::Ignore);
}
