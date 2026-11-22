mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, Resume, TitleSource};
use common::{by_id, ids, scan};
use rusqlite::{Connection, params};
use serde_json::json;

fn opencode_db(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.execute_batch(
        "CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT, parent_id TEXT, slug TEXT, directory TEXT,
           title TEXT, version TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
         CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);
         CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT);",
    )
    .unwrap();
    conn
}

fn session(conn: &Connection, id: &str, title: &str, parent: Option<&str>, archived: Option<i64>) {
    conn.execute(
        "INSERT INTO session (id, parent_id, directory, title, time_created, time_updated, time_archived)
         VALUES (?1, ?2, '/work/' || ?1, ?3, 1790848800000, 1790852400000, ?4)",
        params![id, parent, title, archived],
    )
    .unwrap();
}

fn message(conn: &Connection, session: &str, id: &str, at: i64, role: &str, text: Option<&str>) {
    conn.execute(
        "INSERT INTO message (id, session_id, time_created, data) VALUES (?1, ?2, ?3, ?4)",
        params![id, session, at, json!({"role": role}).to_string()],
    )
    .unwrap();
    if let Some(text) = text {
        conn.execute(
            "INSERT INTO part (id, message_id, session_id, time_created, data) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![format!("p-{id}"), id, session, at, json!({"type":"text","text":text}).to_string()],
        )
        .unwrap();
    }
}

#[test]
fn sessions_come_from_the_db_with_placeholder_titles_replaced() {
    let dir = tempfile::tempdir().unwrap();
    let db = opencode_db(&dir.path().join("opencode.db"));
    session(&db, "ses_a", "Refactor parser", None, None);
    message(&db, "ses_a", "m1", 1, "user", Some("please refactor"));
    message(&db, "ses_a", "m2", 2, "assistant", Some("done"));
    message(&db, "ses_a", "m3", 3, "user", Some("thanks"));
    session(&db, "ses_b", "New session - 2026-10-01T10:00:00.000Z", None, None);
    message(&db, "ses_b", "m4", 4, "assistant", Some("hello"));
    message(&db, "ses_b", "m5", 5, "user", Some("add tests\nfor the parser"));
    session(&db, "ses_child", "Subtask", Some("ses_a"), None);
    session(&db, "ses_old", "Archived", None, Some(1_790_900_000_000));
    let channel = opencode_db(&dir.path().join("opencode-beta.db"));
    session(&channel, "ses_beta", "Beta channel chat", None, None);

    let scan = scan(AdapterKind::OpenCode, dir.path());
    assert_eq!(ids(&scan), ["ses_a", "ses_b", "ses_old", "ses_beta"].map(String::from).into());
    let chats = by_id(&scan);
    let a = &chats["ses_a"];
    assert_eq!(
        (a.title.as_deref(), a.title_source),
        (Some("Refactor parser"), Some(TitleSource::Ai))
    );
    assert_eq!(a.message_count, Some(3));
    assert_eq!(a.cwd.as_deref(), Some("/work/ses_a"));
    assert_eq!((a.created_ms, a.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(
        a.resume,
        Resume::Argv {
            argv: vec!["opencode".into(), "-s".into(), "ses_a".into()],
            cwd_needed: true
        }
    );
    assert_eq!(a.source_path, dir.path().join("opencode.db"));
    let b = &chats["ses_b"];
    assert_eq!(
        (b.title.as_deref(), b.title_source),
        (Some("add tests"), Some(TitleSource::Prompt))
    );
    assert!(chats["ses_old"].archived && !a.archived);
}
