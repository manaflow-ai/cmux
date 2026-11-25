use super::*;
use serde_json::json;

#[test]
fn normalizes_legacy_codex_goal_and_preserves_elapsed_fields() {
    let goal = GoalState::from_value(
        &json!({
            "objective": "Keep typing responsive",
            "status": "active",
            "tokensUsed": 240,
            "tokenBudget": 12000,
            "timeUsedSeconds": 42,
            "createdAt": 10,
            "updatedAt": 52,
            "steps": [{"title": "Inspect", "status": "done"}]
        }),
        Some("codex"),
    )
    .unwrap();
    assert_eq!(goal.provider, GoalProvider::Codex);
    assert_eq!(goal.status, GoalStatus::Running);
    assert_eq!(goal.lifecycle(), "running");
    assert_eq!(goal.elapsed_seconds, Some(42));
    assert_eq!(goal.steps.as_ref().unwrap().len(), 1);
    assert_eq!(goal.to_value()["timeUsedSeconds"], 42);
    assert_eq!(goal.to_value()["status"], "active");
    assert_eq!(goal.to_value()["lifecycle"], "running");

    let usage = GoalState::from_value(
        &json!({"objective": "Wait for quota", "status": "usageLimited"}),
        Some("codex"),
    )
    .unwrap();
    assert_eq!(usage.to_value()["status"], "usageLimited");
    assert_eq!(usage.to_value()["lifecycle"], "stalled");
}

#[test]
fn normalizes_claude_loop_aliases_and_rejects_empty_objectives() {
    let goal = GoalState::from_value(
        &json!({"objective": "Review the changes", "state": "stalled", "source": "anthropic"}),
        None,
    )
    .unwrap();
    assert_eq!(goal.provider, GoalProvider::Claude);
    assert_eq!(goal.status, GoalStatus::Stalled);
    assert_eq!(goal.lifecycle(), "stalled");
    assert!(
        GoalState::from_value(&json!({"objective": "  ", "status": "running"}), None).is_none()
    );
    let autonomous = GoalState::from_value(
        &json!({"objective": "", "autonomous": true, "status": "active", "provider": "claude"}),
        None,
    )
    .unwrap();
    assert_eq!(autonomous.provider, GoalProvider::Claude);
}

#[test]
fn persists_usage_and_budget_stop_reasons() {
    for raw in ["usageLimited", "budgetLimited"] {
        let goal = GoalState::from_value(
            &json!({"objective": "Wait for quota", "status": raw}),
            Some("codex"),
        )
        .unwrap();
        let encoded = serde_json::to_value(&goal).unwrap();
        assert_eq!(encoded["status"], raw);
        let restored: GoalState = serde_json::from_value(encoded).unwrap();
        assert_eq!(restored.status, GoalStatus::from_name(raw));
        assert_eq!(restored.lifecycle(), "stalled");
    }
}

#[test]
fn derives_running_then_done_claude_loop_from_plan_updates() {
    let running = GoalState::from_plan_update(&json!({
        "sessionUpdate": "plan",
        "entries": [
            {"content": "Inspect the change", "status": "completed"},
            {"content": "Run the check", "status": "in_progress"}
        ]
    }))
    .unwrap();
    assert_eq!(running.provider, GoalProvider::Claude);
    assert_eq!(running.objective, "Run the check");
    assert_eq!(running.lifecycle(), "running");
    assert_eq!(running.extra.get("kind"), Some(&json!("plan")));
    let done = GoalState::from_plan_update(&json!({
        "sessionUpdate": "plan",
        "entries": [{"content": "Run the check", "status": "completed"}]
    }))
    .unwrap();
    assert_eq!(done.lifecycle(), "done");
    let stalled = GoalState::from_plan_update(&json!({
        "sessionUpdate": "plan",
        "entries": [{"content": "Run the check", "status": "blocked"}]
    }))
    .unwrap();
    assert_eq!(stalled.lifecycle(), "stalled");
}

#[test]
fn drops_malformed_legacy_fields_without_failing_the_session() {
    let goal = GoalState::from_value(
        &json!({
            "objective": "Keep going",
            "status": 42,
            "provider": null,
            "tokenBudget": -1,
            "tokensUsed": "unknown",
            "steps": "not-a-list"
        }),
        Some("codex"),
    )
    .unwrap();
    assert_eq!(goal.provider, GoalProvider::Codex);
    assert_eq!(goal.lifecycle(), "running");
    assert_eq!(goal.token_budget, None);
    assert_eq!(goal.steps, None);
}

#[test]
fn persisted_goal_migration_drops_invalid_objects() {
    #[derive(Deserialize)]
    struct Stored {
        #[serde(default, deserialize_with = "crate::goal::deserialize_option")]
        goal: Option<GoalState>,
    }

    let stored: Stored = serde_json::from_value(json!({
        "goal": {
            "objective": "Keep going",
            "status": "running",
            "tokenBudget": "old-format"
        }
    }))
    .unwrap();
    assert_eq!(stored.goal.unwrap().objective, "Keep going");
}
