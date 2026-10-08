mod common;

use cmux_chat_index::{AdapterKind, Resume, TitleSource};
use common::{by_id, ids, scan, write, write_jsonl};
use serde_json::{Value, json};

fn meta(id: &str, kind: &str) -> Value {
    json!({"sessionId":id,"projectHash":"h","startTime":"2026-10-01T10:00:00.000Z",
           "lastUpdated":"2026-10-01T10:05:00.000Z","kind":kind})
}

fn msg(id: &str, kind: &str, content: Value) -> Value {
    json!({"id":id,"timestamp":"2026-10-01T10:01:00.000Z","type":kind,"content":content})
}

#[test]
fn set_and_rewind_records_shape_title_count_and_times() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("tmp/my-project");
    write(&project.join(".project_root"), "/work/my-project\n");
    write_jsonl(
        &project.join("chats/session-2026-10-01T10-00-aaaa1111.jsonl"),
        &[
            meta("aaaa1111-0000-4000-8000-000000000001", "main"),
            msg("m1", "user", json!("hello gemini")),
            msg("m2", "gemini", json!("hi")),
            msg("m3", "user", json!("second")),
            msg("m4", "gemini", json!("again")),
            json!({"$rewindTo":"m3"}),
            json!({"$set":{"summary":"Gemini summary","lastUpdated":"2026-10-01T11:00:00.000Z"}}),
        ],
    );
    let entry = by_id(&scan(AdapterKind::Gemini, dir.path()))
        .remove("aaaa1111-0000-4000-8000-000000000001")
        .unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Gemini summary"), Some(TitleSource::Ai))
    );
    assert_eq!(entry.message_count, Some(2));
    assert_eq!(entry.cwd.as_deref(), Some("/work/my-project"));
    assert_eq!(entry.created_ms, Some(1_790_848_800_000));
    assert_eq!(entry.updated_ms, 1_790_852_400_000);
    let argv =
        ["gemini", "--resume", "aaaa1111-0000-4000-8000-000000000001"].map(String::from).to_vec();
    assert_eq!(entry.resume, Resume::Argv { argv, cwd_needed: true });
}

#[test]
fn without_a_summary_the_first_user_message_is_the_title() {
    let dir = tempfile::tempdir().unwrap();
    write_jsonl(
        &dir.path().join("tmp/p/chats/session-2026-10-01T10-00-bbbb2222.jsonl"),
        &[meta("bbbb2222", "main"), msg("m1", "user", json!([{"text":"list the files\nplease"}]))],
    );
    let chats = by_id(&scan(AdapterKind::Gemini, dir.path()));
    assert_eq!(
        (chats["bbbb2222"].title.as_deref(), chats["bbbb2222"].title_source),
        (Some("list the files"), Some(TitleSource::Prompt))
    );
    assert_eq!(chats["bbbb2222"].cwd, None);
}

#[test]
fn subagent_sessions_are_skipped() {
    let dir = tempfile::tempdir().unwrap();
    let chats = dir.path().join("tmp/p/chats");
    write_jsonl(
        &chats.join("session-2026-10-01T10-00-cccc3333.jsonl"),
        &[meta("cccc3333", "main"), msg("m1", "user", json!("x"))],
    );
    write_jsonl(
        &chats.join("session-2026-10-01T10-01-dddd4444.jsonl"),
        &[meta("dddd4444", "subagent"), msg("m1", "user", json!("x"))],
    );
    write_jsonl(
        &chats.join("cccc3333/session-2026-10-01T10-02-eeee5555.jsonl"),
        &[meta("eeee5555", "main"), msg("m1", "user", json!("x"))],
    );
    assert_eq!(ids(&scan(AdapterKind::Gemini, dir.path())), ["cccc3333".to_owned()].into());
}

#[test]
fn legacy_json_sessions_are_read() {
    let dir = tempfile::tempdir().unwrap();
    let legacy = json!({"sessionId":"ffff6666","projectHash":"h","startTime":"2026-10-01T10:00:00.000Z",
        "lastUpdated":"2026-10-01T10:30:00.000Z","messages":[
            {"id":"m1","type":"user","content":"legacy question"},
            {"id":"m2","type":"gemini","content":"answer"}]});
    write(
        &dir.path().join("tmp/p/chats/session-2026-09-01T10-00-ffff6666.json"),
        &legacy.to_string(),
    );
    let chats = by_id(&scan(AdapterKind::Gemini, dir.path()));
    let entry = &chats["ffff6666"];
    assert_eq!(entry.title.as_deref(), Some("legacy question"));
    assert_eq!(entry.message_count, Some(2));
    assert_eq!(entry.updated_ms, 1_790_850_600_000);
}
