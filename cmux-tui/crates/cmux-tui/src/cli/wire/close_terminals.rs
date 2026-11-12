//! The terminals a `tab`, `pane`, `screen` or `workspace` close (or a bulk
//! `layout.bulk` close) leaves with no tab (W7-C: one close model). The CLI
//! sends `terminals` (`grace`, `end` with `--now`, `keep` with
//! `--keep-terminals`, or `detach` from the worktree close). A daemon without
//! `close-grace-v1` refuses `grace` and `detach`, so the CLI sends it `end`
//! (its own default) and `keep` (which only detaches there); one older than
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

/// Fits `terminals` to what the daemon takes. On a daemon without
/// `close-grace-v1`: `grace` becomes `end` (its own default), `detach`
/// becomes that daemon's `keep` (which only detaches), and a bulk close's
/// `keep_terminals: true` becomes `end_terminals: false`. On one without
/// `close-ends-terminals-v1` the field goes too. True when the request
/// changed.
pub(in crate::cli) fn drop_unsupported(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
) -> bool {
    fit(request, |capability| {
        super::super::launch_credential::advertises(reader, socket, capability)
    })
}

/// ``drop_unsupported`` with `advertises` answering whether the daemon has
/// a capability (asked only when the request needs the answer).
fn fit(request: &mut Value, mut advertises: impl FnMut(&str) -> bool) -> bool {
    let operation = request.get("operation");
    let bulk_keep = operation
        .is_some_and(|operation| operation == ResourceOperation::LayoutBulk.wire_name())
        && request.pointer("/params/keep_terminals").and_then(Value::as_bool) == Some(true);
    if bulk_keep {
        if advertises(CLOSE_GRACE_CAPABILITY) {
            return false;
        }
        let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else {
            return false;
        };
        params.remove("keep_terminals");
        params.insert("end_terminals".into(), Value::Bool(false));
        return true;
    }
    let terminals = request.pointer("/params/terminals").and_then(Value::as_str);
    if !request.get("operation").is_some_and(is_close) || terminals.is_none() {
        return false;
    }
    // The values a daemon without `close-grace-v1` does not know, and what it
    // takes for each.
    let older = match terminals {
        Some("grace") => Some("end"),
        Some("detach") => Some("keep"),
        _ => None,
    };
    if older.is_some() && advertises(CLOSE_GRACE_CAPABILITY) {
        return false;
    }
    let keeps_field = advertises(CLOSE_ENDS_TERMINALS_CAPABILITY);
    if keeps_field && older.is_none() {
        return false;
    }
    let Some(params) = request.get_mut("params").and_then(Value::as_object_mut) else {
        return false;
    };
    match older {
        Some(older) if keeps_field => {
            params.insert("terminals".into(), Value::String(older.into()));
            true
        }
        _ => params.remove("terminals").is_some(),
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

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    /// A request of `operation` with `params`, fitted for a daemon that
    /// advertises `capabilities`; the params it then sends.
    fn fitted(operation: ResourceOperation, params: Value, capabilities: &[&str]) -> Value {
        let mut request = json!({"operation": operation.wire_name(), "params": params});
        fit(&mut request, |capability| capabilities.contains(&capability));
        request["params"].clone()
    }

    const GRACE: &[&str] = &[CLOSE_ENDS_TERMINALS_CAPABILITY, CLOSE_GRACE_CAPABILITY];
    const ENDS: &[&str] = &[CLOSE_ENDS_TERMINALS_CAPABILITY];
    const OLD: &[&str] = &[];

    /// A single close keeps `terminals` for a daemon with `close-grace-v1`;
    /// one with only `close-ends-terminals-v1` gets `end` for `grace` and
    /// `keep` for `detach` (its `keep` only detaches); an older one gets no
    /// field (it only detaches).
    #[test]
    fn w7c_a_single_close_fits_terminals_to_the_daemon() {
        let tab = ResourceOperation::TabClose;
        for value in ["grace", "end", "keep", "detach"] {
            assert_eq!(
                fitted(tab, json!({"terminals": value}), GRACE),
                json!({"terminals": value}),
                "{value} to a grace daemon"
            );
        }
        for (value, sent) in
            [("grace", "end"), ("end", "end"), ("keep", "keep"), ("detach", "keep")]
        {
            assert_eq!(
                fitted(tab, json!({"terminals": value}), ENDS),
                json!({"terminals": sent}),
                "{value} to a close-ends daemon"
            );
        }
        for value in ["grace", "end", "keep", "detach"] {
            assert_eq!(fitted(tab, json!({"terminals": value}), OLD), json!({}), "{value} to old");
        }
    }

    /// A bulk close keeps `terminals` for a daemon with `close-grace-v1`.
    /// An older one gets the legacy `end_terminals`: `true` where a single
    /// close ends them (`end`, and `grace` on a close-ends daemon), `false`
    /// for `keep` and `detach`; a daemon without `close-ends-terminals-v1`
    /// gets `true` only for `end`.
    #[test]
    fn w7c_a_bulk_close_fits_terminals_to_the_daemon() {
        let bulk = ResourceOperation::LayoutBulk;
        for value in ["grace", "end", "keep", "detach"] {
            assert_eq!(
                fitted(bulk, json!({"terminals": value}), GRACE),
                json!({"terminals": value}),
                "{value} to a grace daemon"
            );
        }
        for (value, end) in [("grace", true), ("end", true), ("keep", false), ("detach", false)] {
            assert_eq!(
                fitted(bulk, json!({"terminals": value}), ENDS),
                json!({"end_terminals": end}),
                "{value} to a close-ends daemon"
            );
        }
        for (value, sent) in [
            ("grace", json!({})),
            ("end", json!({"end_terminals": true})),
            ("keep", json!({})),
            ("detach", json!({})),
        ] {
            assert_eq!(fitted(bulk, json!({"terminals": value}), OLD), sent, "{value} to old");
        }
    }
}
