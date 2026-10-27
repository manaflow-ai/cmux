//! `cmux [--app-socket PATH] app call <method> [json]`: one app control
//! method, for a DEV or tagged build's debug socket only (debug.* reads such
//! as `debug.surfaces` or `debug.window_snapshot`).
//!
//! The CLI first asks the app `system.identify` on the same connection and
//! refuses (exit 1) any app whose bundle is not a debug build, before it
//! sends the method. The params are the JSON object as given, sent without
//! the read barrier (`debug.hangs` reads its own `after`), with the CLI's
//! `origin` (`cli` or `script`) put over any `origin` in the JSON: a call
//! never claims to be the person, so person-only operations stay refused.
//! The app's own error passes through with its code (exit 1).
//!
//! Every app request this CLI sends carries a top-level `flow` from
//! [`next_flow`] (p09-observability task 115): the app's trace starts that
//! flow when it parses the request and ends it at the action's commit, so a
//! CLI call shows apart from the person's input. An app older than the field
//! never reads it; it is outside `params`, which methods check strictly.

use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};

use serde_json::{Map, Value, json};

use super::{AppCommand, READ_TIMEOUT, UsageError, WAITING_RUN_TIMEOUT};
use crate::app_identity::is_debug_bundle;
use crate::cli::GlobalArgs;

/// `rest` starts with `call`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let (method, params) = match &rest[1..] {
        [method] => (method, Map::new()),
        [method, json] => {
            let Ok(Value::Object(params)) = serde_json::from_str::<Value>(json) else {
                return Err(UsageError::new(messages.app_call_bad_json));
            };
            (method, params)
        }
        _ => return Err(UsageError::new(messages.app_call_usage)),
    };
    if method.is_empty() || method.starts_with('-') {
        return Err(UsageError::new(messages.app_call_usage));
    }
    Ok(AppCommand::DebugCall { method: method.clone(), params })
}

/// Identify the app, refuse a non-debug build, then send the method.
pub(super) fn run(
    global: &GlobalArgs,
    stream: &mut UnixStream,
    method: &str,
    mut params: Map<String, Value>,
) -> i32 {
    let messages = &crate::localization::catalog().app_control;
    let output = global.output;
    let identity = match super::exchange(stream, "system.identify", json!({}), READ_TIMEOUT) {
        Ok(Ok(identity)) => identity,
        Ok(Err(error)) => return super::super::wire::print_local_error(&error, output, 1),
        Err(error) => return super::failure("app.transport", &error, output, 3),
    };
    let bundle = identity.get("bundle_id").and_then(Value::as_str).unwrap_or_default();
    if !is_debug_bundle(bundle) {
        let shown = if bundle.is_empty() { "?" } else { bundle };
        let message = messages.app_call_debug_only.replace("{bundle}", shown);
        return super::failure("app.call_debug_only", &message, output, 1);
    }
    params.insert("origin".into(), json!(super::action_origin()));
    match super::exchange(stream, method, Value::Object(params), WAITING_RUN_TIMEOUT) {
        Ok(Ok(result)) => super::super::wire::print_local_success(&result, output),
        Ok(Err(error)) => super::super::wire::print_local_error(&error, output, 1),
        Err(error) => super::failure("app.transport", &error, output, 3),
    }
}

/// The pid bits a flow keeps: 21, so that a flow (pid above bit 32, the
/// request's sequence below) stays under 2^53 and a JSON number, which the
/// app reads as a double, holds it exactly.
const FLOW_PID_MASK: u64 = (1 << 21) - 1;

/// The flow id of this process's next app request: the pid's low 21 bits
/// above bit 32 and a sequence from 1 below, as the app mints a key's flow
/// (its pid in the high bits), so each CLI call is its own flow. Never 0.
pub(super) fn next_flow() -> u64 {
    static NEXT: AtomicU32 = AtomicU32::new(1);
    flow_id(std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

fn flow_id(pid: u32, sequence: u32) -> u64 {
    ((u64::from(pid) & FLOW_PID_MASK) << 32) | u64::from(sequence.max(1))
}

/// Set once `cmux mcp serve` starts: every app request this process sends
/// then comes from an MCP client.
static MCP_SERVER: AtomicBool = AtomicBool::new(false);

/// This process is `cmux mcp serve` ([`request_source`] says `mcp`).
pub(in crate::cli) fn mark_mcp_server() {
    MCP_SERVER.store(true, Ordering::Relaxed);
}

/// The top-level `source` of this process's app requests, beside `flow`: the
/// app's trace and latency histograms keep CLI, MCP and agent requests apart
/// by it. It names the caller and grants nothing; an app older than the
/// field never reads it.
pub(super) fn request_source() -> &'static str {
    let agent = std::env::var_os("CMUX_AGENT_SESSION").is_some_and(|session| !session.is_empty());
    source_for(MCP_SERVER.load(Ordering::Relaxed), agent)
}

/// `agent` for an agent session's CLI or MCP server, else `mcp` for
/// `cmux mcp serve`, else `cli`.
fn source_for(mcp_server: bool, agent_session: bool) -> &'static str {
    match (agent_session, mcp_server) {
        (true, _) => "agent",
        (false, true) => "mcp",
        (false, false) => "cli",
    }
}

#[cfg(test)]
mod tests {
    use super::{FLOW_PID_MASK, flow_id, next_flow, source_for};

    #[test]
    fn cli_flow_source_names_the_agent_then_the_mcp_server_then_the_cli() {
        assert_eq!(source_for(false, false), "cli");
        assert_eq!(source_for(true, false), "mcp");
        assert_eq!(source_for(true, true), "agent");
        assert_eq!(source_for(false, true), "agent");
    }

    #[test]
    fn cli_flow_ids_fit_a_json_number_and_keep_the_pid() {
        let largest = flow_id(u32::MAX, u32::MAX);
        assert!(largest < 1 << 53, "{largest} must survive a double");
        assert_eq!(flow_id(4_242, 7) >> 32, 4_242);
        assert_eq!(flow_id(4_242, 7) & 0xFFFF_FFFF, 7);
        assert_ne!(flow_id(0, 0), 0, "a flow is never 0 (no flow)");
        let own = u64::from(std::process::id()) & FLOW_PID_MASK;
        let (first, second) = (next_flow(), next_flow());
        assert_ne!(first, second);
        assert_eq!(first >> 32, own);
    }
}
