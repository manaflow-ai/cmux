//! A Claude chat that outgrew its model's context window compacts and goes on by itself
//! (`hub/auto_resume/compact_first.rs`, reason `context`). Leo, 2026-11-03, on a chat whose turn
//! failed with Claude Code's "Prompt is too long" and sat failed: "this should not have happened.
//! this should have just started compacting".
use super::*;

/// Claude Code's error for a prompt past the model's window.
const TOO_LONG: &str = "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 211234 tokens > 200000 maximum\"}}";

fn records(hub: &Hub, id: &str, kind: &str) -> Vec<Value> {
    hub.events(id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == kind)
        .map(|e| e.msg)
        .collect()
}

/// A chat on the fake agent, as a Claude one when `claude` (only a Claude chat can compact),
/// with the fake agent's `FAKE_COMPACT` set to `compact` when given.
async fn chat(claude: bool, compact: Option<&str>) -> (Arc<Hub>, TestClient, String) {
    let env = compact.map(|m| ("FAKE_COMPACT".to_owned(), m.to_owned())).into_iter().collect();
    let (hub, mut c) = setup_env(PermissionPolicy::ApproveAll, env).await;
    {
        let mut config = hub.config.write().await;
        // A minute's wait would show: a chat that outgrew its window compacts at once.
        config.auto_resume_delays_ms = Some(vec![60_000]);
        if claude {
            config.harnesses.get_mut("fake").unwrap().family = Some("claude".into());
        }
    }
    let id = new_session(&mut c, "context").await;
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("recover-once: {TOO_LONG}")}], "_meta": {"acpmux": {"promptId": "p-long"}}}),
        )
        .await;
    assert!(r.unwrap_err().contains("prompt is too long"));
    (hub, c, id)
}

#[tokio::test]
async fn a_chat_past_its_context_window_compacts_then_goes_on_without_a_wait() {
    let (hub, _c, id) = chat(true, None).await;
    let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 3).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 3, "{messages:?} {k:?}");
    let cut_turn = messages[0]["turnId"].clone();
    // First `/compact` in the same chat, as acpmux's.
    assert_eq!(messages[1]["text"], "/compact", "{messages:?}");
    assert_eq!(messages[1]["promptId"], "p-long~compact-1");
    assert_eq!(messages[1]["client"], "acpmux");
    assert_eq!(
        messages[1]["_meta"]["provenance"],
        json!({"kind": "auto_resume", "promptId": "p-long", "attempt": 1, "turnId": cut_turn, "step": "compact"})
    );
    // Then the continuation, after the compaction's turn.
    assert_eq!(messages[2]["promptId"], "p-long~resume-1");
    assert_eq!(messages[2]["_meta"]["provenance"]["kind"], "auto_resume");
    assert_eq!(messages[2]["_meta"]["provenance"]["turnId"], messages[1]["turnId"]);
    let text = messages[2]["text"].as_str().unwrap();
    assert!(text.contains("context") && text.contains("compacted"), "{text}");
    let scheduled = records(&hub, &id, "auto_resume_scheduled");
    assert_eq!(scheduled.len(), 1, "{scheduled:?}");
    assert_eq!(scheduled[0]["reason"], "context", "{scheduled:?}");
    assert_eq!(scheduled[0]["of"], 1, "{scheduled:?}");
    assert_eq!(scheduled[0]["delayMs"], 0, "{scheduled:?}");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["lastTurn"]["status"], "completed", "{row}");
    assert_eq!(row["retry"], Value::Null, "{row}");
}

/// Stop while the chat compacts ends it there: no continuation follows.
#[tokio::test]
async fn stop_during_the_compaction_cancels_the_continuation() {
    let (hub, mut c, id) = chat(true, Some("hold")).await;
    let k = until(&hub, &id, |_| user_messages(&hub, &id).iter().any(|m| m["text"] == "/compact"))
        .await;
    assert!(user_messages(&hub, &id).iter().any(|m| m["text"] == "/compact"), "{k:?}");
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_skipped")).await;
    let skipped = records(&hub, &id, "auto_resume_skipped");
    assert_eq!(skipped.len(), 1, "{k:?}");
    assert_eq!(skipped[0]["skipped"], "stopped", "{skipped:?}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    assert!(!messages.iter().any(|m| m["promptId"] == "p-long~resume-1"), "{messages:?}");
}

/// A compaction that fails is not tried again, nor continued: the retry is used up.
#[tokio::test]
async fn a_failed_compaction_settles_without_a_loop() {
    let (hub, _c, id) = chat(true, Some("fail")).await;
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_exhausted")).await;
    let exhausted = records(&hub, &id, "auto_resume_exhausted");
    assert_eq!(exhausted.len(), 1, "{k:?}");
    assert_eq!(exhausted[0]["reason"], "context", "{exhausted:?}");
    assert_eq!(exhausted[0]["promptId"], "p-long", "{exhausted:?}");
    tokio::time::sleep(Duration::from_millis(500)).await;
    let messages = user_messages(&hub, &id);
    assert_eq!(messages.len(), 2, "{messages:?}");
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(row["retry"], Value::Null, "{row}");
    assert_ne!(row["retryDeciding"], true, "{row}");
}

/// A harness that cannot compact keeps today's behaviour: the chat is not retried.
#[tokio::test]
async fn a_chat_that_cannot_compact_is_not_retried() {
    let (hub, _c, id) = chat(false, None).await;
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_settled")).await;
    assert!(!k.iter().any(|k| k == "auto_resume_scheduled"), "{k:?}");
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert_eq!(user_messages(&hub, &id).len(), 1);
}
