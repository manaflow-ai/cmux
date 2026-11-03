use super::*;
use serde_json::{Value, json};

fn schema() -> Value {
    json!({
        "type": "object",
        "properties": {"passed": {"type": "boolean"}},
        "required": ["passed"],
        "additionalProperties": false,
    })
}

#[test]
fn workflow_reply_accepts_valid_final_json_and_stays_finished() {
    let key = AttemptKey::new("activity-1");
    let mut policy = ReplyPolicy::new(&schema(), ReplyState::new(key.clone())).unwrap();
    assert_eq!(
        policy.observe(&key, 1, r#"{"passed": true}"#),
        ReplyDecision::Accept(json!({"passed": true}))
    );
    assert_eq!(policy.observe(&key, 2, "wrong"), ReplyDecision::Ignore);
}

#[test]
fn workflow_reply_rejects_invalid_schema_before_agent_dispatch() {
    assert!(
        ReplyPolicy::new(&json!({"type": "banana"}), ReplyState::new(AttemptKey::new("activity")))
            .is_err()
    );
    assert!(
        ReplyPolicy::new(
            &json!({"$ref": "https://example.invalid/schema.json"}),
            ReplyState::new(AttemptKey::new("activity"))
        )
        .is_err()
    );
    assert!(
        ReplyPolicy::new(
            &json!({"$ref": "file:///etc/passwd"}),
            ReplyState::new(AttemptKey::new("activity"))
        )
        .is_err()
    );
}

#[test]
fn workflow_reply_correction_once_survives_resume() {
    let key = AttemptKey::new("activity");
    let mut policy = ReplyPolicy::new(&schema(), ReplyState::new(key.clone())).unwrap();
    let ReplyDecision::Correct { prompt, issues } = policy.observe(&key, 1, "not JSON") else {
        panic!("one correction required")
    };
    assert!(prompt.contains("JSON"));
    assert!(matches!(issues.as_slice(), [ReplyIssue::InvalidJson(_)]));
    let saved = serde_json::to_value(policy.state()).unwrap();
    let state = serde_json::from_value(saved).unwrap();
    let mut resumed = ReplyPolicy::new(&schema(), state).unwrap();
    assert_eq!(resumed.observe(&key, 1, "not JSON"), ReplyDecision::Ignore);
    assert_eq!(
        resumed.observe(&key, 2, r#"{"passed": false}"#),
        ReplyDecision::Accept(json!({"passed": false}))
    );
}

#[test]
fn workflow_reply_second_schema_mismatch_fails_without_third_request() {
    let key = AttemptKey::new("activity");
    let mut policy = ReplyPolicy::new(&schema(), ReplyState::new(key.clone())).unwrap();
    let ReplyDecision::Correct { prompt, issues } = policy.observe(&key, 1, r#"{"passed": "yes"}"#)
    else {
        panic!("one correction required")
    };
    assert!(prompt.contains("/passed"));
    assert!(
        matches!(issues.as_slice(), [ReplyIssue::SchemaMismatch { instance_path, .. }] if instance_path == "/passed")
    );
    assert!(matches!(policy.observe(&key, 2, "{}"), ReplyDecision::Fail { .. }));
    assert_eq!(policy.observe(&key, 3, r#"{"passed": true}"#), ReplyDecision::Ignore);
}

#[test]
fn workflow_reply_ignores_another_activity_and_stale_incarnation() {
    let key = AttemptKey::new("activity");
    let mut policy = ReplyPolicy::new(&schema(), ReplyState::new(key.clone())).unwrap();
    assert_eq!(policy.observe(&AttemptKey::new("other"), 99, "wrong"), ReplyDecision::Ignore);
    assert_eq!(
        policy.observe(
            &AttemptKey { activity_id: key.activity_id.clone(), generation: 1 },
            99,
            "wrong"
        ),
        ReplyDecision::Ignore
    );
    assert!(!policy.state().correction_requested);
    assert_eq!(
        policy.observe(&key, 1, r#"{"passed": true}"#),
        ReplyDecision::Accept(json!({"passed": true}))
    );
}

#[test]
fn workflow_recovery_nudges_then_restarts_then_fails_across_resume() {
    let key = AttemptKey::new("activity");
    let mut state = RecoveryState::new(key.clone());
    assert_eq!(state.observe(&key, 1, RecoveryEvent::Stalled), RecoveryAction::Nudge);
    let saved = serde_json::to_string(&state).unwrap();
    let mut resumed: RecoveryState = serde_json::from_str(&saved).unwrap();
    assert_eq!(resumed.observe(&key, 1, RecoveryEvent::Stalled), RecoveryAction::None);
    let RecoveryAction::Restart { key: next } = resumed.observe(&key, 2, RecoveryEvent::RouteError)
    else {
        panic!("second stall restarts")
    };
    assert_eq!(next.generation, 1);
    assert_eq!(resumed.observe(&key, 3, RecoveryEvent::Completed), RecoveryAction::None);
    assert_eq!(resumed.observe(&next, 1, RecoveryEvent::Stalled), RecoveryAction::Fail);
    assert_eq!(resumed.observe(&next, 2, RecoveryEvent::RouteError), RecoveryAction::None);
}

#[test]
fn workflow_recovery_terminal_events_fence_later_nudges() {
    for event in [RecoveryEvent::Completed, RecoveryEvent::Failed] {
        let key = AttemptKey::new("activity");
        let mut state = RecoveryState::new(key.clone());
        state.observe(&key, 1, event);
        assert_eq!(state.observe(&key, 2, RecoveryEvent::Stalled), RecoveryAction::None);
        assert_eq!(state.observe(&key, 3, RecoveryEvent::RouteError), RecoveryAction::None);
    }
}

#[test]
fn workflow_recovery_waits_on_limits_capacity_and_permission_without_switching() {
    for reason in [
        WaitReason::Permission,
        WaitReason::Capacity,
        WaitReason::UsageLimit { reset_at_ms: Some(42) },
    ] {
        let key = AttemptKey::new("activity");
        let mut state = RecoveryState::new(key.clone());
        assert_eq!(
            state.observe(&key, 1, RecoveryEvent::Waiting(reason.clone())),
            RecoveryAction::Wait(reason.clone())
        );
        assert_eq!(state.observe(&key, 2, RecoveryEvent::Stalled), RecoveryAction::None);
        assert_eq!(state.observe(&key, 3, RecoveryEvent::RouteError), RecoveryAction::None);
        assert_eq!(state.stage, RecoveryStage::Watching);
        assert_eq!(state.observe(&key, 4, RecoveryEvent::Resumed), RecoveryAction::None);
        assert_eq!(state.observe(&key, 5, RecoveryEvent::Stalled), RecoveryAction::Nudge);
    }
}

#[test]
fn workflow_recovery_other_activity_cannot_advance_cursor_or_escalation() {
    let key = AttemptKey::new("activity");
    let mut state = RecoveryState::new(key.clone());
    assert_eq!(
        state.observe(&AttemptKey::new("other"), 100, RecoveryEvent::Stalled),
        RecoveryAction::None
    );
    assert_eq!(state.observe(&key, 1, RecoveryEvent::Stalled), RecoveryAction::Nudge);
}
