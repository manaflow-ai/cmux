//! A turn a connection error cut off goes on by itself (`hub/auto_resume.rs`,
//! cmuxterm-hq#2503): on 2026-10-18 one relay outage ended 29 Codex turns with
//! "stream disconnected", and each chat stayed idle until a person typed "continue".
use super::*;

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
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![50]);
    let id = new_session(&mut c, "cut").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "net-fail-once: build it"}], "_meta": {"acpmux": {"promptId": "p-cut"}}}),
        )
        .await;
    assert!(r.unwrap_err().contains("stream disconnected"));

    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_end").count() == 1).await;
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
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
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
    let ids: Vec<Value> =
        user_messages(&hub, &id).into_iter().map(|m| m["promptId"].clone()).collect();
    assert_eq!(ids, [json!("p-down"), json!("p-down~resume-1"), json!("p-down~resume-2")]);
    // Nothing more is sent once the attempts are used.
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(user_messages(&hub, &id).len(), 3);
}

#[tokio::test]
async fn a_prompt_sent_meanwhile_supersedes_the_continuation() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
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
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
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
