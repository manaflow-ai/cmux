//! A turn a connection error cut off goes on by itself (`hub/auto_resume.rs`,
//! cmuxterm-hq#2503): on 2026-10-18 one relay outage ended 29 Codex turns with
//! "stream disconnected", and each chat stayed idle until a person typed "continue".
use super::*;

#[path = "agent_revive.rs"]
mod agent_revive;

#[path = "auto_resume_capacity.rs"]
mod capacity;

#[path = "auto_resume_limits.rs"]
mod limits;

#[path = "auto_resume_retry.rs"]
mod retry;

/// Every event kind of a session, oldest first.
fn kinds(hub: &Hub, id: &str) -> Vec<String> {
    hub.events(id, 0, 10_000).unwrap().into_iter().map(|e| e.kind).collect()
}

/// The `user_message` records of a session.
fn user_messages(hub: &Hub, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "user_message")
        .map(|e| e.msg)
        .collect()
}

async fn new_session(c: &mut TestClient, name: &str) -> String {
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

/// Waits (up to 20 s) until `pred` holds for the session's events.
async fn until(hub: &Hub, id: &str, pred: impl Fn(&[String]) -> bool) -> Vec<String> {
    for _ in 0..400 {
        let k = kinds(hub, id);
        if pred(&k) {
            return k;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    kinds(hub, id)
}

#[tokio::test]
async fn a_turn_a_connection_error_cut_off_goes_on_by_itself() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50]);
    let id = new_session(&mut c, "cut").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-once: build it"}], "_meta": {"acpmux": {"promptId": "p-cut"}}}),
        )
        .await;
    assert!(r.unwrap_err().contains("stream disconnected"));

    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    assert!(k.iter().any(|k| k == "auto_resume_scheduled"), "{k:?}");
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    let resumed = &messages[1];
    assert_eq!(resumed["promptId"], "p-cut~resume-1");
    assert_eq!(resumed["client"], "acpmux");
    assert_eq!(
        resumed["_meta"]["provenance"],
        json!({"kind": "auto_resume", "promptId": "p-cut", "attempt": 1, "turnId": messages[0]["turnId"]})
    );
    let text = resumed["text"].as_str().unwrap();
    assert!(text.contains("cut off by a connection error"), "{text}");
    assert!(text.contains("stream disconnected"), "{text}");
    let summary = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(summary["lastTurn"]["status"], "completed", "{summary}");
}

#[tokio::test]
async fn automatic_continuations_stop_after_the_configured_attempts() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20, 20]);
    let id = new_session(&mut c, "down").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-down"}], "_meta": {"acpmux": {"promptId": "p-down"}}}),
        )
        .await;
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_exhausted")).await;
    assert!(k.iter().any(|k| k == "auto_resume_exhausted"), "{k:?}");
    let exhausted = hub.events(&id, 0, 10_000).unwrap();
    let exhausted = exhausted.iter().find(|e| e.kind == "auto_resume_exhausted").unwrap();
    assert_eq!(exhausted.msg["reason"], "transport", "{:?}", exhausted.msg);
    assert_eq!(exhausted.msg["attempts"], 2, "{:?}", exhausted.msg);
    // Nothing waits any more: the row says so.
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["retry"], Value::Null);
    let ids: Vec<Value> =
        user_messages(&hub, &id).into_iter().map(|m| m["promptId"].clone()).collect();
    assert_eq!(ids, [json!("p-down"), json!("p-down~resume-1"), json!("p-down~resume-2")]);
    // Nothing more is sent once the attempts are used.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(user_messages(&hub, &id).len(), 3);
}

#[tokio::test]
async fn a_prompt_sent_meanwhile_supersedes_the_continuation() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![500]);
    let id = new_session(&mut c, "meanwhile").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-once: x"}]}),
        )
        .await;
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "never mind, do y"}]}),
    )
    .await
    .unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    assert!(k.iter().any(|k| k == "auto_resume_skipped"), "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 2, "only the person's two prompts ran");
}

#[tokio::test]
async fn other_failures_are_not_continued() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "bug").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "fail-once: x"}]}),
        )
        .await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    let k = kinds(&hub, &id);
    assert!(!k.iter().any(|k| k.starts_with("auto_resume")), "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

#[tokio::test]
async fn stop_cancels_a_continuation_that_has_not_fired() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![400]);
    let id = new_session(&mut c, "stop").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-once: x"}]}),
        )
        .await;
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    let skipped: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "auto_resume_skipped")
        .map(|e| e.msg["skipped"].clone())
        .collect();
    assert_eq!(skipped, [json!("stopped")], "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

/// The `skipped` reasons of a session's `auto_resume_skipped` records.
fn skips(hub: &Hub, id: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "auto_resume_skipped")
        .map(|e| e.msg["skipped"].clone())
        .collect()
}

