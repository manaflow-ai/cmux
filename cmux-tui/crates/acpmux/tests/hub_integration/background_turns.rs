//! A turn the person did not start (acpmux `hub/background_turn.rs`): Claude Code runs one of its
//! own for a task notification while the chat is idle. It is bracketed by `background_turn`
//! records, it never marks the chat unread or moves its `lastTurn`, and its words stay off the
//! chat's preview. Leo, 2026-10-31, about "Nothing new for you yet.": "why do you guys keep
//! sending me this/get pinged to send this".

use super::claude_subagents::wait_for;
use super::*;

/// The chat's records of `kind`.
fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

/// Runs a person's turn, hides the chat, then lets Claude Code run its own turn saying `text`;
/// returns the hub, the chat id and the summary before the own turn.
#[cfg(unix)]
async fn own_turn_saying(text: &str) -> (Arc<Hub>, String, Value, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-bgturn-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let gate = root.join("gate");
    let path = std::ffi::CString::new(gate.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(path.as_ptr(), 0o600) }, 0);
    let (hub, mut c) = claude_setup(&claude, &[]).await;
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    // The person's turn ends in view: read.
    c.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    let mut events = hub.subscribe();
    let said = format!("own-turn: {} :: {text}", gate.display());
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": said}]});
    c.request(method::SESSION_PROMPT, prompt).await.unwrap();
    c.request("_acpmux/view", json!({"sessionId": id, "visible": false})).await.unwrap();
    let before = hub.session_summary(&session);
    assert_eq!(before["unread"], false, "{before}");

    let g = gate.clone();
    tokio::task::spawn_blocking(move || std::fs::write(g, b"go")).await.unwrap().unwrap();
    wait_for(&mut events, "the own turn never ended", || {
        records(&hub, &id, "background_turn").iter().any(|r| r["reason"] == "result")
    })
    .await;
    (hub, id, before, root)
}

/// "Nothing new for you yet." after a task notification: one quiet background turn, no ping.
#[cfg(unix)]
#[tokio::test]
async fn a_task_notification_turn_with_nothing_to_say_is_quiet_and_never_pings() {
    let (hub, id, before, root) = own_turn_saying("Nothing new for you yet.").await;
    let session = hub.resolve(&id).unwrap();
    let marks = records(&hub, &id, "background_turn");
    assert_eq!(marks.len(), 2, "{marks:?}");
    assert_eq!(marks[0]["state"], "started");
    assert_eq!(marks[0]["trigger"], "task_notification");
    assert_eq!(marks[1]["id"], marks[0]["id"]);
    assert_eq!(marks[1]["quiet"], true, "{marks:?}");
    assert_eq!(marks[1]["reason"], "result");
    // Its words are between the two records.
    let events = hub.events(&id, 0, 10_000).unwrap();
    let at = |state: &str| {
        events.iter().find(|e| e.kind == "background_turn" && e.msg["state"] == state).unwrap().seq
    };
    let (start, end) = (at("started"), at("ended"));
    assert!(
        events.iter().any(|e| e.kind == "agent_message_chunk" && e.seq > start && e.seq < end),
        "its words are inside it"
    );
    let after = hub.session_summary(&session);
    assert_eq!(after["unread"], false, "a turn the person did not start never marks it: {after}");
    assert_eq!(after["lastTurn"], before["lastTurn"], "no acpmux turn ended: {after}");
    assert_eq!(
        after["lastMessage"], before["lastMessage"],
        "its words stay off the preview: {after}"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// A background turn with something to say draws in full, and still never pings.
#[cfg(unix)]
#[tokio::test]
async fn a_background_turn_with_something_to_say_is_not_quiet_and_never_pings() {
    let text = "Merged #12 at abc123.\nThe nightly built from it is green.";
    let (hub, id, before, root) = own_turn_saying(text).await;
    let session = hub.resolve(&id).unwrap();
    let marks = records(&hub, &id, "background_turn");
    assert_eq!(marks[1]["quiet"], false, "{marks:?}");
    let after = hub.session_summary(&session);
    assert_eq!(after["unread"], false, "{after}");
    assert_eq!(after["lastTurn"], before["lastTurn"], "{after}");
    let _ = std::fs::remove_dir_all(root);
}
