use super::*;
use serde_json::json;

fn chunk(seq: u64, text: &str) -> Value {
    json!({"sessionId": "s", "_meta": {"acpmux": {"seq": seq}},
           "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}})
}

#[test]
fn a_failed_turn_ends_the_turn_and_keeps_its_reason() {
    let mut t = Transcript::default();
    t.apply_event(&json!({"seq": 7, "dir": "mux", "kind": "turn_error",
        "msg": {"code": -32603, "details": {}, "errorKind": "auth.signed_out", "error": "Claude is not signed in"}}));
    assert_eq!(t.turns_ended, 1);
    assert_eq!(t.turn_error.as_deref(), Some("auth.signed_out: Claude is not signed in"));
    // The next turn that ends cleanly clears it.
    t.apply_event(
        &json!({"seq": 8, "dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
    );
    assert_eq!(t.turns_ended, 2);
    assert!(t.turn_error.is_none());
}

#[test]
fn chunks_join_and_a_replay_draws_nothing_twice() {
    let mut t = Transcript::default();
    t.apply_notification("s", "session/update", &chunk(1, "hello "));
    t.apply_notification("s", "session/update", &chunk(2, "world"));
    // The link dropped; attach replays the same records.
    t.apply_notification("s", "session/update", &chunk(1, "hello "));
    t.apply_notification("s", "session/update", &chunk(2, "world"));
    assert_eq!(t.items, vec![Item::Assistant("hello world".into())]);
}

#[test]
fn another_chats_records_are_ignored() {
    let mut t = Transcript::default();
    let mut other = chunk(1, "x");
    other["sessionId"] = json!("other");
    t.apply_notification("s", "session/update", &other);
    assert!(t.items.is_empty());
}

#[test]
fn own_prompt_echo_is_confirmed_not_doubled() {
    let mut t = Transcript::default();
    t.echo_prompt("p1", "hi");
    assert_eq!(t.unconfirmed().len(), 1);
    t.apply_event(&json!({"seq": 5, "dir": "mux", "kind": "user_message",
                          "msg": {"text": "hi\n\nSent-by: x", "promptId": "p1"}}));
    assert_eq!(t.items, vec![Item::User("hi".into())]);
    assert!(t.unconfirmed().is_empty());
}

#[test]
fn accepted_then_echoed_in_the_daemons_shape_is_drawn_once() {
    let mut t = Transcript::default();
    t.echo_prompt("p1", "hi");
    t.apply_notification(
        "s",
        "_acpmux/prompt_accepted",
        &json!({"sessionId": "s", "promptId": "p1"}),
    );
    t.apply_event(&json!({"seq": 6, "dir": "mux", "kind": "user_message",
        "msg": {"_meta": {"_acpmuxMessage": {"message": {"messageId": "p1", "text": "hi\n\nSent-by: x"}}}}}));
    assert_eq!(t.items, vec![Item::User("hi".into())]);
    assert!(t.unconfirmed().is_empty());
}

#[test]
fn someone_elses_prompt_is_drawn_without_provenance() {
    let mut t = Transcript::default();
    t.apply_event(&json!({"seq": 5, "dir": "mux", "kind": "user_message",
                          "msg": {"text": "from my phone\n\nSent-by: phone", "promptId": "zz"}}));
    assert_eq!(t.items, vec![Item::User("from my phone".into())]);
}

#[test]
fn attach_history_in_records_replay_updates() {
    let mut t = Transcript::default();
    t.apply_event(&json!({"seq": 3, "dir": "in", "kind": "session/update",
        "msg": {"method": "session/update", "params": {"update":
            {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read README.md", "status": "pending"}}}}));
    t.apply_event(&json!({"seq": 4, "dir": "in", "kind": "session/update",
        "msg": {"method": "session/update", "params": {"update":
            {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"}}}}));
    assert_eq!(
        t.items,
        vec![Item::Tool {
            id: "t1".into(),
            title: "Read README.md".into(),
            status: "completed".into()
        }]
    );
}