#[tokio::test]
async fn a_turn_stopped_mid_stream_is_not_continued_when_it_ends_in_a_connection_error() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "stopped").await;
    let mut other = connect(&hub).await;
    let params =
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-on-cancel"}]});
    let turn = tokio::spawn(async move { other.request(method::SESSION_PROMPT, params).await });
    let session = hub.resolve(&id).unwrap();
    for _ in 0..400 {
        if session.turn().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    assert!(session.turn().is_some(), "the turn never started");
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let r = turn.await.unwrap();
    assert!(r.unwrap_err().contains("stream disconnected"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let k = kinds(&hub, &id);
    assert!(!k.iter().any(|k| k.starts_with("auto_resume")), "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

#[tokio::test]
async fn closing_the_chat_cancels_a_continuation_that_has_not_fired() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![400]);
    let id = new_session(&mut c, "close").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-once: x"}]}),
        )
        .await;
    c.request(method::SESSION_CLOSE, json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    assert_eq!(skips(&hub, &id), [json!("stopped")], "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

#[tokio::test]
async fn a_chat_being_moved_is_not_continued() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![400]);
    let id = new_session(&mut c, "move").await;
    let _ = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-once: x"}]}),
        )
        .await;
    c.request("_acpmux/transfer_begin", json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    assert_eq!(skips(&hub, &id), [json!("closed")], "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

/// Stop lands after the turn has ended but before its continuation is scheduled. The test holds
/// the config lock, so the failed turn waits in `route_failure` (a refused connection is a
/// route-class failure) after it has given up its turn.
#[tokio::test]
async fn stop_between_the_failure_and_its_scheduling_still_prevents_the_continuation() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![20]);
    let id = new_session(&mut c, "gap").await;
    let mut other = connect(&hub).await;
    let params =
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-refused-later"}]});
    let turn = tokio::spawn(async move { other.request(method::SESSION_PROMPT, params).await });
    let session = hub.resolve(&id).unwrap();
    for _ in 0..400 {
        if session.turn().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(session.turn().is_some(), "the turn never started");
    let config = hub.config.write().await;
    for _ in 0..400 {
        if session.turn().is_none() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(session.turn().is_none(), "the turn never ended");
    hub.cancel(&session).await.unwrap();
    drop(config);
    let r = turn.await.unwrap();
    assert!(r.unwrap_err().contains("connection refused"));
    tokio::time::sleep(Duration::from_millis(300)).await;
    let k = kinds(&hub, &id);
    assert!(!k.iter().any(|k| k == "auto_resume_scheduled"), "{k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
}

/// Stop lands after the continuation fired but before its turn starts. The agent exits after
/// the failure, so the continuation reads the config before it dispatches; the test holds the
/// config lock to keep it there.
#[tokio::test]
async fn stop_right_after_the_continuation_fires_still_prevents_it() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![500]);
    let id = new_session(&mut c, "fired").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-then-exit"}]}),
        )
        .await;
    assert!(r.unwrap_err().contains("stream disconnected"));
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    assert!(k.iter().any(|k| k == "auto_resume_scheduled"), "{k:?}");
    let session = hub.resolve(&id).unwrap();
    let config = hub.config.write().await;
    // The wait (500 ms, up to 600 with the stagger) ends: the continuation fires and waits on
    // the config.
    tokio::time::sleep(Duration::from_millis(1200)).await;
    let _ = tokio::time::timeout(Duration::from_secs(2), hub.cancel(&session)).await;
    drop(config);
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(user_messages(&hub, &id).len(), 1, "{:?}", kinds(&hub, &id));
}

/// A prompt queued behind the cut turn runs once a later attempt goes through. The attempt that
/// failed holds nothing new (the cut turn already holds the prompt), so the prompt waits on the
/// cut turn, not on the attempt before the one that went through.
#[tokio::test]
async fn a_prompt_held_by_the_cut_turn_runs_when_a_later_attempt_goes_through() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50, 50]);
    let id = new_session(&mut c, "flaky").await;
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-flaky: build it"}], "_meta": {"acpmux": {"promptId": "p-cut"}}}),
    )
    .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "flaky ").await;
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "then test it"}], "_meta": {"acpmux": {"promptId": "p-q1"}}}),
    )
    .await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-q1" && p["queued"] == true)
        .await;

    let ids = || -> Vec<Value> {
        user_messages(&hub, &id).into_iter().map(|m| m["promptId"].clone()).collect()
    };
    for _ in 0..400 {
        if ids().contains(&json!("p-q1")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(
        ids(),
        [json!("p-cut"), json!("p-cut~resume-1"), json!("p-cut~resume-2"), json!("p-q1")],
        "{:?}",
        kinds(&hub, &id)
    );
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 4).await;
    let summary = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(summary["lastTurn"]["status"], "completed", "{summary} {k:?}");
}

/// An agent message held behind a cut turn waits for the continuation instead of overtaking it:
/// its own retry (`digest.rs` `retry_held_agent_messages`) waits the same `autoResumeDelaysMs`,
/// and going first would supersede the continuation and leave the person's held prompt waiting.
#[tokio::test]
async fn an_agent_message_held_by_the_cut_turn_waits_for_the_continuation() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50, 50]);
    let id = new_session(&mut c, "flaky-agents").await;
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-flaky: build it"}], "_meta": {"acpmux": {"promptId": "p-cut"}}}),
    )
    .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "flaky ").await;
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "then test it"}], "_meta": {"acpmux": {"promptId": "p-q1"}}}),
    )
    .await;
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "from a lane"}], "_meta": {"acpmux": {"promptId": "p-a", "fromAgent": "lane-a"}}}),
    )
    .await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-a" && p["queued"] == true)
        .await;

    let ids = || -> Vec<Value> {
        user_messages(&hub, &id).into_iter().map(|m| m["promptId"].clone()).collect()
    };
    for _ in 0..400 {
        if ids().contains(&json!("p-q1")) && ids().contains(&json!("p-a")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    let ran = ids();
    assert_eq!(
        ran[..3],
        [json!("p-cut"), json!("p-cut~resume-1"), json!("p-cut~resume-2")],
        "{ran:?} {:?}",
        kinds(&hub, &id)
    );
    assert!(ran.contains(&json!("p-q1")) && ran.contains(&json!("p-a")), "{ran:?}");
}
