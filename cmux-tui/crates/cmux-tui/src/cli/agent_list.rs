//! `cmux agent list`: the daemon's `agent.list` rows with `status`, the one
//! agent status vocabulary of the TUI sidebar (`working`, `blocked`, `done`,
//! `idle`, `unknown`; `cmux_tui_core::AgentStatus`). `done` is a finished
//! turn nobody has viewed: an idle agent whose terminal has an unread
//! notification. The daemon's own `state` keeps `done` for a session that
//! ended; such a row has `status: null` and `--state ended` selects it.
//!
//! The daemon's fields are unchanged; only the CLI adds `status`, from one
//! `notification.list` read after `agent.list`, and the place of each
//! agent's terminal (`name`, `tab_id`, `tab_name`, `pane_id`), from one
//! `session.snapshot` read (W3-H).

use std::collections::HashSet;

use cmux_tui_core::AgentStatus;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Value, json};

use super::agent_names::valid_agent_name;
use super::command::{RequestPlan, ResponseView, WireOperation};
use super::{GlobalArgs, wire};

/// A parsed `agent list` (`command.rs` `parse_agent`).
#[derive(Clone, Debug)]
pub(super) struct AgentListPlan {
    /// The `agent.list` request, its `state` already the daemon's word
    /// ([`daemon_state_for_status`]).
    pub request: RequestPlan,
    /// `--state`: keep only the rows whose status is this word.
    pub status: Option<&'static str>,
}

/// The words `agent list --state` takes: the shared status vocabulary and
/// `ended`.
pub(super) const STATUS_WORDS: [&str; 6] =
    ["working", "blocked", "done", "idle", "unknown", "ended"];

/// The status word of a row whose session ended (`status: null`).
const ENDED: &str = "ended";

/// `notification.list`'s largest `limit`: a session keeps at most this many.
const NOTIFICATION_LIMIT: u32 = 256;

/// The daemon `state` that `agent list --state <status>` asks for; the CLI
/// then keeps the rows whose `status` is that word. `done` and `idle` are
/// both the daemon's `idle` (the unread marker tells them apart), and
/// `ended` is the daemon's `done`.
pub(super) fn daemon_state_for_status(status: &str) -> &str {
    match status {
        "done" | "idle" => "idle",
        ENDED => "done",
        other => other,
    }
}

pub(super) fn run(global: GlobalArgs, plan: AgentListPlan) -> i32 {
    let notifications = notifications_request(&plan.request);
    let snapshot = snapshot_request(&plan.request);
    let rows = match wire::fetch(&global, plan.request) {
        Ok(rows) => rows,
        Err(error) => return wire::print_local_error(&error, global.output, exit_code(&error)),
    };
    // A refused read (an older daemon) leaves every idle agent `idle`.
    let notifications = wire::fetch(&global, notifications)
        .ok()
        .and_then(|notifications| notifications.as_array().cloned())
        .unwrap_or_default();
    let shaped = shape(rows, &unseen_terminals(&notifications), plan.status);
    // A refused read leaves the place fields null.
    let snapshot = wire::fetch(&global, snapshot).unwrap_or(Value::Null);
    wire::print_local_success(&with_places(shaped, &snapshot), global.output)
}

/// The CLI exit code for a failed request: 2 for a usage error, 3 when the
/// session could not be reached, 1 for an error the server answered.
fn exit_code(error: &Value) -> i32 {
    let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
    if code.starts_with("usage.") {
        2
    } else if code.starts_with("transport.") {
        3
    } else {
        1
    }
}

/// `notification.list` on the same machine and session as `agents`.
fn notifications_request(agents: &RequestPlan) -> RequestPlan {
    let mut params = json!({"limit": NOTIFICATION_LIMIT});
    for route in ["machine", "session"] {
        if let Some(value) = agents.params.get(route) {
            params[route] = value.clone();
        }
    }
    RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::NotificationList),
        params,
        idempotency_key: None,
        stream: false,
        view: ResponseView::Full,
    }
}

/// `session.snapshot` on the same machine and session as `agents`.
fn snapshot_request(agents: &RequestPlan) -> RequestPlan {
    let mut params = json!({"session": "current"});
    for route in ["machine", "session"] {
        if let Some(value) = agents.params.get(route) {
            params[route] = value.clone();
        }
    }
    RequestPlan {
        operation: WireOperation::Typed(ResourceOperation::SessionSnapshot),
        params,
        idempotency_key: None,
        stream: false,
        view: ResponseView::Full,
    }
}

fn list<'a>(snapshot: &'a Value, key: &str) -> &'a [Value] {
    snapshot[key].as_array().map(Vec::as_slice).unwrap_or_default()
}

