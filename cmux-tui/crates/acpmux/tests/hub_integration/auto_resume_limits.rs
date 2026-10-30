//! Usage limits and gateway failures resume the same conversation after the provider hint.
use super::*;

#[tokio::test]
async fn limit_recovery_resumes_429_502_503_and_harness_unavailable_without_manual_retry() {
    for error in [
        "API Error: 429 rate_limit_error; Retry-After: 1",
        "HTTP 502",
        "HTTP 503",
        "harness_unavailable",
        "You've hit your weekly usage limit (retry after 1s)",
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

#[tokio::test]
async fn limit_recovery_waits_for_a_weekly_reset_instead_of_spending_short_retries() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.auto_resume_delays_ms = Some(vec![25]);
    let id = new_session(&mut c, "weekly-reset").await;
    let reset = acpmux::store::now_ms() / 1000 + 6 * 86400;
    let r = c.request(method::SESSION_PROMPT, json!({"sessionId": id,
        "prompt": [{"type": "text", "text": format!("recover-once: Claude AI usage limit reached|{reset}")}]
    })).await;
    assert!(r.is_err());
    let k = until(&hub, &id, |k| k.iter().any(|k| k == "auto_resume_scheduled")).await;
    let row = hub.session_summary(&hub.resolve(&id).unwrap());
    assert!(row["retry"]["nextAt"].as_u64().unwrap_or(0) >= reset * 1000, "{row}: {k:?}");
    assert_eq!(user_messages(&hub, &id).len(), 1);
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    assert_eq!(hub.session_summary(&hub.resolve(&id).unwrap())["retry"], Value::Null);
}
