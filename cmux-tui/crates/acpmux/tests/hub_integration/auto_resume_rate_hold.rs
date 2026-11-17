//! The account's rate limit holds the chat until its reset (`hub/rate_hold.rs`). Leo,
//! 2026-11-17: "the old coord keeps running into these rate limit spirals" / "oh i mean not gh".
//! claude-sr2-coord-old failed 207 of 400 turns on one 429: every message from another agent
//! started a turn of its own, each resending a 323K context into the same limit.
use super::*;

const LIMIT: &str =
    "API Error: Request rejected (429) · This request would exceed your account's rate limit";

fn events(hub: &Hub, id: &str) -> Vec<acpmux::store::EventRecord> {
    hub.events(id, 0, 10_000).unwrap()
}

fn of_kind(hub: &Hub, id: &str, kind: &str) -> Vec<acpmux::store::EventRecord> {
    events(hub, id).into_iter().filter(|e| e.kind == kind).collect()
}

fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": agent}}})
}

/// A 429 that names its reset T, then ten messages from other agents while it holds: exactly
/// one turn after T, carrying all ten and the continuation's words; none before T.
async fn ten_messages_make_one_turn_after_the_reset(hub: Arc<Hub>, mut c: TestClient) {
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25, 25, 25, 25]);
    let id = new_session(&mut c, "coord-old").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 2")}],
        "_meta": {"acpmux": {"promptId": "p-cut"}}
    })).await;
    assert!(r.unwrap_err().contains("429"));
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let held = of_kind(&hub, &id, "rate_limit_held");
    let reset =
        held.last().unwrap_or_else(|| panic!("no hold: {k:?}")).msg["until"].as_u64().unwrap();
    let failed_at = of_kind(&hub, &id, "turn_result")[0].at;
    assert!(reset >= failed_at + 1_900, "the hold waits for the reset: {reset} vs {failed_at}");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["rateLimitedUntil"], reset, "{row}");
    assert_eq!(row["retry"]["reason"], "rate_limit", "{row}");

    let mut sent = Vec::new();
    for n in 0..10 {
        sent.push(
            c.send(
                method::SESSION_PROMPT,
                from_agent(&id, &format!("m-{n}"), &format!("lane-{n}"), &format!("report {n}")),
            )
            .await,
        );
    }
    // Every message waits out the hold: none starts a turn before the reset.
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(acpmux::store::now_ms() < reset, "the test reached the reset before it looked");
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1, "{:?}", kinds(&hub, &id));

    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    // Give a second turn the time to start if one were coming.
    tokio::time::sleep(Duration::from_millis(800)).await;
    let started = of_kind(&hub, &id, "turn_started");
    assert_eq!(started.len(), 2, "exactly one turn after the reset: {k:?}");
    assert!(started[1].at >= reset, "it started at the reset: {} < {reset}", started[1].at);
    let skipped = of_kind(&hub, &id, "auto_resume_skipped");
    assert_eq!(skipped.len(), 1, "{skipped:?}");
    assert_eq!(skipped[0].msg["skipped"], "folded", "{skipped:?}");
    let last = user_messages(&hub, &id).pop().unwrap().to_string();
    for n in 0..10 {
        assert!(last.contains(&format!("report {n}")), "message {n} missing from {last}");
    }
    assert!(last.contains("rate limit"), "the turn carries the continuation's words: {last}");
    assert_eq!(of_kind(&hub, &id, "rate_limit_lifted").len(), 1);
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");
    drop(sent);
}

#[tokio::test]
async fn a_rate_limit_hold_turns_ten_queued_messages_into_one_turn_after_the_reset() {
    let (hub, c) = setup_queue(PermissionPolicy::ApproveAll).await;
    ten_messages_make_one_turn_after_the_reset(hub, c).await;
}

#[tokio::test]
async fn a_rate_limit_with_nothing_queued_continues_alone_at_the_reset() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "alone").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 1")}],
        "_meta": {"acpmux": {"promptId": "p-alone"}}
    })).await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{k:?}");
    assert_eq!(messages[1]["promptId"], "p-alone~resume-1");
    let reset = of_kind(&hub, &id, "rate_limit_held")[0].msg["until"].as_u64().unwrap();
    assert!(of_kind(&hub, &id, "turn_started")[1].at >= reset);
    assert!(of_kind(&hub, &id, "auto_resume_skipped").is_empty());
}

#[tokio::test]
async fn a_529_is_capacity_and_holds_nothing() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "overloaded").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": "recover-once: API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}"}],
        "_meta": {"acpmux": {"promptId": "p-529"}}
    })).await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    assert!(!k.iter().any(|k| k == "rate_limit_held"), "{k:?}");
    let scheduled = of_kind(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled[0].msg["reason"], "capacity", "{scheduled:?}");
}

#[tokio::test]
async fn stop_ends_a_rate_limit_hold_and_the_queue_goes_on() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "stopped").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: {LIMIT}; Retry-After: 600")}],
        "_meta": {"acpmux": {"promptId": "p-stop"}}
    })).await;
    assert!(r.is_err());
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    c.send(method::SESSION_PROMPT, from_agent(&id, "m-late", "lane", "late report")).await;
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(of_kind(&hub, &id, "turn_started").len(), 1);
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "rate_limit_lifted")).await;
    assert!(k.iter().any(|k| k == "rate_limit_lifted"), "{k:?}");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row.get("rateLimitedUntil").is_none(), "{row}");
    // The person's next prompt runs at once, its 429 long before the reset or not.
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "go on"}]}),
    )
    .await
    .unwrap();
}
