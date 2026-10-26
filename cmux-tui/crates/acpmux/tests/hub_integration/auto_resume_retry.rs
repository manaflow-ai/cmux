//! `_acpmux/retry` (`hub/auto_resume/retry_turn.rs`): the Retry button retries a chat's failed
//! last turn now, in the same session. subsession-card's ask (b), from Leo's "this needs to
//! retry :(" (2026-10-26).
use super::*;

const RETRY: &str = "_acpmux/retry";

fn row(hub: &Hub, id: &str) -> Value {
    hub.session_summary(&hub.resolve(id).unwrap())
}

async fn prompt(c: &mut TestClient, id: &str, prompt_id: &str, text: &str) -> Result<Value, String> {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id}}}),
    )
    .await
}

fn turn_results(k: &[String]) -> usize {
    k.iter().filter(|k| *k == "turn_result").count()
}

#[tokio::test]
async fn retry_refuses_when_nothing_failed_and_while_a_turn_runs() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "retry-refusals").await;
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
    prompt(&mut c, &id, "p-ok", "hello").await.unwrap();
    let e = c.request(RETRY, json!({"sessionId": id, "subagentId": "a1"})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");

    // A turn runs: busy.
    let mut other = connect(&hub).await;
    let sid = id.clone();
    let running = tokio::spawn(async move { prompt(&mut other, &sid, "p-run", "until-cancel").await });
    for _ in 0..400 {
        if hub.resolve(&id).unwrap().turn().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.busy"), "{e}");
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let _ = running.await;
    // A cancelled turn did not fail.
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
}

/// A turn that failed before the model produced anything goes again as the same prompt, in the
/// same session, as the next attempt of its prompt id; a double click sends it once.
#[tokio::test]
async fn a_failed_turn_with_no_output_is_sent_again_as_the_same_prompt() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    // No automatic retry: the failure stays failed until the person retries it.
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-same").await;
    let e = prompt(&mut c, &id, "p-f", "fail-once: hello").await.unwrap_err();
    assert!(e.contains("simulated internal error"), "{e}");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "failed");
    let agent_session = row(&hub, &id)["agentSessionId"].clone();
    let cut_turn = user_messages(&hub, &id)[0]["turnId"].clone();

    let mut other = connect(&hub).await;
    let (a, b) = tokio::join!(
        c.request(RETRY, json!({"sessionId": id})),
        other.request(RETRY, json!({"sessionId": id}))
    );
    let mut answered = 0;
    for r in [a, b] {
        match r {
            Ok(v) => {
                answered += 1;
                assert_eq!(v["promptId"], "p-f~resume-1", "{v}");
                assert_eq!(v["kind"], "turn", "{v}");
            }
            // The other click came while the first one's turn ran, or after it ended.
            Err(e) => assert!(e.starts_with("retry.busy") || e.starts_with("retry.nothing_failed"), "{e}"),
        }
    }
    assert!(answered >= 1);
    let k = until(&hub, &id, |k| turn_results(k) == 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "sent once: {messages:?} {k:?}");
    assert_eq!(messages[1]["promptId"], "p-f~resume-1");
    assert_eq!(messages[1]["text"], "fail-once: hello", "the same prompt");
    assert_eq!(
        messages[1]["_meta"]["provenance"],
        json!({"kind": "auto_resume", "promptId": "p-f", "attempt": 1, "turnId": cut_turn, "manual": true})
    );
    let after = row(&hub, &id);
    assert_eq!(after["lastTurn"]["status"], "completed", "{after}");
    assert_eq!(after["agentSessionId"], agent_session, "{after}");
    assert_eq!(hub.sessions().len(), 1, "no new session");
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(user_messages(&hub, &id).len(), 2);
    let e = c.request(RETRY, json!({"sessionId": id})).await.unwrap_err();
    assert!(e.starts_with("retry.nothing_failed"), "{e}");
}

/// A turn the model had started on is continued, not sent again.
#[tokio::test]
async fn a_failed_turn_with_output_is_continued() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "retry-continue").await;
    prompt(&mut c, &id, "p-o", "fail-after-update: x").await.unwrap_err();
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v["promptId"], "p-o~resume-1", "{v}");
    assert!(v["turnId"].is_string(), "{v}");
    until(&hub, &id, |k| turn_results(k) == 2).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    let text = messages[1]["text"].as_str().unwrap();
    assert!(text.starts_with("Your previous turn was cut off by an error"), "{text}");
    assert!(text.contains("simulated internal error after output"), "{text}");
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "completed");
}

/// A retry that waits fires now: its minute's wait ends at once, under the attempt's own id.
#[tokio::test]
async fn a_waiting_retry_fires_now() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![60_000]);
    let id = new_session(&mut c, "retry-now").await;
    prompt(&mut c, &id, "p-cap", "cap-fail-once: build it").await.unwrap_err();
    until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    assert_eq!(row(&hub, &id)["retry"]["attempt"], 1);
    let v = c.request(RETRY, json!({"sessionId": id})).await.unwrap();
    assert_eq!(v, json!({"promptId": "p-cap~resume-1", "kind": "turn"}));
    // Asked again before it started: the same retry, or busy; never a second prompt.
    match c.request(RETRY, json!({"sessionId": id})).await {
        Ok(v) => assert_eq!(v["promptId"], "p-cap~resume-1", "{v}"),
        Err(e) => assert!(e.starts_with("retry.busy"), "{e}"),
    }
    let k = until(&hub, &id, |k| turn_results(k) == 2).await;
    assert_eq!(turn_results(&k), 2, "fired within seconds, not a minute: {k:?}");
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-cap~resume-1");
    assert_eq!(row(&hub, &id)["retry"], Value::Null);
    assert_eq!(row(&hub, &id)["lastTurn"]["status"], "completed");
}
