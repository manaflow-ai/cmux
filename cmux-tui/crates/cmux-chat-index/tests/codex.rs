mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, Resume, TitleSource};
use common::{by_id, ids, scan, write, write_jsonl};
use rusqlite::Connection;
use serde_json::json;

const T5: &str = "019a0000-0000-7000-8000-000000000005";

fn threads_db(path: &Path, with_name: bool) -> Connection {
    let conn = Connection::open(path).unwrap();
    let name_col = if with_name { "name TEXT," } else { "" };
    conn.execute_batch(&format!(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, created_at INTEGER, updated_at INTEGER,
         cwd TEXT, title TEXT, preview TEXT, first_user_message TEXT, archived INTEGER DEFAULT 0,
         has_user_event INTEGER DEFAULT 1, agent_nickname TEXT, {name_col} originator TEXT);"
    ))
    .unwrap();
    conn
}

struct Row<'a> {
    id: &'a str,
    name: Option<&'a str>,
    title: Option<&'a str>,
    preview: Option<&'a str>,
    archived: bool,
    user_event: bool,
    nickname: Option<&'a str>,
}

impl<'a> Row<'a> {
    fn new(id: &'a str) -> Self {
        Self {
            id,
            name: None,
            title: None,
            preview: None,
            archived: false,
            user_event: true,
            nickname: None,
        }
    }
}

fn thread(conn: &Connection, row: Row<'_>) {
    let originator = (row.id == "t1").then_some("Codex Desktop");
    conn.execute(
        "INSERT INTO threads (id, rollout_path, created_at, updated_at, cwd, title, preview, archived,
         has_user_event, agent_nickname, originator)
         VALUES (?1, '/r/' || ?1 || '.jsonl', 1790848800, 1790852400, '/work/' || ?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        rusqlite::params![row.id, row.title, row.preview, row.archived, row.user_event, row.nickname, originator],
    )
    .unwrap();
    if let Some(name) = row.name {
        conn.execute("UPDATE threads SET name = ?2 WHERE id = ?1", rusqlite::params![row.id, name])
            .unwrap();
    }
}

#[test]
fn the_newest_state_db_gives_threads_with_names_titles_and_filters() {
    let dir = tempfile::tempdir().unwrap();
    let old = threads_db(&dir.path().join("state_4.sqlite"), false);
    thread(&old, Row { title: Some("from old db"), ..Row::new("stale") });
    let db = threads_db(&dir.path().join("state_5.sqlite"), true);
    thread(
        &db,
        Row {
            name: Some("Named"),
            title: Some("AI title"),
            preview: Some("preview"),
            ..Row::new("t1")
        },
    );
    thread(&db, Row { title: Some("AI title"), preview: Some("preview"), ..Row::new("t2") });
    thread(&db, Row { preview: Some("preview text"), ..Row::new("t3") });
    thread(&db, Row { title: Some("no user event"), user_event: false, ..Row::new("t4") });
    thread(&db, Row { title: Some("subagent"), nickname: Some("worker"), ..Row::new("t5") });
    thread(&db, Row { title: Some("archived one"), archived: true, ..Row::new("t6") });
    let scan = scan(AdapterKind::Codex, dir.path());
    assert_eq!(ids(&scan), ["t1", "t2", "t3", "t6"].map(String::from).into());
    let chats = by_id(&scan);
    assert_eq!(
        (chats["t1"].title.as_deref(), chats["t1"].title_source),
        (Some("Named"), Some(TitleSource::Custom))
    );
    assert_eq!(
        (chats["t2"].title.as_deref(), chats["t2"].title_source),
        (Some("AI title"), Some(TitleSource::Ai))
    );
    assert_eq!(
        (chats["t3"].title.as_deref(), chats["t3"].title_source),
        (Some("preview text"), Some(TitleSource::Prompt))
    );
    assert!(chats["t6"].archived && !chats["t1"].archived);
    assert_eq!(chats["t1"].originator.as_deref(), Some("Codex Desktop"));
    assert_eq!(chats["t1"].cwd.as_deref(), Some("/work/t1"));
    assert_eq!(chats["t1"].created_ms, Some(1_790_848_800_000));
    assert_eq!(chats["t1"].updated_ms, 1_790_852_400_000);
    assert_eq!(chats["t1"].source_path, Path::new("/r/t1.jsonl"));
    assert_eq!(chats["t1"].resume, Resume::Adopt);
}

#[test]
fn the_session_index_names_threads_when_the_db_has_no_name_column() {
    let dir = tempfile::tempdir().unwrap();
    let db = threads_db(&dir.path().join("state_5.sqlite"), false);
    thread(&db, Row { title: Some("AI title"), ..Row::new("t2") });
    write_jsonl(
        &dir.path().join("session_index.jsonl"),
        &[
            json!({"id":"t2","thread_name":"first name","updated_at":"2026-10-01T10:00:00Z"}),
            json!({"id":"t2","thread_name":"Renamed","updated_at":"2026-10-01T11:00:00Z"}),
        ],
    );
    let chats = by_id(&scan(AdapterKind::Codex, dir.path()));
    assert_eq!(
        (chats["t2"].title.as_deref(), chats["t2"].title_source),
        (Some("Renamed"), Some(TitleSource::Custom))
    );
}

#[test]
fn without_a_db_rollout_files_are_read_and_zst_has_no_count() {
    let dir = tempfile::tempdir().unwrap();
    let day = dir.path().join("sessions/2026/10/01");
    let path = day.join(format!("rollout-2026-10-01T10-00-00-{T5}.jsonl"));
    write_jsonl(
        &path,
        &[
            json!({"timestamp":"2026-10-01T10:00:00.000Z","type":"session_meta","payload":{
            "id":T5,"cwd":"/work/codex","timestamp":"2026-10-01T10:00:00.000Z","originator":"codex_cli_rs",
            "base_instructions":{"text":"i".repeat(100_000)}}}),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"<environment_context>x</environment_context>"}}),
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"fix the bug"}]}}),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"fix the bug"}}),
            json!({"type":"event_msg","payload":{"type":"agent_message","message":"done"}}),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"thanks"}}),
        ],
    );
    let zst_id = "019a0000-0000-7000-8000-00000000000a";
    write(
        &dir.path()
            .join(format!("archived_sessions/rollout-2026-09-01T08-30-00-{zst_id}.jsonl.zst")),
        "\u{28}\u{b5}/\u{fd} not real zstd",
    );
    write_jsonl(
        &dir.path().join("session_index.jsonl"),
        &[json!({"id":zst_id,"thread_name":"Old work"})],
    );
    let scan = scan(AdapterKind::Codex, dir.path());
    let chats = by_id(&scan);
    let live = &chats[T5];
    assert_eq!(live.title.as_deref(), Some("fix the bug"));
    assert_eq!(live.cwd.as_deref(), Some("/work/codex"));
    assert_eq!(live.created_ms, Some(1_790_848_800_000));
    assert_eq!(live.message_count, Some(3));
    assert_eq!(live.originator.as_deref(), Some("codex_cli_rs"));
    let old = &chats[zst_id];
    assert_eq!(old.message_count, None);
    assert_eq!(old.title.as_deref(), Some("Old work"));
    assert!(old.archived);
    assert_eq!(old.created_ms, Some(1_788_251_400_000));
}
