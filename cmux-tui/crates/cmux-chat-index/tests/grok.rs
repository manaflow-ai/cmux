mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write};
use serde_json::{Value, json};

fn summary(root: &Path, group: &str, id: &str, value: &Value) -> std::path::PathBuf {
    let path = root.join(group).join(id).join("summary.json");
    write(&path, &value.to_string());
    path
}

fn base(id: &str, cwd: &str) -> Value {
    json!({
        "info": {"id": id, "cwd": cwd},
        "session_summary": "fix the flaky test",
        "created_at": "2026-10-01T10:00:00Z",
        "updated_at": "2026-10-01T11:00:00Z",
        "num_messages": 9,
        "num_chat_messages": 4,
        "current_model_id": "grok-code",
        "chat_format_version": 1
    })
}

#[test]
fn summaries_give_titles_folders_times_and_counts() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut generated = base("g-1", "/work/app");
    generated["generated_title"] = json!("Fix flaky test");
    generated["last_active_at"] = json!("2026-10-01T12:00:00Z");
    summary(root, "%2Fwork%2Fapp", "g-1", &generated);
    let mut manual = base("g-2", "/work/app");
    manual["generated_title"] = json!("My name");
    manual["title_is_manual"] = json!(true);
    summary(root, "%2Fwork%2Fapp", "g-2", &manual);
    // chat_format_version 0 (legacy) with only a summary and no chat count.
    let mut legacy = base("g-3", "");
    legacy["chat_format_version"] = json!(0);
    legacy.as_object_mut().unwrap().remove("num_chat_messages");
    summary(root, "long-name-abc123", "g-3", &legacy);
    write(&root.join("long-name-abc123/.cwd"), "/very/long/path\n");

    let scan = scan(AdapterKind::Grok, root);
    let chats = by_id(&scan);
    let g1 = &chats["g-1"];
    assert_eq!(
        (g1.title.as_deref(), g1.title_source),
        (Some("Fix flaky test"), Some(TitleSource::Ai))
    );
    assert_eq!(g1.cwd.as_deref(), Some("/work/app"));
    assert_eq!(g1.created_ms, Some(1_790_848_800_000));
    assert_eq!(g1.updated_ms, 1_790_856_000_000, "last_active_at is later");
    assert_eq!(g1.message_count, Some(4));
    assert_eq!(g1.resume, Resume::ReadOnly);
    assert_eq!(chats["g-2"].title_source, Some(TitleSource::Custom));
    let g3 = &chats["g-3"];
    assert_eq!(
        (g3.title.as_deref(), g3.title_source),
        (Some("fix the flaky test"), Some(TitleSource::Ai))
    );
    assert_eq!(g3.cwd.as_deref(), Some("/very/long/path"));
    assert_eq!(g3.message_count, Some(9));
}

#[test]
fn hidden_subagent_and_nested_sessions_are_not_chats_but_forks_are() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let mut hidden = base("h", "/w");
    hidden["hidden"] = json!(true);
    summary(root, "g", "h", &hidden);
    let mut child = base("c", "/w");
    child["parent_session_id"] = json!("p");
    summary(root, "g", "c", &child);
    let mut fork = base("f", "/w");
    fork["parent_session_id"] = json!("p");
    fork["forked_at"] = json!("2026-10-01T10:30:00Z");
    summary(root, "g", "f", &fork);
    summary(root, "g", "p", &base("p", "/w"));
    write(&root.join("g/p/subagents/s1/summary.json"), &base("s1", "/w").to_string());
    write(&root.join("g/broken/summary.json"), "{not json");
    assert_eq!(ids(&scan(AdapterKind::Grok, root)), ["f", "p"].map(String::from).into());
}

#[test]
fn only_summary_files_are_session_paths() {
    let root = Path::new("/r");
    let role = |rel: &str| classify_path(AdapterKind::Grok, root, &root.join(rel));
    assert_eq!(role("g/id/summary.json"), PathRole::Session);
    assert_eq!(role("g/id/chat_history.jsonl"), PathRole::Ignore);
    assert_eq!(role("g/id/subagents/s/summary.json"), PathRole::Ignore);
}
