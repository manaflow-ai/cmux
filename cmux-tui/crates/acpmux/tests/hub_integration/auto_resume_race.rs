//! A double resume (Leo, 2026-11-24: "is our logistics for being able to durably wake them up
//! good?"). A capacity wait's timer and the Retry button (`_acpmux/retry`, from the GUI, a
//! coordinator's `acpmux retry` and a second window at once) race at the wait's deadline. Only
//! one of them may send the continuation: the chat gets `P~resume-1` exactly once, and never a
//! `P~resume-2` for a turn that went through.
use super::*;

const RETRY: &str = "_acpmux/retry";
/// How many Retry calls race the timer, each from its own connection.
const CALLERS: u64 = 6;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_timer_and_six_retries_racing_at_the_deadline_send_the_continuation_once() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![400]);
    let id = new_session(&mut c, "resume-race").await;
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "cap-fail-once: build it"}],
            "_meta": {"acpmux": {"promptId": "p-race"}}}),
    )
    .await
    .unwrap_err();
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let next_at = hub.session_summary(&hub.resolve(&id).unwrap())["retry"]["nextAt"]
        .as_u64()
        .expect("a waiting retry has its time");

    // The callers arrive from 30 ms before the deadline to 30 ms after it, 12 ms apart.
    let now_ms = || {
        u64::try_from(
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis(),
        )
        .unwrap()
    };
    let mut calls = Vec::new();
    for i in 0..CALLERS {
        let mut caller = connect(&hub).await;
        let at = next_at.saturating_sub(30) + i * 12;
        let id = id.clone();
        let wait = at.saturating_sub(now_ms());
        calls.push(tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(wait)).await;
            caller.request(RETRY, json!({"sessionId": id})).await
        }));
    }
    let mut sent = 0;
    for call in calls {
        match call.await.unwrap() {
            Ok(v) => {
                assert_eq!(v["promptId"], "p-race~resume-1", "{v}");
                sent += 1;
            }
            Err(e) => assert!(
                e.starts_with("retry.busy") || e.starts_with("retry.nothing_failed"),
                "a losing retry says why: {e}"
            ),
        }
    }
    assert!(sent <= 1, "{sent} retries each sent the continuation");

    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() >= 2).await;
    // Room for a second send to show if one slipped through.
    tokio::time::sleep(Duration::from_millis(800)).await;
    let k2 = kinds(&hub, &id);
    assert_eq!(k2.iter().filter(|k| *k == "turn_result").count(), 2, "{k:?} then {k2:?}");
    let prompts: Vec<Value> =
        user_messages(&hub, &id).into_iter().map(|m| m["promptId"].clone()).collect();
    assert_eq!(prompts, [json!("p-race"), json!("p-race~resume-1")], "sent once, in order");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["retry"], Value::Null, "{row}");
    assert_eq!(row["lastTurn"]["status"], "completed", "{row}");
}
