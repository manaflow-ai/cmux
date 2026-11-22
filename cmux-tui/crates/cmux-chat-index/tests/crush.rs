mod common;

use std::fs;
use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan};
use rusqlite::{Connection, params};
use serde_json::json;

/// The schema after Crush's initial migration (20250424200609) plus the
/// later session columns (summary_message_id, todos, channel).
fn crush_db(path: &Path) -> Connection {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT NOT NULL,
           message_count INTEGER NOT NULL DEFAULT 0, prompt_tokens INTEGER NOT NULL DEFAULT 0,
           completion_tokens INTEGER NOT NULL DEFAULT 0, cost REAL NOT NULL DEFAULT 0.0,
           updated_at INTEGER NOT NULL, created_at INTEGER NOT NULL,
           summary_message_id TEXT, todos TEXT, channel TEXT);
         CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, role TEXT NOT NULL,
           parts TEXT NOT NULL DEFAULT '[]', model TEXT, created_at INTEGER NOT NULL,
           updated_at INTEGER NOT NULL, finished_at INTEGER);",
    )
    .unwrap();
    conn
}

fn session(conn: &Connection, id: &str, parent: Option<&str>, title: &str, count: i64) {
    conn.execute(
        "INSERT INTO sessions (id, parent_session_id, title, message_count, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, 1790848800, 1790852400)",
        params![id, parent, title, count],
    )
    .unwrap();
}

fn message(conn: &Connection, session: &str, id: &str, at: i64, role: &str, text: &str) {
    let parts = json!([{"type": "text", "data": {"text": text}}]).to_string();
    conn.execute(
        "INSERT INTO messages (id, session_id, role, parts, created_at, updated_at) VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
        params![id, session, role, parts, at],
    )
    .unwrap();
}

#[test]
fn project_sessions_come_from_crush_db_with_the_project_as_folder() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("proj/.crush");
    let db = crush_db(&data.join("crush.db"));
    session(&db, "s1", None, "Refactor parser", 3);
    session(&db, "s2", None, "", 2);
    message(&db, "s2", "m2", 2, "user", "second");
    message(&db, "s2", "m1", 1, "user", "add tests\nfor it");
    session(&db, "title-s1", Some("s1"), "title gen", 1);

    let scan = scan(AdapterKind::Crush, &data);
    assert_eq!(ids(&scan), ["s1", "s2"].map(String::from).into());
    let chats = by_id(&scan);
    let s1 = &chats["s1"];
    assert_eq!(
        (s1.title.as_deref(), s1.title_source),
        (Some("Refactor parser"), Some(TitleSource::Ai))
    );
    assert_eq!(s1.message_count, Some(3));
    assert_eq!((s1.created_ms, s1.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(s1.cwd.as_deref(), Some(dir.path().join("proj").display().to_string().as_str()));
    assert_eq!(s1.resume, Resume::ReadOnly);
    let s2 = &chats["s2"];
    assert_eq!(
        (s2.title.as_deref(), s2.title_source),
        (Some("add tests"), Some(TitleSource::Prompt))
    );
}

#[test]
fn an_older_schema_without_parent_or_count_and_a_custom_data_dir() {
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("custom-data");
    fs::create_dir_all(&data).unwrap();
    let conn = Connection::open(data.join("crush.db")).unwrap();
    conn.execute_batch(
        "CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT, updated_at INTEGER, created_at INTEGER);
         CREATE TABLE messages (id TEXT PRIMARY KEY, session_id TEXT, role TEXT, parts TEXT, created_at INTEGER);
         INSERT INTO sessions VALUES ('old', 'Old', 1790852400000, 1790848800);
         INSERT INTO messages VALUES ('m', 'old', 'user', '[]', 1);",
    )
    .unwrap();
    let chats = by_id(&scan(AdapterKind::Crush, &data));
    let old = &chats["old"];
    assert_eq!(old.cwd, None, "only a .crush dir names its project");
    assert_eq!(old.updated_ms, 1_790_852_400_000, "a millisecond value stays as is");
    assert_eq!(old.message_count, Some(1));
}

#[test]
fn crush_db_writes_rescan_the_root() {
    let root = Path::new("/r");
    let role = |rel: &str| classify_path(AdapterKind::Crush, root, &root.join(rel));
    assert_eq!(role("crush.db"), PathRole::Store);
    assert_eq!(role("crush.db-wal"), PathRole::Store);
    assert_eq!(role("logs/crush.log"), PathRole::Ignore);
}
