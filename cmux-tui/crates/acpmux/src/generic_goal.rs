//! A goal on any harness: the one the agent sets with the `acpmux` MCP server's `goal_set`
//! (`acpmux_mcp_goal.rs`), kept on the session as its `GoalState` (`goal.rs`, provider
//! `generic`), which the pane's goal strip draws as it draws Codex's. Its done-when lives here,
//! outside the agent, so it survives a compaction or a restart (the session's saved meta).
//!
//! At each completed turn the hub (`hub/goal_tools.rs`) asks [`next_step`]: while the goal runs,
//! acpmux prompts the chat to go on, naming the objective and its done-when, until the agent calls
//! `goal_update` with `complete` or `blocked`, a budget runs out, or [`MAX_CONTINUATIONS`] prompts
//! went. Codex keeps its own goal and Claude Code its own `/loop`, so neither is prompted here.
//! Leo, 2026-11-05: "i meant can you do all of htem", the ranked moves of the 11-05 audit, whose
//! move 7 is a `/goal` that works on every harness.

use crate::goal::{GoalProvider, GoalState, GoalStatus};
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// The most continuation prompts one goal gets: a safety net under the budgets.
pub const MAX_CONTINUATIONS: u64 = 50;
/// The goal's kind (`extra.kind`), apart from Claude's `loop` and `plan`.
pub const KIND: &str = "goal";
const DONE_WHEN: &str = "doneWhen";
const TIME_BUDGET: &str = "timeBudgetSeconds";
const STARTED: &str = "startedAtMs";
const CONTINUATIONS: &str = "continuations";
const NOTE: &str = "note";
const STOP_REASON: &str = "stopReason";

/// What `goal_set` asks for.
#[derive(Debug, Clone, PartialEq)]
pub struct GoalRequest {
    pub objective: String,
    pub done_when: String,
    pub token_budget: Option<u64>,
    pub time_budget_minutes: Option<u64>,
}

/// A new running goal, started at `now_ms`.
pub fn new_goal(request: &GoalRequest, now_ms: u64) -> GoalState {
    let mut extra = BTreeMap::from([
        ("kind".to_owned(), json!(KIND)),
        (DONE_WHEN.to_owned(), json!(request.done_when)),
        (STARTED.to_owned(), json!(now_ms)),
        (CONTINUATIONS.to_owned(), json!(0)),
    ]);
    if let Some(minutes) = request.time_budget_minutes {
        extra.insert(TIME_BUDGET.to_owned(), json!(minutes.saturating_mul(60)));
    }
    GoalState {
        objective: request.objective.clone(),
        status: GoalStatus::Running,
        provider: GoalProvider::Generic,
        token_budget: request.token_budget,
        tokens_used: request.token_budget.map(|_| 0),
        elapsed_seconds: Some(0),
        created_at: Some(json!(now_ms)),
        updated_at: Some(json!(now_ms)),
        steps: None,
        extra,
    }
}

/// Whether `goal` is one acpmux keeps going (set through `goal_set`).
pub fn is_generic(goal: &GoalState) -> bool {
    goal.provider == GoalProvider::Generic
        && goal.extra.get("kind").and_then(Value::as_str) == Some(KIND)
}

/// Which state of `goal` a continuation was sent for: any later change (a report, a new goal, the
/// next turn's step) gives another mark, so a continuation that waited sees its goal moved on.
pub fn mark(goal: &GoalState) -> String {
    let count = goal.extra.get(CONTINUATIONS).and_then(Value::as_u64).unwrap_or(0);
    let at = |v: &Option<Value>| v.as_ref().map(Value::to_string).unwrap_or_default();
    format!("{}:{}:{count}", at(&goal.created_at), at(&goal.updated_at))
}

/// The goal's done-when.
pub fn done_when(goal: &GoalState) -> &str {
    goal.extra.get(DONE_WHEN).and_then(Value::as_str).unwrap_or_default()
}

/// The statuses `goal_update` takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reported {
    Running,
    Blocked,
    Complete,
}

impl Reported {
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "running" => Some(Self::Running),
            "blocked" => Some(Self::Blocked),
            "complete" | "completed" | "done" => Some(Self::Complete),
            _ => None,
        }
    }
}

