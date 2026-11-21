//! Usage limits and gateway failures resume the same conversation after the provider hint.
use super::*;

#[tokio::test]
async fn limit_recovery_resumes_429_502_503_and_harness_unavailable_without_manual_retry() {
    for error in [
        "API Error: 429 rate_limit_error; Retry-After: 1",
        "HTTP 502",
        "HTTP 503",
        "harness_unavailable",
    ] {
        let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
        hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
        let id = new_session(&mut c, "limit-recovery").await;
        let r = c.request(method::SESSION_PROMPT, json!({
            "sessionId": id, "prompt": [{"type": "text", "text": format!("recover-once: {error}")}],
            "_meta": {"acpmux": {"promptId": "p-limit"}}
        })).await;
        assert!(r.unwrap_err().contains(error));
        let agent = hub.session_summary(&hub.resolve(&id).unwrap())["agentSessionId"].clone();
        let k = until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
        let messages = user_messages(&hub, &id);
        assert_eq!(messages.len(), 2, "{error}: {k:?}");
        let row = hub.session_summary(&hub.resolve(&id).unwrap());
        assert_eq!(row["lastTurn"]["status"], "completed", "{error}: {row}");
        assert_eq!(row["agentSessionId"], agent, "{error}: same conversation");
        assert_eq!(messages[1]["promptId"], "p-limit~resume-1");
        if error.contains("1s") || error.contains("Retry-After") {
            let scheduled = hub
                .events(&id, 0, 1000)
                .unwrap()
                .into_iter()
                .find(|e| e.kind == "auto_resume_scheduled")
                .unwrap();
            assert!(scheduled.msg["delayMs"].as_u64().unwrap() >= 1000, "{scheduled:?}");
        }
    }
}

#[tokio::test]
async fn a_usage_limit_with_a_fallback_stays_on_the_same_profile() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    {
        let mut cfg = hub.config.write().await;
        let mut fallback = cfg.harnesses["fake"].clone();
        fallback.fallback = None;
        cfg.harnesses.insert("fallback".into(), fallback);
        cfg.harnesses.get_mut("fake").unwrap().fallback = Some("fallback".into());
    }
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "same-profile-limit").await;
    let r = c.request(method::SESSION_PROMPT, json!({
        "sessionId": id,
        "prompt": [{"type": "text", "text": "recover-once: API Error: 429 rate_limit_error"}],
        "_meta": {"acpmux": {"promptId": "p-same-profile"}}
    })).await;
    assert!(r.is_err());
    let before = hub.session_summary(&hub.resolve(&id).unwrap());
    let agent = before["agentSessionId"].clone();
    until(&hub, &id, |k| k.iter().filter(|k| *k == "turn_result").count() == 2).await;
    let after = hub.session_summary(&hub.resolve(&id).unwrap());
    assert_eq!(after["harness"], "fake");
    assert_eq!(after["agentSessionId"], agent, "usage limits must not switch accounts");
}

// cmux#48665: a Codex chat out of its usage window was continued again and again before the
// reset, and each attempt drew one more "rate limited" card. A used-up usage window is never
// continued by itself ("never retry usage limits"): the chat holds until its reset, and the
// person goes on with another model.
#[tokio::test]
async fn a_used_up_usage_window_is_never_continued_and_holds_until_its_reset() {
    let reset = acpmux::store::now_ms() / 1000 + 6 * 86400;
    for error in [
        format!("Claude AI usage limit reached|{reset}"),
        "You've hit your weekly usage limit (retry after 1s)".to_owned(),
        "You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at 4:05 AM.".to_owned(),
    ] {
        let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
        hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
        let id = new_session(&mut c, "usage-window").await;
        let r = c.request(method::SESSION_PROMPT, json!({"sessionId": id,
            "prompt": [{"type": "text", "text": format!("recover-once: {error}")}]
        })).await;
        assert!(r.is_err(), "{error}");
        let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_settled")).await;
        assert!(!k.iter().any(|k| k == "auto_resume_scheduled"), "{error}: {k:?}");
        let row = hub.session_summary(&hub.resolve(&id).unwrap());
        assert!(row["retry"].is_null(), "{error}: {row}");
        assert!(row["rateLimitedUntil"].as_u64().is_some(), "{error}: {row}");
        if error.contains("reached|") {
            assert!(row["rateLimitedUntil"].as_u64().unwrap() >= reset * 1000, "{row}");
        }
        // Well past the attempt's own 25 ms wait: still the one prompt, no second failure.
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert_eq!(user_messages(&hub, &id).len(), 1, "{error}");
        assert_eq!(kinds(&hub, &id).iter().filter(|k| *k == "turn_result").count(), 1, "{error}");
    }
}