/// Each row with the place of its terminal in `snapshot`: `tab_id`,
/// `tab_name` and `pane_id` of the tab that shows it, and `name`, the tab's
/// name when it is an agent name (`cmux agent start NAME`), else null. A
/// terminal the snapshot does not show (or no snapshot) gives nulls.
fn with_places(rows: Value, snapshot: &Value) -> Value {
    let mut agents = match rows {
        Value::Array(rows) => rows,
        other => return other,
    };
    let terminals = list(snapshot, "terminals");
    let tabs = list(snapshot, "tabs");
    for agent in &mut agents {
        let terminal = agent.get("terminal_id").and_then(Value::as_str).unwrap_or_default();
        let tab_id = terminals
            .iter()
            .find(|candidate| candidate["id"] == terminal)
            .and_then(|candidate| candidate["tab_id"].as_str());
        let tab = tabs.iter().find(|tab| match tab_id {
            Some(id) => tab["id"] == id,
            None => !terminal.is_empty() && tab["content_id"] == terminal,
        });
        let text = |key: &str| tab.and_then(|tab| tab[key].as_str()).map(str::to_owned);
        let tab_name = text("name");
        let name = tab_name.clone().filter(|name| valid_agent_name(name).is_ok());
        let (tab_id, pane_id) = (text("id"), text("pane_id"));
        if let Some(object) = agent.as_object_mut() {
            object.insert("name".into(), json!(name));
            object.insert("tab_id".into(), json!(tab_id));
            object.insert("tab_name".into(), json!(tab_name));
            object.insert("pane_id".into(), json!(pane_id));
        }
    }
    Value::Array(agents)
}

/// The terminals with an unread notification: a turn finished there that
/// nobody has viewed (done-until-seen). `notifications` are
/// `notification.list` rows.
fn unseen_terminals(notifications: &[Value]) -> HashSet<&str> {
    notifications
        .iter()
        .filter(|notification| notification["unread"] == true)
        .filter_map(|notification| notification["terminal_id"].as_str())
        .collect()
}

/// The printed rows: each daemon row with `status` (its terminal is in
/// `unseen` when it has an unread notification), only the rows with status
/// word `wanted` when given. Anything but an array prints as it came.
fn shape(rows: Value, unseen: &HashSet<&str>, wanted: Option<&str>) -> Value {
    let mut agents = match rows {
        Value::Array(rows) => rows,
        other => return other,
    };
    for agent in &mut agents {
        let status = status_of(agent, unseen).map(AgentStatus::as_str);
        if let Some(object) = agent.as_object_mut() {
            object.insert("status".into(), json!(status));
        }
    }
    if let Some(wanted) = wanted {
        agents.retain(|agent| status_word(agent) == wanted);
    }
    Value::Array(agents)
}

/// The shared status of a listed agent: from the daemon's `state`, `done`
/// for an idle agent whose terminal is in `unseen`. `None` for a session
/// that ended; a state the CLI does not know is `unknown`.
fn status_of(agent: &Value, unseen: &HashSet<&str>) -> Option<AgentStatus> {
    let state = agent.get("state").and_then(Value::as_str).unwrap_or_default();
    let unseen = agent
        .get("terminal_id")
        .and_then(Value::as_str)
        .is_some_and(|terminal| unseen.contains(terminal));
    AgentStatus::from_state_str(state, unseen)
}

/// The row's status word ([`shape`] set it): `ended` for `status: null`.
fn status_word(agent: &Value) -> &str {
    agent.get("status").and_then(Value::as_str).unwrap_or(ENDED)
}

#[cfg(test)]
mod tests {
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

    /// W3-H: each row names the tab, pane and agent name of its terminal
    /// (feat's `terminal list --agents` fields; main lists agents here).
    #[test]
    fn w3h_agent_list_rows_carry_the_tab_pane_and_agent_name() {
        let snapshot = json!({
            "terminals": [
                {"id": IDLE_SEEN, "tab_id": "tab_alpha"},
                {"id": IDLE_UNSEEN, "tab_id": "tab_shell"},
            ],
            "tabs": [
                {"id": "tab_alpha", "name": "alpha", "pane_id": "pane_1", "content_id": IDLE_SEEN},
                {"id": "tab_shell", "name": "My Shell", "pane_id": "pane_2", "content_id": IDLE_UNSEEN},
                {"id": "tab_ended", "name": "old", "pane_id": "pane_2", "content_id": ENDED_TERMINAL},
            ],
        });
        let placed = with_places(rows(), &snapshot);
        let fields = |index: usize| {
            let row = &placed[index];
            [&row["name"], &row["tab_id"], &row["tab_name"], &row["pane_id"]].map(Value::clone)
        };
        assert_eq!(
            fields(0),
            [json!("alpha"), json!("tab_alpha"), json!("alpha"), json!("pane_1")]
        );
        // A tab name that is not an agent name is no `name`.
        assert_eq!(
            fields(1),
            [Value::Null, json!("tab_shell"), json!("My Shell"), json!("pane_2")]
        );
        // No terminal record: the tab that shows the terminal.
        assert_eq!(fields(2), [json!("old"), json!("tab_ended"), json!("old"), json!("pane_2")]);
        // A terminal the snapshot does not show, or no snapshot: nulls.
        assert_eq!(fields(3), [Value::Null, Value::Null, Value::Null, Value::Null]);
        assert_eq!(with_places(rows(), &Value::Null)[0]["tab_id"], Value::Null);
        // The daemon's fields stay.
        assert_eq!(placed[0]["state"], "idle");
    }
}
