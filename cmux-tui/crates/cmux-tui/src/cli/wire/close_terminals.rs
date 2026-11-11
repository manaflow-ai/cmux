//! The terminals a `tab`, `pane`, `screen` or `workspace` close (or a bulk
//! `layout.bulk` close) leaves with no tab (W7-C: one close model). The CLI
//! sends `terminals` (`grace`, `end` with `--now`, or `keep` with
//! `--keep-terminals`). A daemon without `close-grace-v1` refuses `grace`, so
//! the CLI sends it `end` (its own default); one older than
//! `close-ends-terminals-v1` refuses the field, so the CLI drops it there and
//! the close detaches its terminals as that daemon always did. A person's
//! close names the terminals it ended, the ones that end when the grace runs
//! out (and that `cmux closed reopen` keeps), and the ones still running.
//! `wire::run_once` and the agents/MCP transport (`mcp/transport.rs`) both
//! send through here.

use std::io::BufReader;
use std::path::Path;

use serde_json::Value;

use cmux_tui_core::platform::transport;
use cmux_tui_core::resource::ResourceOperation;
use cmux_tui_core::server::{CLOSE_ENDS_TERMINALS_CAPABILITY, CLOSE_GRACE_CAPABILITY};

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

/// Fits `terminals` to what the daemon takes: `grace` becomes `end` on a
/// daemon without `close-grace-v1`, and the field goes on one without
/// `close-ends-terminals-v1`. True when the request changed.
pub(in crate::cli) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    let terminals = request.get("params").and_then(|params| params.get("terminals"));
    if !request.get("operation").is_some_and(is_close) || terminals.is_none() {
        return false;
    }
    let grace = terminals.and_then(Value::as_str) == Some("grace");
    let advertises = |reader: &mut BufReader<Box<dyn transport::Stream>>, capability| {
        super::super::launch_credential::advertises(reader, socket, capability)
    };
    if grace && advertises(reader, CLOSE_GRACE_CAPABILITY) {
        return false;
    }
    let keeps_field = advertises(reader, CLOSE_ENDS_TERMINALS_CAPABILITY);
    if keeps_field && !grace {
        return false;
    }
    let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else {
        return false;
    };
    if keeps_field {
        params.insert("terminals".into(), Value::String("end".into()));
        true
    } else {
        params.remove("terminals").is_some()
    }
}

/// The lines a person's close adds after its result: how many terminals it
/// ended, and which ones still run with no tab and how to see them. None for
/// any other command, and for a close that ended and left nothing.
pub(super) fn human_note(plan: &RequestPlan, result: &Value) -> Option<String> {
    let WireOperation::Typed(operation) = &plan.operation else { return None };
    // A bulk close (`--others`, `--all`, ...) names its terminals the same way.
    if !CLOSES.contains(operation) && *operation != ResourceOperation::LayoutBulk {
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
    let ending = ids("ending_terminal_ids");
    let messages = &crate::localization::catalog().pane_cli;
    let mut lines = Vec::new();
    if !ended.is_empty() {
        lines.push(messages.close_ended_terminals.replace("{count}", &ended.len().to_string()));
    }
    if !ending.is_empty() {
        let ends_at_ms = result
            .pointer("/value/ends_at_ms")
            .or_else(|| result.get("ends_at_ms"))
            .and_then(Value::as_str)
            .and_then(|text| text.parse::<u64>().ok());
        let now_ms = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX));
        // Whole seconds, rounded up: a 30 s grace reads "30 s" right after the close.
        let seconds = ends_at_ms.map_or(0, |ends| ends.saturating_sub(now_ms).div_ceil(1000));
        lines.push(
            messages
                .close_ending_terminals
                .replace("{count}", &ending.len().to_string())
                .replace("{seconds}", &seconds.to_string())
                .replace("{ids}", &ending.join(", ")),
        );
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
