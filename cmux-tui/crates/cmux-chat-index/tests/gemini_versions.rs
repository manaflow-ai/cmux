//! Gemini CLI history before and beside chat recording: `/chat save`
//! checkpoints (both shapes) and sessions only `logs.json` remembers.

mod common;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write, write_jsonl};
use serde_json::json;

#[test]
fn checkpoints_in_both_shapes_are_chats_named_by_their_tag() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("tmp/my-project");
    write(&project.join(".project_root"), "/work/my-project");
    let turns = json!([
        {"role":"user","parts":[{"text":"hello"}]},
        {"role":"model","parts":[{"text":"hi"}]},
        {"role":"user","parts":[{"text":"more"}]}
    ]);
    // Before v0.16: a bare Content[].
    write(&project.join("checkpoint-old%20plan.json"), &turns.to_string());
    // v0.16+: {history, authType}.
    write(
        &project.join("checkpoint-new.json"),
        &json!({"history": turns, "authType": "oauth-personal"}).to_string(),
    );
    let chats = by_id(&scan(AdapterKind::Gemini, dir.path()));
    let old = &chats["checkpoint:my-project/old%20plan"];
    assert_eq!(
        (old.title.as_deref(), old.title_source),
        (Some("old plan"), Some(TitleSource::Custom))
    );
    assert_eq!(old.message_count, Some(3));
    assert_eq!(old.cwd.as_deref(), Some("/work/my-project"));
    assert_eq!(old.resume, Resume::ReadOnly);
    assert_eq!(chats["checkpoint:my-project/new"].message_count, Some(3));
}

#[test]
fn sessions_only_logs_json_remembers_are_listed_once() {
    let dir = tempfile::tempdir().unwrap();
    let project = dir.path().join("tmp/0f0e0d");
    let log = |session: &str, at: &str, text: &str| json!({"sessionId":session,"messageId":0,"timestamp":at,"type":"user","message":text});
    write(
        &project.join("logs.json"),
        &json!([
            log("s-old", "2025-06-25T10:00:00.000Z", "/help"),
            log("s-old", "2025-06-25T10:01:00.000Z", "explain the build"),
            log("s-old", "2025-06-25T10:05:00.000Z", "and the tests"),
            log("s-recorded", "2025-09-01T10:00:00.000Z", "recorded too"),
        ])
        .to_string(),
    );
    write_jsonl(
        &project.join("chats/session-2025-09-01T10-00-s-rec.jsonl"),
        &[
            json!({"sessionId":"s-recorded","projectHash":"h","startTime":"2025-09-01T10:00:00.000Z","lastUpdated":"2025-09-01T10:10:00.000Z"}),
            json!({"id":"m1","type":"user","content":"recorded too"}),
        ],
    );
    let scan = scan(AdapterKind::Gemini, dir.path());
    assert_eq!(ids(&scan), ["s-old", "s-recorded"].map(String::from).into());
    let old = &by_id(&scan)["s-old"];
    assert_eq!(
        (old.title.as_deref(), old.title_source),
        (Some("explain the build"), Some(TitleSource::Prompt))
    );
    assert_eq!(old.message_count, Some(3));
    assert_eq!((old.created_ms, old.updated_ms), (Some(1_750_845_600_000), 1_750_845_900_000));
    assert_eq!(old.source_path, project.join("logs.json"));
}

#[test]
fn checkpoints_are_sessions_and_logs_are_store_events() {
    let root = std::path::Path::new("/h/.gemini");
    let classify = |rel: &str| classify_path(AdapterKind::Gemini, root, &root.join(rel));
    assert_eq!(classify("tmp/p/checkpoint-x.json"), PathRole::Session);
    assert_eq!(classify("tmp/p/chats/session-1.jsonl"), PathRole::Session);
    assert_eq!(classify("tmp/p/logs.json"), PathRole::Store);
    assert_eq!(classify("tmp/p/chats/parent/agent.jsonl"), PathRole::Ignore);
}
