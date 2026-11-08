#![allow(dead_code)] // Red stub: `agent list` as before (no `status`); the fix adds it.
//! `cmux agent list`: the daemon's `agent.list` rows.

use std::collections::HashSet;

use serde_json::Value;

use super::command::RequestPlan;
use super::{GlobalArgs, wire};

/// A parsed `agent list` (`command.rs` `parse_agent`).
#[derive(Clone, Debug)]
pub(super) struct AgentListPlan {
    pub request: RequestPlan,
    pub status: Option<&'static str>,
}

/// The words `agent list --state` takes.
pub(super) const STATUS_WORDS: [&str; 5] = ["working", "blocked", "idle", "done", "unknown"];

/// The daemon `state` that `agent list --state <status>` asks for.
pub(super) fn daemon_state_for_status(status: &str) -> &str {
    status
}

pub(super) fn run(global: GlobalArgs, plan: AgentListPlan) -> i32 {
    match wire::fetch(&global, plan.request) {
        Ok(rows) => {
            wire::print_local_success(&shape(rows, &HashSet::new(), plan.status), global.output)
        }
        Err(error) => wire::print_local_error(&error, global.output, 1),
    }
}

fn unseen_terminals(notifications: &[Value]) -> HashSet<&str> {
    let _ = notifications;
    HashSet::new()
}

fn shape(rows: Value, unseen: &HashSet<&str>, wanted: Option<&str>) -> Value {
    let _ = (unseen, wanted);
    rows
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    const IDLE_SEEN: &str = "term_11111111111111111111111111111111";
    const IDLE_UNSEEN: &str = "term_22222222222222222222222222222222";
    const ENDED_TERMINAL: &str = "term_33333333333333333333333333333333";
    const WORKING: &str = "term_44444444444444444444444444444444";

    fn rows() -> Value {
        json!([
            {"terminal_id": IDLE_SEEN, "state": "idle"},
            {"terminal_id": IDLE_UNSEEN, "state": "idle"},
            {"terminal_id": ENDED_TERMINAL, "state": "done"},
            {"terminal_id": WORKING, "state": "working"},
        ])
    }

    fn notifications() -> Vec<Value> {
        vec![
            json!({"terminal_id": IDLE_UNSEEN, "unread": true}),
            json!({"terminal_id": IDLE_SEEN, "unread": false}),
            // An unread notification on a working agent does not make it done.
            json!({"terminal_id": WORKING, "unread": true}),
        ]
    }

    fn statuses(shaped: &Value) -> Vec<(String, Value)> {
        shaped
            .as_array()
            .unwrap()
            .iter()
            .map(|row| (row["terminal_id"].as_str().unwrap().to_owned(), row["status"].clone()))
            .collect()
    }

    /// `done` is idle with an unread notification, as the TUI shows it; the
    /// daemon's `done` (a session that ended) is `status: null`; the
    /// daemon's `state` stays.
    #[test]
    fn w4j_agent_list_rows_carry_the_shared_status() {
        let notifications = notifications();
        let shaped = shape(rows(), &unseen_terminals(&notifications), None);
        assert_eq!(
            statuses(&shaped),
            vec![
                (IDLE_SEEN.to_owned(), json!("idle")),
                (IDLE_UNSEEN.to_owned(), json!("done")),
                (ENDED_TERMINAL.to_owned(), Value::Null),
                (WORKING.to_owned(), json!("working")),
            ]
        );
        assert_eq!(shaped[1]["state"], "idle");
        assert_eq!(shaped[2]["state"], "done");
    }

    #[test]
    fn w4j_agent_list_state_filter_keeps_rows_with_that_status_word() {
        let notifications = notifications();
        let unseen = unseen_terminals(&notifications);
        for (wanted, terminal) in
            [("done", IDLE_UNSEEN), ("idle", IDLE_SEEN), ("ended", ENDED_TERMINAL)]
        {
            let shaped = shape(rows(), &unseen, Some(wanted));
            let terminals = statuses(&shaped).into_iter().map(|(id, _)| id).collect::<Vec<_>>();
            assert_eq!(terminals, vec![terminal.to_owned()], "--state {wanted}");
        }
        // A refused notification read: every idle agent is idle.
        let shaped = shape(rows(), &HashSet::new(), Some("done"));
        assert_eq!(shaped, json!([]));
    }
}
