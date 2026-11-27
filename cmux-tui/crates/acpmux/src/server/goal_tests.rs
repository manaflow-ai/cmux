use super::*;
use serde_json::json;

#[test]
fn set_needs_an_objective_and_a_done_when_and_checks_budgets() {
    let ok = request(&json!({"objective": " Ship it ", "doneWhen": "CI green", "tokenBudget": 5}));
    assert_eq!(
        ok.ok(),
        Some(GoalRequest {
            objective: "Ship it".into(),
            done_when: "CI green".into(),
            token_budget: Some(5),
            time_budget_minutes: None,
        })
    );
    assert!(request(&json!({"objective": "Ship it"})).is_err());
    assert!(request(&json!({"objective": "  ", "doneWhen": "x"})).is_err());
    assert!(request(&json!({"objective": "a", "doneWhen": "b", "tokenBudget": 0})).is_err());
    assert!(
        request(&json!({"objective": "a", "doneWhen": "b", "timeBudgetMinutes": "ten"})).is_err()
    );
    assert!(request(&json!({"objective": "a".repeat(MAX_TEXT + 1), "doneWhen": "b"})).is_err());
}
