mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write};
use rusqlite::{Connection, params};
use serde_json::{Value, json};

fn write_json(path: &Path, value: &Value) {
    write(path, &value.to_string());
}

fn ui_messages(task: &str, ts: i64) -> Value {
    json!([
        {"ts": ts, "type": "say", "say": "task", "text": task},
        {"ts": ts + 5, "type": "say", "say": "text", "text": "working"}
    ])
}

#[test]
fn cline_tasks_before_3_28_are_named_by_their_first_ui_message() {
    let dir = tempfile::tempdir().unwrap();
    let tasks = dir.path().join("tasks");
    write_json(
        &tasks.join("1700000000000/ui_messages.json"),
        &ui_messages("build the parser\nfast", 1_700_000_000_000),
    );
    write_json(&tasks.join("1700000000000/api_conversation_history.json"), &json!([]));
    // Cline before 2.2 called the file claude_messages.json.
    write_json(
        &tasks.join("1600000000000/claude_messages.json"),
        &ui_messages("old task", 1_600_000_000_000),
    );
    let scan = scan(AdapterKind::Cline, dir.path());
    assert_eq!(ids(&scan), ["1700000000000", "1600000000000"].map(String::from).into());
    let chats = by_id(&scan);
    let task = &chats["1700000000000"];
    assert_eq!(task.harness, AdapterKind::Cline);
    assert_eq!(
        (task.title.as_deref(), task.title_source),
        (Some("build the parser"), Some(TitleSource::Prompt))
    );
    assert_eq!(task.created_ms, Some(1_700_000_000_000));
    assert_eq!(task.resume, Resume::ReadOnly);
    assert_eq!(chats["1600000000000"].title.as_deref(), Some("old task"));
}

#[test]
fn cline_task_history_json_wins_over_task_dirs_and_skips_subtasks() {
    let dir = tempfile::tempdir().unwrap();
    write_json(
        &dir.path().join("state/taskHistory.json"),
        &json!([
            {"id":"t1","ts":1_790_852_400_000_i64,"task":"from the index","tokensIn":1,"tokensOut":2,
             "totalCost":0.1,"cwdOnTaskInitialization":"/work/app"},
            {"id":"t2","ts":5,"task":"subtask","parentTaskId":"t1"}
        ]),
    );
    write_json(&dir.path().join("tasks/t1/ui_messages.json"), &ui_messages("from the dir", 1));
    write_json(&dir.path().join("tasks/t3/ui_messages.json"), &ui_messages("not indexed", 7));
    let scan = scan(AdapterKind::Cline, dir.path());
    assert_eq!(ids(&scan), ["t1", "t3"].map(String::from).into());
    let chats = by_id(&scan);
    let t1 = &chats["t1"];
    assert_eq!(t1.title.as_deref(), Some("from the index"));
    assert_eq!(t1.cwd.as_deref(), Some("/work/app"));
    assert_eq!(t1.updated_ms, 1_790_852_400_000);
    assert_eq!(t1.source_path, dir.path().join("state/taskHistory.json"));
    assert_eq!(chats["t3"].title.as_deref(), Some("not indexed"));
}

