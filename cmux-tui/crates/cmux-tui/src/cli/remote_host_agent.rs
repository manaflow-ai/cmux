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
mod tests {
    use serde_json::{Value, json};

    use super::{agent_context, share_off, ticket_request, with_ticket};

    #[test]
    fn names_the_agent_session_from_the_environment() {
        let env = |pairs: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).to_owned())
            }
        };
        assert_eq!(
            agent_context(env(&[
                ("ACPMUX_SESSION_ID", "aid-1"),
                ("ACPMUX_SESSION_NAME", "lane"),
                ("CMUX_AGENT_SESSION", "x")
            ])),
            json!({"session": "aid-1", "name": "lane"})
        );
        assert_eq!(
            agent_context(env(&[("CMUX_AGENT_SESSION", "s-2")])),
            json!({"session": "s-2", "name": null})
        );
        assert_eq!(
            agent_context(env(&[("ACPMUX_SESSION_ID", "  ")])),
            json!({"session": null, "name": null})
        );
    }

    #[test]
    fn the_ticket_request_carries_the_action_the_device_and_the_agent() {
        let agent = json!({"session": "aid-1", "name": null});
        let request = ticket_request("share", Some("Studio"), &agent);
        assert_eq!(request["cmd"], "remote-host-call");
        assert_eq!(request["method"], "agent.ticket");
        assert_eq!(
            request["params"],
            json!({"action": "share", "device": "Studio", "agent": agent})
        );
        assert!(ticket_request("unshare", None, &agent)["params"].get("device").is_none());
    }

    #[test]
    fn without_a_ticket_the_app_gets_exactly_todays_request() {
        let today = json!({"action": "share", "on": true});
        // The daemon refuses (an older daemon, the permission refused, a page): unchanged.
        let refused = with_ticket(today.clone(), || Err(json!({"code": "bad_request"})));
        assert_eq!(refused, today);
        let empty = with_ticket(today.clone(), || Ok(json!({})));
        assert_eq!(empty, today);
        let ticketed = with_ticket(today, || Ok(json!({"ticket": "t1"})));
        assert_eq!(ticketed, json!({"action": "share", "on": true, "agent_ticket": "t1"}));
    }

    #[test]
    fn share_off_goes_through_the_app_only_when_it_takes_the_agents_ticket() {
        // `took` is the app's change; `off` is today's path (cmux Remote's worker, or the app's
        // own action in a build without it).
        let took = |answer: Value| ("app", answer);
        let off = || ("today", Value::Null);
        // No ticket: today's path; the app is never asked.
        let (path, _) = share_off(
            || Err(json!({"code": "bad_request"})),
            |_| -> Result<Value, Value> { panic!("the app is not asked without a ticket") },
            took,
            off,
        );
        assert_eq!(path, "today");
        // A ticket the app takes: the app turns it off, today's path is not taken.
        let (path, answer) = share_off(
            || Ok(json!({"ticket": "t1"})),
            |params| {
                assert_eq!(params, json!({"action": "unshare", "agent_ticket": "t1"}));
                Ok(json!({"ok": true, "agent": true}))
            },
            took,
            off,
        );
        assert_eq!((path, answer["agent"].clone()), ("app", json!(true)));
        // The permission is off (the app says so) or the app is unreachable: today's path.
        for answer in
            [Ok(json!({"ok": false, "asks_person": true})), Err(json!({"code": "app.unreachable"}))]
        {
            let (path, _) = share_off(|| Ok(json!({"ticket": "t1"})), |_| answer, took, off);
            assert_eq!(path, "today");
        }
    }
}
