//! The agent side of "My agents can turn screen sharing and control on my machines"
//! (docs/cmux-remote.md, Agents; the daemon's side is cmux-tui-core `remote_host/agent_share.rs`).
//!
//! `cmux remote-host share on|off [--device D]` and MCP `remote_share` ask this daemon for a
//! single-use ticket naming this agent session, then hand it to the cmux app
//! (`remote.confirm {..., agent_ticket}`). With the account's permission on, the app redeems it
//! and makes the change with no dialog; otherwise it asks the person exactly as with no ticket.
//! A daemon that gives no ticket (an older one, a page, the permission refused) changes nothing:
//! the request goes out as before, without one.

use serde_json::{Value, json};

/// The agent session this command runs in, as its environment names it (the daemon records it
/// with the connection's process id): `ACPMUX_SESSION_ID`, else `CMUX_AGENT_SESSION`, and
/// `ACPMUX_SESSION_NAME`. Null fields for a person's terminal.
pub(super) fn agent_context(env: impl Fn(&str) -> Option<String>) -> Value {
    let named = |name: &str| {
        env(name).map(|value| value.trim().to_owned()).filter(|value| !value.is_empty())
    };
    json!({
        "session": named("ACPMUX_SESSION_ID").or_else(|| named("CMUX_AGENT_SESSION")),
        "name": named("ACPMUX_SESSION_NAME"),
    })
}

/// [`agent_context`] of this process.
pub(super) fn this_agent() -> Value {
    agent_context(|name| std::env::var(name).ok())
}

/// The daemon request for a ticket: `action` share or unshare, `device` for another Mac.
pub(super) fn ticket_request(action: &str, device: Option<&str>, agent: &Value) -> Value {
    let mut params = json!({"action": action, "agent": agent});
    if let (Some(device), Some(fields)) = (device, params.as_object_mut()) {
        fields.insert("device".into(), json!(device));
    }
    json!({"id": 1, "cmd": "remote-host-call", "method": "agent.ticket", "params": params})
}

/// `params` for `remote.confirm` with the ticket `mint` gives, or unchanged when it gives none.
pub(super) fn with_ticket(mut params: Value, mint: impl FnOnce() -> Result<Value, Value>) -> Value {
    if let Ok(answer) = mint()
        && let Some(ticket) = answer.get("ticket").and_then(Value::as_str)
        && let Some(fields) = params.as_object_mut()
    {
        fields.insert("agent_ticket".into(), json!(ticket));
    }
    params
}

/// `share off`: with a ticket, the app turns sharing off (no dialog ever) so the change is the
/// agent's, audited and announced: `took` gets the app's answer. When there is no ticket, the app
/// is unreachable or it says the permission does not cover this agent, `off` turns it off as
/// before (`remote_host::LowerChange::ShareOff`: cmux Remote's worker, or the app's own action
/// in a build without it).
pub(super) fn share_off<T>(
    mint: impl FnOnce() -> Result<Value, Value>,
    app: impl FnOnce(Value) -> Result<Value, Value>,
    took: impl FnOnce(Value) -> T,
    off: impl FnOnce() -> T,
) -> T {
    let params = with_ticket(json!({"action": "unshare"}), mint);
    if params.get("agent_ticket").is_none() {
        return off();
    }
    match app(params) {
        Ok(answer) if answer.get("ok").and_then(Value::as_bool) == Some(true) => took(answer),
        _ => off(),
    }
}

#[cfg(test)]
#[path = "remote_host_agent_tests.rs"]
mod tests;
