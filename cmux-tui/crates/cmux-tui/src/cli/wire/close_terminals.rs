//! The terminals a `tab`, `pane`, `screen` or `workspace` close leaves with
//! no tab (W7-C: close ends what it closed). The CLI sends `terminals`
//! (`end`, or `keep` with `--keep-terminals`); a daemon older than
//! `close-ends-terminals-v1` refuses the unknown field, so the CLI drops it
//! there and the close detaches its terminals as that daemon always did. A
//! person's close names the terminals it ended and the ones still running,
//! with the way to see and end them. `wire::run_once` and the agents/MCP
//! transport (`mcp/transport.rs`) both send through here.

use std::io::BufReader;
use std::path::Path;

use serde_json::Value;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use cmux_tui_core::server::CLOSE_ENDS_TERMINALS_CAPABILITY;

use super::super::command::{RequestPlan, WireOperation};

const CLOSES: [ResourceOperation; 4] = [
    ResourceOperation::TabClose,
    ResourceOperation::PaneClose,
    ResourceOperation::ScreenClose,
    ResourceOperation::WorkspaceClose,
];

fn is_close(operation: &Value) -> bool {
    CLOSES.iter().any(|close| operation == close.wire_name())
}

/// Removes `terminals` from a close the daemon cannot take; true when the
/// request changed.
pub(in crate::cli) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    if !request.get("operation").is_some_and(is_close)
        || request.get("params").and_then(|params| params.get("terminals")).is_none()
        || super::super::launch_credential::advertises(
            reader,
            socket,
            CLOSE_ENDS_TERMINALS_CAPABILITY,
        )
    {
        return false;
    }
    request
        .get_mut("params")
        .and_then(Value::as_object_mut)
        .is_some_and(|params| params.remove("terminals").is_some())
}

/// The lines a person's close adds after its result: how many terminals it
/// ended, and which ones still run with no tab and how to see them. None for
/// any other command, and for a close that ended and left nothing.
pub(super) fn human_note(plan: &RequestPlan, result: &Value) -> Option<String> {
    let WireOperation::Typed(operation) = &plan.operation else { return None };
    if !CLOSES.contains(operation) {
        return None;
    }
    let ids = |field: &str| -> Vec<&str> {
        result
            .pointer(&format!("/value/{field}"))
            .or_else(|| result.get(field))
            .and_then(Value::as_array)
            .map(|ids| ids.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default()
    };
    let (ended, running) = (ids("ended_terminal_ids"), ids("running_terminal_ids"));
    let messages = &crate::localization::catalog().pane_cli;
    let mut lines = Vec::new();
    if !ended.is_empty() {
        lines.push(messages.close_ended_terminals.replace("{count}", &ended.len().to_string()));
    }
    if !running.is_empty() {
        lines.push(
            messages
                .close_running_terminals
                .replace("{count}", &running.len().to_string())
                .replace("{ids}", &running.join(", ")),
        );
    }
    (!lines.is_empty()).then(|| lines.join("\n"))
}
