//! A turn cut by a refused connection (nobody listening: the inference gateway is down) goes on
//! by itself, from a brand-new chat's first turn too, and waits the outage out like a capacity
//! one: it never uses up its attempts (`hub/auto_resume.rs` `waits_it_out`). On 2026-11-24 three
//! fresh Claude chats ended their first turn `failed` on "API Error: Connection refused
//! (ECONNREFUSED)" and sat idle until resumed by hand (Leo: "didn't we build auto retries for
//! this? why do they fail instead of waiting it out?").
use super::*;

const REFUSED: &str = "API Error: Connection refused (ECONNREFUSED)";

fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

fn row(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())
}

#[tokio::test]
async fn a_new_chats_first_turn_refused_by_the_gateway_goes_on_by_itself() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50]);
    let id = new_session(&mut c, "refused-first").await;
    let err = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("rate-fail-n:1:{REFUSED}")}], "_meta": {"acpmux": {"promptId": "p-refused"}}}),
        )
        .await
        .unwrap_err();
    assert_eq!(err, REFUSED);
    until(&hub, &id, |_| row(&hub, &id)["lastTurn"]["status"] == "completed").await;
    let scheduled = records(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled.len(), 1, "{:?}", kinds(&hub, &id));
    assert_eq!(scheduled[0]["reason"], "transport", "{}", scheduled[0]);
    assert_eq!(scheduled[0]["untilCapacity"], true, "{}", scheduled[0]);
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-refused~resume-1");
    let text = messages[1]["text"].as_str().unwrap();
    assert!(text.contains("ECONNREFUSED"), "{text}");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "completed");
}

#[tokio::test]
async fn a_refused_connection_outlasts_the_configured_attempts_and_completes() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20, 20]);
    let id = new_session(&mut c, "refused-down").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("rate-fail-n:4:{REFUSED}")}], "_meta": {"acpmux": {"promptId": "p-down"}}}),
        )
        .await
        .unwrap_err();
    // Four refusals outlast the two configured waits: the chain never runs out (a dropped
    // connection's would, `automatic_continuations_stop_after_the_configured_attempts`), and the
    // fifth prompt, once the gateway listens again, completes the turn.
    until(&hub, &id, |_| row(&hub, &id)["lastTurn"]["status"] == "completed").await;
    assert!(records(&hub, &id, "auto_resume_exhausted").is_empty(), "{:?}", kinds(&hub, &id));
    let scheduled = records(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled.len(), 4, "{scheduled:?}");
    assert!(scheduled.iter().all(|s| s["untilCapacity"] == true), "{scheduled:?}");
    // Past the configured waits the last one doubles, capped as a capacity wait is.
    assert!(scheduled[3]["delayMs"].as_u64().unwrap() > scheduled[1]["delayMs"].as_u64().unwrap());
    assert_eq!(user_messages(&hub, &id).len(), 5);
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
}
