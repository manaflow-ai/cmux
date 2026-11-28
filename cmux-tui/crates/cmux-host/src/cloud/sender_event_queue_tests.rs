use super::{Answer, AttentionQueue, EventQueue};
use serde_json::json;

/// HQ#5351 item 2: nothing drains the queue while it backs off (up to 600 s), so
/// socket clients could grow the agent's memory without bound. Past its cap the
/// queue refuses new events and keeps the ones it holds, in order.
#[test]
fn a_backed_off_queue_refuses_events_past_its_cap() {
    let mut queue = EventQueue::new("vm-1");
    let first = queue.emit("agent.started", 1, json!({})).unwrap();
    assert!(first.is_some());
    let (_, next) = queue.finished(&Answer::Transport, 0, 0.5);
    assert!(next.is_none());
    let mut refused = 0;
    for at in 2..1_000 {
        if queue.emit("agent.started", at, json!({})).is_err() {
            refused += 1;
        }
    }
    assert_eq!(queue.len(), super::EVENT_QUEUE_MAX);
    assert!(refused > 0);
    let retry = queue.fire(u64::MAX).expect("the head retries");
    assert_eq!(retry.params["at"], 1);
}

fn attention(id: &str, kind: &str) -> serde_json::Value {
    serde_json::json!({
        "event_id": id, "kind": kind, "session": "acp_s1", "title": "Cloud chat",
        "occurred_at": 1_790_000_000_000u64
    })
}

#[test]
fn attention_retry_preserves_payload_and_success_drains() {
    let mut queue = AttentionQueue::new("vm-1");
    let first = queue.emit(&attention("attn_1", "question")).unwrap().unwrap();
    let (_, next) = queue.finished(&Answer::Transport, 10, 0.5);
    assert!(next.is_none());
    let retry = queue.fire(1_010).unwrap();
    assert_eq!(retry.params, first.params);
    let (_, next) = queue.finished(
        &Answer::Http { status: 200, body: serde_json::json!({"ok": true}) },
        1_011,
        0.5,
    );
    assert!(next.is_none());
    assert_eq!(queue.len(), 0);
}

#[test]
fn attention_rate_limit_waits_and_denial_drops() {
    let mut queue = AttentionQueue::new("vm-1");
    queue.emit(&attention("attn_2", "permission")).unwrap();
    let answer = Answer::Http {
        status: 429,
        body: serde_json::json!({"error": {"code": "cloud.rate_limited", "details": {"retry_after_ms": 20}}}),
    };
    let (outcome, next) = queue.finished(&answer, 100, 0.5);
    assert_eq!(outcome, super::EventOutcome::Retrying);
    assert!(next.is_none());
    assert!(queue.fire(119).is_none());
    assert!(queue.fire(120).is_some());
    let (outcome, next) = queue.finished(
        &Answer::Http {
            status: 400,
            body: serde_json::json!({"error": {"code": "policy.denied"}}),
        },
        121,
        0.5,
    );
    assert!(matches!(outcome, super::EventOutcome::Dropped(_)));
    assert!(next.is_none());
    assert!(queue.is_empty());
}

#[test]
fn attention_queue_is_bounded() {
    let mut queue = AttentionQueue::new("vm-1");
    queue.emit(&attention("attn_0", "done")).unwrap();
    for i in 1..super::EVENT_QUEUE_MAX {
        queue.emit(&attention(&format!("attn_{i}"), "done")).unwrap();
    }
    assert_eq!(queue.len(), super::EVENT_QUEUE_MAX);
    assert!(queue.emit(&attention("attn_overflow", "done")).is_err());
}
