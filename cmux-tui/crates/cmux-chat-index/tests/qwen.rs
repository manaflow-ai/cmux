mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path, read_file};
use common::{append_jsonl, by_id, ids, scan, write, write_jsonl};
use serde_json::{Value, json};

const A: &str = "0b6c1a2e-0000-4000-8000-00000000000a";
const B: &str = "0b6c1a2e-0000-4000-8000-00000000000b";

fn record(kind: &str, uuid: &str, extra: Value) -> Value {
    let mut base = json!({"uuid":uuid,"parentUuid":null,"sessionId":A,"timestamp":"2026-10-01T10:00:00.000Z",
                          "type":kind,"cwd":"/w/p","version":"0.9.0"});
    if let (Some(base), Some(extra)) = (base.as_object_mut(), extra.as_object()) {
        base.extend(extra.clone());
    }
    base
}

fn user(uuid: &str, text: &str) -> Value {
    record("user", uuid, json!({"message":{"role":"user","parts":[{"text":text}]}}))
}

fn title(text: &str, source: &str) -> Value {
    record(
        "system",
        "t",
        json!({"subtype":"custom_title","systemPayload":{"customTitle":text,"titleSource":source}}),
    )
}

#[test]
fn v2_jsonl_sessions_count_messages_and_take_the_last_custom_title() {
    let dir = tempfile::tempdir().unwrap();
    let chats = dir.path().join("projects/-w-p/chats");
    let path = chats.join(format!("{A}.jsonl"));
    write_jsonl(
        &path,
        &[
            user("u1", "fix the bug\nplease"),
            record("assistant", "a1", json!({"message":{"role":"model","parts":[{"text":"ok"}]}})),
            record(
                "tool_result",
                "r1",
                json!({"message":{"role":"user","parts":[{"text":"out"}]}}),
            ),
            record("system", "s1", json!({"subtype":"chat_compression"})),
            title("Auto name", "auto"),
            user("u2", "again"),
            title("Fix bug", "manual"),
        ],
    );
    // An archived session whose title is generated.
    let archived = chats.join("archive").join(format!("{B}.jsonl"));
    let mut first = user("u1", "archived prompt");
    first["sessionId"] = json!(B);
    write_jsonl(&archived, &[first, title("Generated", "auto")]);
    // Not a session file name.
    write(&chats.join("notes.jsonl"), "{}\n");
    write(&chats.join(format!("{A}.runtime.json")), "{}");

    let scan = scan(AdapterKind::QwenCode, dir.path());
    assert_eq!(ids(&scan), [A, B].map(String::from).into());
    let all = by_id(&scan);
    let a = &all[A];
    assert_eq!(a.message_count, Some(3));
    assert_eq!((a.title.as_deref(), a.title_source), (Some("Fix bug"), Some(TitleSource::Custom)));
    assert_eq!(a.cwd.as_deref(), Some("/w/p"));
    assert_eq!(a.created_ms, Some(1_790_848_800_000));
    assert!(!a.archived);
    assert_eq!(
        a.resume,
        Resume::Argv { argv: vec!["qwen".into(), "--resume".into(), A.into()], cwd_needed: true }
    );
    let b = &all[B];
    assert!(b.archived);
    assert_eq!((b.title.as_deref(), b.title_source), (Some("Generated"), Some(TitleSource::Ai)));

    // Appended lines are counted from the last offset.
    let read = read_file(AdapterKind::QwenCode, &path, None).unwrap();
    append_jsonl(&path, &[user("u3", "third")]);
    let next = read_file(AdapterKind::QwenCode, &path, Some(&read.state)).unwrap();
    assert_eq!(next.entry.unwrap().message_count, Some(4));
}

#[test]
fn v2_without_a_title_uses_the_typed_prompt() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("projects/-w-p/chats").join(format!("{A}.jsonl"));
    let mut shown = user("u1", "@file expanded text");
    shown["systemPayload"] = json!({"displayText":"what I typed"});
    write_jsonl(&path, &[shown]);
    let chat = by_id(&scan(AdapterKind::QwenCode, dir.path())).remove(A).unwrap();
    assert_eq!(
        (chat.title.as_deref(), chat.title_source),
        (Some("what I typed"), Some(TitleSource::Prompt))
    );
}

#[test]
fn v1_legacy_gemini_format_sessions_are_listed_as_qwen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir
        .path()
        .join("tmp/9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08/chats")
        .join("session-2025-08-01T10-00-abcd1234.json");
    write(
        &path,
        &json!({"sessionId":"legacy-1","projectHash":"9f86","startTime":"2025-08-01T10:00:00.000Z",
                "lastUpdated":"2025-08-01T10:05:00.000Z","messages":[
                    {"id":"m1","timestamp":"2025-08-01T10:00:00.000Z","type":"user","content":"legacy prompt"},
                    {"id":"m2","timestamp":"2025-08-01T10:01:00.000Z","type":"qwen","content":"ok"}
                ]})
        .to_string(),
    );
    let chat = by_id(&scan(AdapterKind::QwenCode, dir.path())).remove("legacy-1").unwrap();
    assert_eq!(chat.harness, AdapterKind::QwenCode);
    assert_eq!(chat.title.as_deref(), Some("legacy prompt"));
    assert_eq!(chat.message_count, Some(2));
    assert_eq!(chat.created_ms, Some(1_754_042_400_000));
}

#[test]
fn qwen_paths_classify() {
    let root = Path::new("/q");
    let role = |rel: &str| classify_path(AdapterKind::QwenCode, root, &root.join(rel));
    assert_eq!(role(&format!("projects/-w/chats/{A}.jsonl")), PathRole::Session);
    assert_eq!(role(&format!("projects/-w/chats/archive/{A}.jsonl")), PathRole::Session);
    assert_eq!(role("tmp/h/chats/session-2025-08-01T10-00-abcd1234.json"), PathRole::Session);
    assert_eq!(role("tmp/h/logs.json"), PathRole::Store);
    assert_eq!(role(&format!("projects/-w/chats/{A}.runtime.json")), PathRole::Ignore);
    assert_eq!(role("settings.json"), PathRole::Ignore);
}
