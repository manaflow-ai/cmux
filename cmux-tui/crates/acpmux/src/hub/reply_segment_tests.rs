//! A reply's segment (`before_agent_update`, stamped as `_meta.acpmux.segment`) is one per message: a turn
//! that starts under a message still streaming (the person's prompt ending a background turn) keeps it, and
//! only another message or a step the pane cuts a reply at (`cuts_reply`) starts a new one.
//!
//! Leo, 2026-11-22 08:25Z (images/1158.png, one reply drawn as two bubbles cut inside `**`): "ok, well. this
//! happened again. you need to help decide what goes on in this case and perfect it."

use super::*;
use crate::config::{Config, StoreMode};
use serde_json::json;
use std::path::Path;

fn chat() -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let meta: SessionMeta = serde_json::from_value(json!({"schema":META_SCHEMA,"id":"segment-chat",
        "name":"segment-chat","harness":"fake","cwd":"/tmp","status":"idle","createdAt":1,"updatedAt":1}))
    .unwrap();
    store.save(&meta).unwrap();
    let hub = Hub::new(cfg, store);
    let session = hub.resolve("segment-chat").unwrap();
    (hub, session)
}

/// The turn acpmux runs now: `Some(id)` a prompt's, `None` none (a background turn).
fn set_turn(session: &Session, turn: Option<&str>) {
    *session.turn.lock().unwrap() = turn.map(|turn_id| TurnInfo {
        trigger: false,
        started_at: 1,
        client: "test".into(),
        prompt_preview: String::new(),
        masked_preview: String::new(),
        turn_id: turn_id.into(),
        prompt_id: format!("prompt-{turn_id}"),
        turn_seq: 1,
        control: Control::Local,
        doing: Default::default(),
        notice: false,
        persons: false,
        accepted: true,
        device: None,
    });
}

fn chunk(hub: &Hub, session: &Arc<Session>, message: Option<&str>, text: &str) -> String {
    let mut update =
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}});
    if let Some(message) = message {
        update["messageId"] = json!(message);
    }
    hub.before_agent_update(session, Some(&json!({ "update": update })))
        .expect("a reply chunk gets a segment")
}

#[test]
fn a_prompt_that_ends_a_background_turn_mid_message_keeps_its_segment() {
    let (hub, session) = chat();
    // The agent writes on its own (no acpmux turn): "**GUI paths:" streams.
    set_turn(&session, None);
    let first = chunk(&hub, &session, Some("msg_bg"), "Two paths matter. **GUI paths:");
    // The person's prompt ends the background turn and starts a turn; the same message goes on.
    set_turn(&session, Some("turn-2"));
    let rest =
        chunk(&hub, &session, Some("msg_bg"), "** includes forking while the daemon restarts.");
    assert_eq!(rest, first, "one message keeps one segment across the turn change");
    // The prompt's own answer is another message: a segment of the new turn.
    let answer = chunk(&hub, &session, Some("msg_answer"), "Checking Codex now.");
    assert_ne!(answer, first);
    assert!(answer.starts_with("turn-2."), "numbered in the turn it starts in: {answer}");
}

#[test]
fn a_step_the_pane_cuts_at_still_starts_a_new_segment_of_one_message() {
    let (hub, session) = chat();
    set_turn(&session, Some("turn-1"));
    let first = chunk(&hub, &session, Some("msg_1"), "Reading the helper.");
    assert_eq!(chunk(&hub, &session, Some("msg_1"), " Still reading."), first);
    // A tool call the person sees cuts the reply (`cuts_reply`).
    hub.before_agent_update(
        &session,
        Some(&json!({"update": {"sessionUpdate": "tool_call", "toolCallId": "c1", "title": "bun test",
            "_meta": {"claude": {"tool": "Bash"}}}})),
    );
    let after = chunk(&hub, &session, Some("msg_1"), "The test passes.");
    assert_ne!(after, first, "text after a call the person sees is a new row");
}

#[test]
fn chunks_with_no_message_id_start_again_at_a_turn_change() {
    let (hub, session) = chat();
    set_turn(&session, Some("turn-1"));
    let first = chunk(&hub, &session, None, "Done.");
    set_turn(&session, Some("turn-2"));
    let next = chunk(&hub, &session, None, "Next.");
    assert_ne!(next, first, "with no message id the turn is all that tells two replies apart");
}
