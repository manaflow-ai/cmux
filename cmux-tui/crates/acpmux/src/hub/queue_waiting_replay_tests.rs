use super::*;
use serde_json::json;

fn rec(seq: u64, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: 0, dir: "mux".into(), kind: kind.into(), msg, host_seq: None }
}

/// A prompt that was queued and then ran as a steer into another turn (its `user_message`
/// names the running turn, not its own) must not wait again after a restore: the agent
/// already read it. Leo, 2026-11-25: queued messages arrived again after a restart.
#[test]
fn a_queued_prompt_that_ran_under_another_turn_does_not_wait_again() {
    let mut waiting = Waiting::default();
    waiting.push(rec(1, "queued", json!({"promptId": "p1", "turnId": "t-own", "prompt": []})));
    waiting.push(rec(2, "queued", json!({"promptId": "p2", "turnId": "t-p2", "prompt": []})));
    // What `restore_queue_after` does for a `user_message` of p1 under the turn it steered.
    waiting.remove_other_turns(&json!("p1"), Some(&json!("t-running")));
    let left: Vec<String> = waiting
        .into_records()
        .iter()
        .filter_map(|e| e.msg.get("promptId").and_then(Value::as_str).map(str::to_owned))
        .collect();
    assert_eq!(left, ["p2"], "only the prompt nothing read waits");
}

/// A record keeps its whole prompt (text, image and resource link blocks) as one unit.
#[test]
fn a_waiting_record_keeps_its_message_and_attachments_together() {
    let prompt = json!([
        {"type": "image", "data": "AAAA", "mimeType": "image/png"},
        {"type": "resource_link", "name": "image.png", "uri": "file:///x/image.png"},
        {"type": "text", "text": "move this back to the center"},
    ]);
    let mut waiting = Waiting::default();
    waiting.push(rec(1, "queued", json!({"promptId": "p", "turnId": "t", "prompt": prompt})));
    let records = waiting.into_records();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].msg["prompt"], prompt);
}