#[test]
fn the_cline_sdk_session_db_comes_first_and_drops_subagents() {
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("db/sessions.db");
    std::fs::create_dir_all(db_path.parent().unwrap()).unwrap();
    let db = Connection::open(&db_path).unwrap();
    db.execute_batch(
        "CREATE TABLE sessions (session_id TEXT PRIMARY KEY, source TEXT NOT NULL, started_at TEXT NOT NULL,
           ended_at TEXT, status TEXT NOT NULL, cwd TEXT NOT NULL, workspace_root TEXT NOT NULL,
           parent_session_id TEXT, is_subagent INTEGER NOT NULL DEFAULT 0, prompt TEXT,
           metadata_json TEXT, updated_at TEXT NOT NULL);",
    )
    .unwrap();
    let insert = |id: &str, parent: Option<&str>, sub: i64, prompt: &str, meta: Option<&str>| {
        db.execute(
            "INSERT INTO sessions VALUES (?1, 'cli', '2026-10-01T10:00:00.000Z', NULL, 'done', '/work/sdk',
               '/work', ?2, ?3, ?4, ?5, '2026-10-01T11:00:00.000Z')",
            params![id, parent, sub, prompt, meta],
        )
        .unwrap();
    };
    insert("s1", None, 0, "typed prompt", Some(r#"{"title":"SDK title"}"#));
    insert("s2", None, 0, "only a prompt\nsecond line", Some("not json"));
    insert("s3", Some("s1"), 0, "child", None);
    insert("s4", None, 1, "subagent", None);
    // The same id in the older JSON index is the same task.
    write_json(
        &dir.path().join("state/taskHistory.json"),
        &json!([{"id":"s1","ts":1,"task":"stale"}]),
    );
    let scan = scan(AdapterKind::Cline, dir.path());
    assert_eq!(ids(&scan), ["s1", "s2"].map(String::from).into());
    let chats = by_id(&scan);
    let s1 = &chats["s1"];
    assert_eq!((s1.title.as_deref(), s1.title_source), (Some("SDK title"), Some(TitleSource::Ai)));
    assert_eq!(s1.cwd.as_deref(), Some("/work/sdk"));
    assert_eq!((s1.created_ms, s1.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(s1.source_path, db_path);
    let s2 = &chats["s2"];
    assert_eq!(
        (s2.title.as_deref(), s2.title_source),
        (Some("only a prompt"), Some(TitleSource::Prompt))
    );
}

#[test]
fn roo_code_index_and_history_item_files() {
    let dir = tempfile::tempdir().unwrap();
    write_json(
        &dir.path().join("tasks/_index.json"),
        &json!({"version":1,"updatedAt":3,"entries":[
            {"id":"r1","number":1,"ts":100,"task":"indexed roo task","workspace":"/work/roo","mode":"code"},
            {"id":"r9","number":2,"ts":101,"task":"child","parentTaskId":"r1"}
        ]}),
    );
    write_json(
        &dir.path().join("tasks/r2/history_item.json"),
        &json!({"id":"r2","number":3,"ts":200,"task":"per-task item","workspace":"/work/two"}),
    );
    write_json(&dir.path().join("tasks/r1/ui_messages.json"), &ui_messages("ignored", 1));
    let scan = scan(AdapterKind::RooCode, dir.path());
    assert_eq!(ids(&scan), ["r1", "r2"].map(String::from).into());
    let chats = by_id(&scan);
    assert_eq!(chats["r1"].harness, AdapterKind::RooCode);
    assert_eq!(chats["r1"].cwd.as_deref(), Some("/work/roo"));
    assert_eq!(chats["r2"].title.as_deref(), Some("per-task item"));
    assert_eq!(chats["r2"].updated_ms, 200);
}

#[test]
fn kilo_code_legacy_cli_global_state() {
    let dir = tempfile::tempdir().unwrap();
    write_json(
        &dir.path().join("global-state.json"),
        &json!({"taskHistory":[{"id":"k1","ts":300,"task":"kilo task","workspace":"/work/kilo"}],
                "mode":"code"}),
    );
    let scan = scan(AdapterKind::KiloCode, dir.path());
    let chat = by_id(&scan).remove("k1").unwrap();
    assert_eq!((chat.harness, chat.title.as_deref()), (AdapterKind::KiloCode, Some("kilo task")));
    assert_eq!(chat.cwd.as_deref(), Some("/work/kilo"));
}

#[test]
fn task_store_paths_classify_as_store_changes() {
    let root = Path::new("/g");
    let role = |rel: &str| classify_path(AdapterKind::Cline, root, &root.join(rel));
    assert_eq!(role("state/taskHistory.json"), PathRole::Store);
    assert_eq!(role("tasks/_index.json"), PathRole::Store);
    // A new task dir rescans; its streamed message files do not.
    assert_eq!(role("tasks/t1"), PathRole::Store);
    assert_eq!(role("tasks/t1/ui_messages.json"), PathRole::Ignore);
    assert_eq!(role("db/sessions.db-wal"), PathRole::Store);
    assert_eq!(role("global-state.json"), PathRole::Store);
    assert_eq!(role("tasks/t1/api_conversation_history.json"), PathRole::Ignore);
    assert_eq!(role("checkpoints/x"), PathRole::Ignore);
}