/// `goal` after the agent reported `status` (and `note`, kept as the strip's latest word).
/// Running again after a stop starts its continuation count over; the budgets keep counting.
pub fn apply_report(goal: &mut GoalState, status: Reported, note: Option<&str>, now_ms: u64) {
    goal.status = match status {
        Reported::Running => GoalStatus::Running,
        Reported::Blocked => GoalStatus::Stalled,
        Reported::Complete => GoalStatus::Done,
    };
    match status {
        Reported::Running => {
            goal.extra.remove(STOP_REASON);
            goal.extra.insert(CONTINUATIONS.to_owned(), json!(0));
        }
        Reported::Blocked => {
            goal.extra.insert(STOP_REASON.to_owned(), json!("blocked"));
        }
        Reported::Complete => {
            goal.extra.remove(STOP_REASON);
        }
    }
    match note.map(str::trim).filter(|n| !n.is_empty()) {
        Some(note) => goal.extra.insert(NOTE.to_owned(), json!(note)),
        None => goal.extra.remove(NOTE),
    };
    touch(goal, now_ms);
}

fn touch(goal: &mut GoalState, now_ms: u64) {
    goal.updated_at = Some(json!(now_ms));
    if let Some(started) = goal.extra.get(STARTED).and_then(Value::as_u64) {
        goal.elapsed_seconds = Some(now_ms.saturating_sub(started) / 1000);
    }
}

/// What acpmux does at a completed turn's end.
#[derive(Debug, Clone, PartialEq)]
pub enum Step {
    /// Not a running generic goal: nothing.
    None,
    /// Prompt the chat with this text; the goal is updated (its count and time).
    Continue(String),
    /// The goal stops here with this status and reason; the goal is updated.
    Stop(&'static str),
}

/// The step after a completed turn that spent `turn_tokens` (None when the harness reports none),
/// at `now_ms`, updating `goal` (tokens, time, continuations, a stop's status).
pub fn next_step(goal: &mut GoalState, turn_tokens: Option<u64>, now_ms: u64) -> Step {
    if !is_generic(goal) || goal.status != GoalStatus::Running {
        return Step::None;
    }
    if let (Some(used), Some(spent)) = (goal.tokens_used, turn_tokens) {
        goal.tokens_used = Some(used.saturating_add(spent));
    }
    touch(goal, now_ms);
    let stop = |goal: &mut GoalState, status: GoalStatus, reason: &'static str| {
        goal.status = status;
        goal.extra.insert(STOP_REASON.to_owned(), json!(reason));
        Step::Stop(reason)
    };
    if let (Some(budget), Some(used)) = (goal.token_budget, goal.tokens_used)
        && used >= budget
    {
        return stop(goal, GoalStatus::BudgetLimited, "tokenBudget");
    }
    if let (Some(budget), Some(elapsed)) =
        (goal.extra.get(TIME_BUDGET).and_then(Value::as_u64), goal.elapsed_seconds)
        && elapsed >= budget
    {
        return stop(goal, GoalStatus::BudgetLimited, "timeBudget");
    }
    let sent = goal.extra.get(CONTINUATIONS).and_then(Value::as_u64).unwrap_or(0);
    if sent >= MAX_CONTINUATIONS {
        return stop(goal, GoalStatus::Stalled, "continuationLimit");
    }
    goal.extra.insert(CONTINUATIONS.to_owned(), json!(sent + 1));
    Step::Continue(continuation(goal, sent + 1))
}

/// The prompt that keeps the goal going.
fn continuation(goal: &GoalState, count: u64) -> String {
    format!(
        "Keep working toward the goal (continuation {count} of at most {MAX_CONTINUATIONS}).\n\
         Objective: {}\nDone when: {}\n\
         Check done-when yourself before you stop. When it holds, call goal_update with status \
         \"complete\" and a one-line note of the evidence. If you need the person (a decision, \
         access, something only they can do), call goal_update with status \"blocked\" and say \
         what you need. Otherwise go on with the next step; acpmux prompts you again when this \
         turn ends.",
        goal.objective,
        done_when(goal),
    )
}

#[cfg(test)]
mod tests {
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

        let mut goal = new_goal(
            &GoalRequest { token_budget: None, time_budget_minutes: None, ..request() },
            0,
        );
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

    #[test]
    fn reported_statuses_parse() {
        assert_eq!(Reported::parse(" Complete "), Some(Reported::Complete));
        assert_eq!(Reported::parse("done"), Some(Reported::Complete));
        assert_eq!(Reported::parse("blocked"), Some(Reported::Blocked));
        assert_eq!(Reported::parse("paused"), None);
    }
}
