mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, set_mtime_ms, write, write_jsonl};
use rusqlite::{Connection, params};
use serde_json::json;

/// goose sessions.db (session_manager.rs, schema v16): the columns the index reads.
fn goose_db(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE schema_version (version INTEGER PRIMARY KEY, applied_at TIMESTAMP);
         INSERT INTO schema_version (version) VALUES (16);
         CREATE TABLE sessions (id TEXT PRIMARY KEY, name TEXT NOT NULL DEFAULT '',
           description TEXT NOT NULL DEFAULT '', user_set_name BOOLEAN DEFAULT FALSE,
           session_type TEXT NOT NULL DEFAULT 'user', working_dir TEXT NOT NULL,
           created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
           extension_data TEXT DEFAULT '{}', archived_at TIMESTAMP, project_id TEXT, parent_session_id TEXT);
         CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT,
           session_id TEXT NOT NULL, role TEXT NOT NULL, content_json TEXT NOT NULL,
           created_timestamp INTEGER NOT NULL, timestamp TIMESTAMP, tokens INTEGER, metadata_json TEXT);",
    )
    .unwrap();
    conn
}

fn message(conn: &Connection, session: &str, at: i64, role: &str, text: &str, visible: bool) {
    conn.execute(
        "INSERT INTO messages (session_id, role, content_json, created_timestamp, metadata_json)
         VALUES (?1, ?2, ?3, ?4, ?5)",
        params![
            session,
            role,
            json!([{"type": "text", "text": text}]).to_string(),
            at,
            json!({"userVisible": visible, "agentVisible": true}).to_string()
        ],
    )
    .unwrap();
}

#[test]
fn db_sessions_and_legacy_jsonl_merge_with_the_db_winning() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let db = goose_db(&root.join("sessions.db"));
    db.execute_batch(
        "INSERT INTO sessions (id, name, description, working_dir, created_at, updated_at, archived_at)
           VALUES ('20261008_1', 'My name', 'fix the build', '/w/a', '2026-10-01 10:00:00', '2026-10-01 11:00:00', NULL),
                  ('20261008_2', '', '', '/w/b', '2026-10-01T10:00:00Z', '2026-10-01T10:30:00Z', '2026-10-02 00:00:00'),
                  ('20261008_3', '', 'imported', '/w/c', '2026-10-01 10:00:00', '2026-10-01 10:00:00', NULL);
         INSERT INTO sessions (id, working_dir, session_type) VALUES ('sub', '/w', 'sub_agent');
         INSERT INTO sessions (id, working_dir, parent_session_id) VALUES ('child', '/w', '20261008_1');",
    )
    .unwrap();
    message(&db, "20261008_1", 1, "user", "hello", true);
    message(&db, "20261008_1", 2, "assistant", "hi", true);
    message(&db, "20261008_1", 3, "user", "hidden summary", false);
    message(&db, "20261008_2", 5, "user", "later", true);
    message(&db, "20261008_2", 4, "user", "first ask\nmore", true);
    // The importer keeps the JSONL file: the DB row wins.
    write_jsonl(
        &root.join("20261008_3.jsonl"),
        &[json!({"description": "from file", "message_count": 9, "working_dir": "/old"})],
    );

    let scan = scan(AdapterKind::Goose, root);
    assert_eq!(ids(&scan), ["20261008_1", "20261008_2", "20261008_3"].map(String::from).into());
    let chats = by_id(&scan);
    let one = &chats["20261008_1"];
    assert_eq!(
        (one.title.as_deref(), one.title_source),
        (Some("My name"), Some(TitleSource::Custom))
    );
    assert_eq!(one.cwd.as_deref(), Some("/w/a"));
    assert_eq!((one.created_ms, one.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(one.message_count, Some(2), "userVisible false is not counted");
    assert_eq!(
        one.resume,
        Resume::Argv {
            argv: ["goose", "session", "--resume", "--session-id", "20261008_1"]
                .map(String::from)
                .to_vec(),
            cwd_needed: true
        }
    );
    let two = &chats["20261008_2"];
    assert_eq!(
        (two.title.as_deref(), two.title_source),
        (Some("first ask"), Some(TitleSource::Prompt))
    );
    assert!(two.archived && !one.archived);
    assert_eq!(two.updated_ms, 1_790_850_600_000);
    let three = &chats["20261008_3"];
    assert_eq!((three.title.as_deref(), three.cwd.as_deref()), (Some("imported"), Some("/w/c")));
}

#[test]
fn legacy_jsonl_with_metadata_and_without() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    // v1.0.20+: metadata line with working_dir.
    let with_meta = root.join("20261001_100000.jsonl");
    write_jsonl(
        &with_meta,
        &[
            json!({"description": "Refactor parser", "message_count": 4, "total_tokens": 10, "working_dir": "/w/p"}),
            json!({"role": "user", "created": 1_790_848_800, "content": [{"type": "text", "text": "go"}]}),
        ],
    );
    set_mtime_ms(&with_meta, 1_790_860_000_000);
    // v1.0.6 era: no metadata line, the first line is a message.
    write_jsonl(
        &root.join("named-session.jsonl"),
        &[
            json!({"role": "user", "created": 1, "content": [{"type": "text", "text": "old prompt"}]}),
        ],
    );
    write(&root.join("broken.jsonl"), "{\"description\": ");
    write(&root.join("notes.txt"), "not a session");

    let chats = by_id(&scan(AdapterKind::Goose, root));
    assert_eq!(chats.len(), 3);
    let meta = &chats["20261001_100000"];
    assert_eq!(
        (meta.title.as_deref(), meta.title_source),
        (Some("Refactor parser"), Some(TitleSource::Ai))
    );
    assert_eq!(meta.cwd.as_deref(), Some("/w/p"));
    assert_eq!(meta.message_count, Some(4));
    assert_eq!(meta.created_ms, Some(1_790_848_800_000));
    assert_eq!(meta.updated_ms, 1_790_860_000_000);
    let named = &chats["named-session"];
    assert_eq!(
        (named.title.as_deref(), named.title_source, named.created_ms),
        (Some("old prompt"), Some(TitleSource::Prompt), None)
    );
    assert_eq!(chats["broken"].title, None);
}

#[test]
fn db_and_jsonl_writes_rescan_the_root() {
    let root = Path::new("/r");
    let role = |rel: &str| classify_path(AdapterKind::Goose, root, &root.join(rel));
    assert_eq!(role("sessions.db"), PathRole::Store);
    assert_eq!(role("sessions.db-wal"), PathRole::Store);
    assert_eq!(role("20261001_100000.jsonl"), PathRole::Store);
    assert_eq!(role("sub/x.jsonl"), PathRole::Ignore);
}
