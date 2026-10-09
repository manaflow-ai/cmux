//! Claude Code store variants beyond the plain JSONL session: NUL padding,
//! `/cd` relocation, `continued-in`, the custom-title sidecar, the 1.0.28
//! XDG config dir, and the 0.2.90-0.2.109 SQLite store.

mod common;

use cmux_chat_index::{AdapterKind, Resume, TitleSource};
use common::{by_id, ids, jsonl, scan, write, write_jsonl};
use rusqlite::{Connection, params};
use serde_json::json;

const A: &str = "aaaa0000-0000-4000-8000-00000000000a";
const B: &str = "bbbb0000-0000-4000-8000-00000000000b";
const C: &str = "cccc0000-0000-4000-8000-00000000000c";

fn user(text: &str) -> serde_json::Value {
    json!({"type":"user","cwd":"/work/app","timestamp":"2026-10-01T10:00:00.000Z",
           "message":{"role":"user","content":text}})
}

#[test]
fn nul_padded_lines_relocation_and_the_title_sidecar_are_read() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("-work-app");
    let mut text = String::from("\0\0\0");
    text.push_str(&jsonl(&[
        user("padded first prompt"),
        json!({"type":"relocated","relocatedCwd":"/work/moved"}),
    ]));
    write(&project.join(format!("{A}.jsonl")), &text);
    write_jsonl(&project.join(format!("{B}.jsonl")), &[user("prompt b")]);
    write(
        &project.join(B).join("custom-title.json"),
        &json!({"customTitle":"Sidecar name"}).to_string(),
    );

    let chats = by_id(&scan(AdapterKind::ClaudeCode, dir.path()));
    let a = &chats[A];
    assert_eq!(a.title.as_deref(), Some("padded first prompt"));
    assert_eq!(a.cwd.as_deref(), Some("/work/moved"));
    assert_eq!(a.message_count, Some(1));
    let b = &chats[B];
    assert_eq!(
        (b.title.as_deref(), b.title_source),
        (Some("Sidecar name"), Some(TitleSource::Custom))
    );
}

#[test]
fn a_session_continued_in_another_is_left_out() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("-work-app");
    write_jsonl(
        &project.join(format!("{A}.jsonl")),
        &[user("old"), json!({"type":"continued-in","continuedInSessionId":B})],
    );
    write_jsonl(&project.join(format!("{B}.jsonl")), &[user("continuation")]);
    assert_eq!(ids(&scan(AdapterKind::ClaudeCode, dir.path())), [B.to_owned()].into());
}

#[test]
fn the_sqlite_store_of_claude_0_2_90_lists_its_sessions_beside_jsonl() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join(".claude");
    let projects = config.join("projects");
    write_jsonl(&projects.join("-work-app").join(format!("{A}.jsonl")), &[user("jsonl chat")]);
    let conn = Connection::open(config.join("__store.db")).unwrap();
    // drizzle migrations 0000-0002 shipped in @anthropic-ai/claude-code 0.2.90.
    conn.execute_batch(
        "CREATE TABLE base_messages (uuid TEXT PRIMARY KEY, parent_uuid TEXT, session_id TEXT NOT NULL,
           timestamp INTEGER NOT NULL, message_type TEXT NOT NULL, cwd TEXT NOT NULL, user_type TEXT NOT NULL,
           version TEXT NOT NULL, isSidechain INTEGER NOT NULL);
         CREATE TABLE user_messages (uuid TEXT PRIMARY KEY, message TEXT NOT NULL, tool_use_result TEXT,
           timestamp INTEGER NOT NULL);
         CREATE TABLE conversation_summaries (leaf_uuid TEXT PRIMARY KEY, summary TEXT NOT NULL,
           updated_at INTEGER NOT NULL);",
    )
    .unwrap();
    let row = |uuid: &str, session: &str, at: i64, kind: &str, side: i64| {
        conn.execute(
            "INSERT INTO base_messages VALUES (?1, NULL, ?2, ?3, ?4, '/work/old', 'external', '0.2.90', ?5)",
            params![uuid, session, at, kind, side],
        )
        .unwrap();
    };
    row("u1", C, 1_746_000_000, "user", 0);
    row("u2", C, 1_746_000_060, "assistant", 0);
    row("u3", C, 1_746_000_120, "user", 0);
    row("s1", C, 1_746_000_130, "user", 1);
    conn.execute(
        "INSERT INTO user_messages VALUES ('u1', ?1, NULL, 1746000000)",
        [json!({"role":"user","content":"sqlite era prompt"}).to_string()],
    )
    .unwrap();
    // A session id that also has a JSONL file is listed once, from JSONL.
    row("x1", A, 1_746_000_000, "user", 0);

    let scan = scan(AdapterKind::ClaudeCode, &projects);
    assert_eq!(ids(&scan), [A, C].map(String::from).into());
    let chats = by_id(&scan);
    assert_eq!(chats[A].title.as_deref(), Some("jsonl chat"));
    let old = &chats[C];
    assert_eq!(
        (old.title.as_deref(), old.title_source),
        (Some("sqlite era prompt"), Some(TitleSource::Prompt))
    );
    assert_eq!(old.cwd.as_deref(), Some("/work/old"));
    assert_eq!(old.message_count, Some(3));
    assert_eq!((old.created_ms, old.updated_ms), (Some(1_746_000_000_000), 1_746_000_120_000));
    assert_eq!(old.resume, Resume::ReadOnly);
    assert_eq!(old.source_path, config.join("__store.db"));
}
