//! A turn whose agent says nothing (`hub/silent_turn.rs`): past `silentTurnMs`
//! with no word from the agent, the chat logs `turn_silent`.

use super::*;

/// An OpenCode free model that stalls left the chat on "Thinking" with no end
/// and no sign why. A turn whose agent sends nothing past `silentTurnMs` logs
/// `turn_silent` once; a turn whose agent answered and then works quietly (a
/// long command) never does.
#[tokio::test]
async fn a_turn_the_agent_never_answers_says_so_and_a_quiet_working_one_does_not() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.silent_turn_ms = Some(400);
    let id = new_session(&mut c, "silent").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "mute", None)).await;
    let silent = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_silent").await;
    assert_eq!(silent["msg"]["silentMs"], 400, "{silent}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let started = find(&events, "turn_started");
    assert_eq!(silent["msg"]["turnId"], started[0].msg["turnId"], "{silent}");
    assert_eq!(c.response(rid).await.0.unwrap()["stopReason"], "end_turn");

    // An answer at once, then a turn that streams one word and works on: neither is silent.
    c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    c.send(method::SESSION_PROMPT, prompt(&id, "hang", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "working").await;
    tokio::time::sleep(Duration::from_millis(1_200)).await;
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert_eq!(find(&events, "turn_silent").len(), 1, "{:?}", find(&events, "turn_silent"));

    // 0 turns it off.
    hub.config.write().await.silent_turn_ms = Some(0);
    let quiet = new_session(&mut c, "silent-off").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&quiet, "mute", None)).await;
    assert_eq!(c.response(rid).await.0.unwrap()["stopReason"], "end_turn");
    assert!(find(&hub.events(&quiet, 0, 10_000).unwrap(), "turn_silent").is_empty());
}
