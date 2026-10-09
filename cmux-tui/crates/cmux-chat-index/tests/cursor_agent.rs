mod common;

use cmux_chat_index::{AdapterKind, Resume, TitleSource};
use common::{by_id, ids, scan, write};
use serde_json::json;

#[test]
fn chats_come_from_meta_json_only() {
    let dir = tempfile::tempdir().unwrap();
    let chat = dir.path().join("0123abcd/chat-1");
    write(
        &chat.join("meta.json"),
        &json!({"cwd":"/work/cursor","name":"Fix login","createdAtMs":1_790_848_800_000_i64,
        "updatedAtMs":1_790_852_400_000_i64,"hasConversation":true})
        .to_string(),
    );
    // store.db holds content blobs and the blob key: unreadable here proves it is never opened.
    write(&chat.join("store.db"), "not for reading");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(chat.join("store.db"), std::fs::Permissions::from_mode(0o000))
            .unwrap();
    }
    write(
        &dir.path().join("0123abcd/chat-empty/meta.json"),
        &json!({"cwd":"/w","hasConversation":false,"updatedAtMs":1}).to_string(),
    );
    write(&dir.path().join("0123abcd/subagent-run/store.db"), "no meta");

    let scan = scan(AdapterKind::CursorAgent, dir.path());
    assert_eq!(ids(&scan), ["chat-1".to_owned()].into());
    let entry = &by_id(&scan)["chat-1"];
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Fix login"), Some(TitleSource::Ai))
    );
    assert_eq!(entry.cwd.as_deref(), Some("/work/cursor"));
    assert_eq!((entry.created_ms, entry.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(entry.message_count, None);
    let argv = ["cursor-agent", "--resume", "chat-1"].map(String::from).to_vec();
    assert_eq!(entry.resume, Resume::Argv { argv, cwd_needed: true });
}

#[test]
fn a_chat_without_meta_json_is_read_from_the_store_meta_row() {
    let dir = tempfile::tempdir().unwrap();
    let chat = dir.path().join("0123abcd/chat-old");
    std::fs::create_dir_all(&chat).unwrap();
    let conn = rusqlite::Connection::open(chat.join("store.db")).unwrap();
    conn.execute_batch(
        "CREATE TABLE blobs (id TEXT PRIMARY KEY, data BLOB); CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);",
    )
    .unwrap();
    let hex = |value: serde_json::Value| -> String {
        value.to_string().bytes().map(|byte| format!("{byte:02x}")).collect()
    };
    conn.execute(
        "INSERT INTO meta VALUES ('0', ?1)",
        [hex(json!({"agentId":"chat-old","name":"Old chat","createdAt":1_790_848_800_i64,"mode":"agent"}))],
    )
    .unwrap();
    drop(conn);
    let sub = dir.path().join("0123abcd/chat-sub");
    std::fs::create_dir_all(&sub).unwrap();
    let conn = rusqlite::Connection::open(sub.join("store.db")).unwrap();
    conn.execute_batch("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);").unwrap();
    conn.execute(
        "INSERT INTO meta VALUES ('0', ?1)",
        [hex(json!({"agentId":"chat-sub","name":"Sub","subagentInfo":{"parent":"chat-old"}}))],
    )
    .unwrap();
    drop(conn);
    write(
        &dir.path().join("0123abcd/chat-subagent/meta.json"),
        &json!({"isSubagent":true,"hasConversation":true,"title":"x"}).to_string(),
    );

    let scan = scan(AdapterKind::CursorAgent, dir.path());
    assert_eq!(ids(&scan), ["chat-old".to_owned()].into());
    let entry = &by_id(&scan)["chat-old"];
    assert_eq!(entry.title.as_deref(), Some("Old chat"));
    assert_eq!(entry.created_ms, Some(1_790_848_800_000), "seconds are scaled to ms");
}
