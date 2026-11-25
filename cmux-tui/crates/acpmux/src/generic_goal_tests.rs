use super::*;

fn request() -> GoalRequest {
    GoalRequest {
        objective: "Make the suite pass".into(),
        done_when: "cargo test passes".into(),
        token_budget: Some(1_000),
        time_budget_minutes: Some(10),
    }
}

#[test]
fn a_new_goal_is_generic_running_and_keeps_its_done_when_on_the_wire() {
    let goal = new_goal(&request(), 5_000);
    assert!(is_generic(&goal));
    assert_eq!(done_when(&goal), "cargo test passes");
    let wire = goal.to_value();
    assert_eq!(wire.get("provider"), Some(&json!("generic")));
    assert_eq!(wire.get("lifecycle"), Some(&json!("running")));
    assert_eq!(wire.get("doneWhen"), Some(&json!("cargo test passes")));
    assert_eq!(wire.get("timeBudgetSeconds"), Some(&json!(600)));
    // Saved and loaded again (a restart, `deserialize_option`), it is the same goal.
    let back = GoalState::from_value(&wire, None);
    assert!(back.as_ref().is_some_and(is_generic));
    assert_eq!(back.as_ref().map(done_when), Some("cargo test passes"));
}

#[test]
fn a_running_goal_continues_and_counts() {
    let mut goal = new_goal(&request(), 0);
    let step = next_step(&mut goal, Some(100), 1_000);
    let text = match &step {
        Step::Continue(text) => text.as_str(),
        _ => "",
    };
    assert!(text.contains("Objective: Make the suite pass"));
    assert!(text.contains("Done when: cargo test passes"));
    assert!(text.contains("goal_update"));
    assert_eq!(goal.tokens_used, Some(100));
    assert_eq!(goal.extra.get(CONTINUATIONS), Some(&json!(1)));
}

#[test]
fn budgets_and_the_cap_stop_it() {
    let mut goal = new_goal(&request(), 0);
    assert_eq!(next_step(&mut goal, Some(1_000), 1_000), Step::Stop("tokenBudget"));
    assert_eq!(goal.status, GoalStatus::BudgetLimited);
    assert_eq!(goal.lifecycle(), "stalled");

    let mut goal = new_goal(&request(), 0);
    assert_eq!(next_step(&mut goal, None, 600_000), Step::Stop("timeBudget"));
    assert_eq!(goal.status, GoalStatus::BudgetLimited);

    let mut goal =
        new_goal(&GoalRequest { token_budget: None, time_budget_minutes: None, ..request() }, 0);
    for _ in 0..MAX_CONTINUATIONS {
        assert!(matches!(next_step(&mut goal, None, 1), Step::Continue(_)));
    }
    assert_eq!(next_step(&mut goal, None, 1), Step::Stop("continuationLimit"));
    assert_eq!(goal.status, GoalStatus::Stalled);
}

#[test]
fn complete_blocked_and_other_goals_get_no_prompt() {
    let mut goal = new_goal(&request(), 0);
    apply_report(&mut goal, Reported::Complete, Some("all green"), 2_000);
    assert_eq!(goal.lifecycle(), "done");
    assert_eq!(goal.extra.get(NOTE), Some(&json!("all green")));
    assert_eq!(next_step(&mut goal, None, 3_000), Step::None);

    let mut goal = new_goal(&request(), 0);
    apply_report(&mut goal, Reported::Blocked, Some("needs a token"), 2_000);
    assert_eq!(goal.lifecycle(), "stalled");
    assert_eq!(next_step(&mut goal, None, 3_000), Step::None);
    // Going on again starts its count over.
    apply_report(&mut goal, Reported::Running, None, 4_000);
    assert!(matches!(next_step(&mut goal, None, 5_000), Step::Continue(_)));
    assert_eq!(goal.extra.get(CONTINUATIONS), Some(&json!(1)));

    // Claude's loop and Codex's goal are never prompted here.
    let mut codex = GoalState { provider: GoalProvider::Codex, ..new_goal(&request(), 0) };
    assert_eq!(next_step(&mut codex, None, 1), Step::None);
}

/// Completed, running again and stepped once more in the same millisecond, the goal is not
/// the state a continuation sent before was marked with: its count and times came back to the
/// same values, its generation did not. Codex review of #36641, F1.
#[test]
fn a_goal_changed_in_the_same_millisecond_gets_another_mark() {
    let mut goal = new_goal(&request(), 0);
    assert!(matches!(next_step(&mut goal, None, 7), Step::Continue(_)));
    let sent = mark(&goal);
    apply_report(&mut goal, Reported::Complete, None, 7);
    apply_report(&mut goal, Reported::Running, None, 7);
    assert!(matches!(next_step(&mut goal, None, 7), Step::Continue(_)));
    assert_ne!(mark(&goal), sent);
}

#[test]
fn reported_statuses_parse() {
    assert_eq!(Reported::parse(" Complete "), Some(Reported::Complete));
    assert_eq!(Reported::parse("done"), Some(Reported::Complete));
    assert_eq!(Reported::parse("blocked"), Some(Reported::Blocked));
    assert_eq!(Reported::parse("paused"), None);
}
