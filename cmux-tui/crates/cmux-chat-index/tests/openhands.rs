mod common;

use std::path::Path;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, set_mtime_ms, write};
use serde_json::{Value, json};

fn event(dir: &Path, index: u32, value: &Value) {
    write(&dir.join(format!("events/event-{index:05}-e{index}.json")), &value.to_string());
}

fn user_message(text: &str) -> Value {
    json!({"kind": "MessageEvent", "id": "m", "timestamp": "2026-10-01T10:00:05.000000",
           "source": "user",
           "llm_message": {"role": "user", "content": [{"type": "text", "text": text}]}})
}

#[test]
fn conversations_take_created_from_the_first_event_and_title_from_the_first_user_message() {
    let dir = tempfile::tempdir().unwrap();
    let conv = dir.path().join("0123abcd");
    write(
        &conv.join("base_state.json"),
        &json!({"id": "0123abcd", "workspace": {"kind": "LocalWorkspace", "working_dir": "/w/app"}})
            .to_string(),
    );
    event(
        &conv,
        0,
        &json!({"kind": "SystemPromptEvent", "timestamp": "2026-10-01T10:00:00Z", "source": "agent"}),
    );
    event(
        &conv,
        1,
        &json!({"kind": "MessageEvent", "timestamp": "2026-10-01T10:00:01Z", "source": "agent",
                "llm_message": {"role": "assistant", "content": [{"type": "text", "text": "hi"}]}}),
    );
    write(&conv.join("events/event-00002-bad.json"), "{broken");
    event(&conv, 3, &user_message("fix the parser\nplease"));
    event(&conv, 4, &user_message("second"));
    set_mtime_ms(&conv.join("base_state.json"), 1_000);

    let chats = by_id(&scan(AdapterKind::OpenHands, dir.path()));
    let chat = &chats["0123abcd"];
    assert_eq!(
        (chat.title.as_deref(), chat.title_source),
        (Some("fix the parser"), Some(TitleSource::Prompt))
    );
    assert_eq!(chat.cwd.as_deref(), Some("/w/app"));
    assert_eq!(chat.created_ms, Some(1_790_848_800_000));
    assert!(chat.updated_ms > 1_000, "the events dir is newer than base_state");
    assert_eq!((chat.message_count, chat.resume.clone()), (None, Resume::ReadOnly));
}

#[test]
fn conversations_without_events_or_base_state_are_not_listed() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join("empty/base_state.json"), "{}");
    write(&dir.path().join("no-state/events/event-00000-a.json"), &user_message("x").to_string());
    let only = dir.path().join("only");
    write(&only.join("base_state.json"), "not json");
    event(&only, 0, &user_message("still listed"));
    let scan = scan(AdapterKind::OpenHands, dir.path());
    assert_eq!(ids(&scan), ["only"].map(String::from).into());
    let chat = &by_id(&scan)["only"];
    assert_eq!((chat.title.as_deref(), chat.cwd.as_deref()), (Some("still listed"), None));
}

#[test]
fn base_state_is_the_session_file_and_events_rescan() {
    let root = Path::new("/r");
    let role = |rel: &str| classify_path(AdapterKind::OpenHands, root, &root.join(rel));
    assert_eq!(role("abc/base_state.json"), PathRole::Session);
    assert_eq!(role("abc/events/event-00001-x.json"), PathRole::Ignore);
    assert_eq!(role("abc/other.json"), PathRole::Ignore);
}
