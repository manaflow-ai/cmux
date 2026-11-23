//! `terminal <t> status`: the terminal's program status records (OSC 7501)
//! with the status word every agent list shows (W5-Q, bench round 4 #7).
//!
//! A program reports its own words: Claude Code says `done` when a turn
//! ends. The lists say `idle` once somebody viewed that turn and `done`
//! until then, and a hook's record wins over the program's report. Each
//! record gets that `status` (`roster::status_of` and the roster row, the
//! one source of truth); the human table shows it as STATE, and `--json`
//! keeps the program's own `state` beside it. A word with no shared meaning
//! (`error`) has `status: null` and keeps its own word in the table.

use std::io::BufReader;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

use super::super::agent_vocabulary::harness_name;
use super::super::command::{RequestPlan, ResponseView};
use super::super::terminal_talk::roster;

/// [`annotate`] for a `terminal status` result, with the terminal's agent
/// records and unread notifications read on the same connection. A refused
/// read (an older daemon) leaves the agent records out and every finished
/// turn `idle`. Any other command's result is returned as it is.
pub(super) fn with_agent_status(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    plan: &RequestPlan,
    result: Value,
) -> Value {
    if plan.view != ResponseView::TerminalProgramStatus {
        return result;
    }
    let Some(terminal) = result.get("id").and_then(Value::as_str).map(str::to_owned) else {
        return result;
    };
    let route: Map<String, Value> =
        plan.params.as_object().map(super::super::resolve::route).unwrap_or_default();
    let mut agent_params = route.clone();
    agent_params.insert("terminal_id".into(), json!(terminal));
    let agents = super::super::resolve::read(reader, ResourceOperation::AgentList, agent_params)
        .ok()
        .and_then(|agents| agents.as_array().cloned())
        .unwrap_or_default();
    let mut notification_params = route;
    notification_params.insert("limit".into(), json!(super::NOTIFICATION_LIMIT));
    let notifications = super::super::resolve::read(
        reader,
        ResourceOperation::NotificationList,
        notification_params,
    )
    .ok()
    .and_then(|notifications| notifications.as_array().cloned())
    .unwrap_or_default();
    let unseen = super::unseen_terminals(&notifications).contains(terminal.as_str());
    annotate(result, &agents, unseen)
}

/// The `terminal.get` `result` with each program status record's `status`.
/// `agents` are the terminal's daemon agent records; `unseen` is whether the
/// terminal has an unread notification. The record of the terminal's agent
/// (its harness's app) says the roster's word, as `terminal list --agents`.
pub(super) fn annotate(mut result: Value, agents: &[Value], unseen: bool) -> Value {
    let row = roster::agent_of_terminal(&result, agents, unseen);
    let Some(records) = result.pointer_mut("/extra/program_status").and_then(Value::as_array_mut)
    else {
        return result;
    };
    for record in records.iter_mut() {
        let word = record.get("state").and_then(Value::as_str).unwrap_or_default();
        let app = record.get("app").and_then(Value::as_str).map(harness_name);
        let status = match &row {
            Some(row) if app.as_deref() == Some(harness_name(&row.harness).as_str()) => {
                Some(row.status_word())
            }
            _ if matches!(word, "ended" | "exited") => Some("ended"),
            _ => roster::status_of(word, unseen).map(cmux_tui_core::AgentStatus::as_str),
        };
        if let Some(object) = record.as_object_mut() {
            object.insert("status".into(), json!(status));
        }
    }
    result
}

/// What the human table shows for the records: one STATE column with the
/// shared word, or the program's own word where there is none.
pub(super) fn human_records(records: Value) -> Value {
    let Value::Array(mut records) = records else { return records };
    for record in &mut records {
        let Some(object) = record.as_object_mut() else { continue };
        if let Some(Value::String(status)) = object.remove("status") {
            object.insert("state".into(), Value::String(status));
        }
    }
    Value::Array(records)
}

#[cfg(test)]
#[path = "program_status_view/tests.rs"]
mod tests;
