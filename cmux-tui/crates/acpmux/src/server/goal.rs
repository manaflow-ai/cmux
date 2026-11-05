//! The goal methods (`hub/goal_tools.rs`): `_acpmux/goal/set {sessionId, objective, doneWhen,
//! tokenBudget?, timeBudgetMinutes?}`, `_acpmux/goal/update {sessionId, status, note?}` and
//! `_acpmux/goal/get {sessionId}`, each answering the goal (`GoalState::to_value`, null for none).
//!
//! Like the background-task methods (`bg_tasks.rs`) they belong to the chat's own agent (a
//! connection that proved it runs in that chat, `hub/person.rs` (a): the `acpmux` MCP server)
//! and the person; a remote WebSocket device and a peer are refused.

use super::{Conn, str_param};
use crate::generic_goal::{GoalRequest, Reported};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The longest objective or done-when, in characters: a goal is a line or two, not a document.
const MAX_TEXT: usize = 2_000;

/// The reply to a goal method, or None for any other method.
pub(super) fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_GOAL_SET | method::MUX_GOAL_UPDATE | method::MUX_GOAL_GET) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(handle(hub, conn, m, params))
}

fn handle(hub: &Arc<Hub>, conn: &Conn, m: &str, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    // The chat's own agent (its proven caller token) or the person; nothing else.
    if conn.caller() != Some(session.id.as_str()) && !conn.is_person() {
        return Err(RpcError::invalid_params("a chat reaches only its own goal"));
    }
    match m {
        method::MUX_GOAL_SET => hub.goal_set(&session, &request(params)?),
        method::MUX_GOAL_UPDATE => {
            let status = str_param(params, "status")
                .and_then(Reported::parse)
                .ok_or_else(|| {
                    RpcError::invalid_params("status must be running, blocked or complete")
                })?;
            hub.goal_update(&session, status, str_param(params, "note"))
        }
        _ => Ok(hub.goal_get(&session)),
    }
}

/// `goal/set`'s params, checked.
pub(crate) fn request(params: &Value) -> Result<GoalRequest, RpcError> {
    let text = |key: &str| {
        str_param(params, key)
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
            .and_then(|t| {
                if t.chars().count() > MAX_TEXT {
                    Err(RpcError::invalid_params(format!("{key} is over {MAX_TEXT} characters")))
                } else {
                    Ok(t.to_owned())
                }
            })
    };
    let count = |key: &str| match params.get(key).filter(|v| !v.is_null()) {
        None => Ok(None),
        Some(v) => v
            .as_u64()
            .filter(|n| *n > 0)
            .map(Some)
            .ok_or_else(|| RpcError::invalid_params(format!("{key} must be a whole number above 0"))),
    };
    Ok(GoalRequest {
        objective: text("objective")?,
        done_when: text("doneWhen")?,
        token_budget: count("tokenBudget")?,
        time_budget_minutes: count("timeBudgetMinutes")?,
    })
}

#[cfg(test)]
mod tests {
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
        assert!(request(&json!({"objective": "a", "doneWhen": "b", "timeBudgetMinutes": "ten"})).is_err());
        assert!(request(&json!({"objective": "a".repeat(MAX_TEXT + 1), "doneWhen": "b"})).is_err());
    }
}
