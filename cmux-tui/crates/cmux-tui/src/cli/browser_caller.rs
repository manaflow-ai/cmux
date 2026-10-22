//! The CLI and `cmux mcp` name the caller of a browser open
//! (`browser-open-caller-v1`): `tab.create_browser`, `browser.profile.open`
//! and `workspace.open_url` sent from inside cmux carry `caller {workspace?,
//! agent_session?}` from the caller's environment (`CMUX_WORKSPACE_ID`,
//! `CMUX_AGENT_SESSION`). The daemon then opens the page in the rightmost
//! pane of the caller's own workspace instead of wherever the person looks,
//! and never in a new workspace (cmux-tui-core `mux/browser_caller.rs`).
//!
//! The caller goes only with a request for the caller's own session on this
//! machine (no `--socket`, `--session` or `--machine`, as the app's `caller`
//! in frontend_browser.rs), only when the request names no workspace, screen
//! or pane (a named place wins, so it needs no caller), and only to a daemon
//! that advertises the capability: an older daemon refuses the unknown
//! field, so it gets the request as before.

use std::io::BufReader;
use std::path::Path;

use cmux_tui_core::platform::transport;
use serde_json::{Map, Value, json};

/// The daemon capability that takes `caller` (cmux-tui-core
/// `mux::BROWSER_OPEN_CALLER_CAPABILITY`).
const CAPABILITY: &str = "browser-open-caller-v1";

/// The operations that take `caller`.
const OPERATIONS: [&str; 3] = ["tab.create_browser", "browser.profile.open", "workspace.open_url"];

/// Adds `caller` to `request` by the rules above; true when it did (the
/// caller re-encodes the request then). `own_session` says no `--socket`
/// or `--session` points the call elsewhere.
pub(super) fn attach(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    socket: &Path,
    request: &mut Value,
    own_session: bool,
) -> bool {
    let Some(caller) = caller_for(request, own_session, |key| std::env::var(key).ok()) else {
        return false;
    };
    if !super::launch_credential::advertises(reader, socket, CAPABILITY) {
        return false;
    }
    request["params"]["caller"] = caller;
    true
}

/// The `caller` `request` may carry, by the rules above, from `env`.
pub(super) fn caller_for(
    request: &Value,
    own_session: bool,
    env: impl Fn(&str) -> Option<String>,
) -> Option<Value> {
    let operation = request.get("operation").and_then(Value::as_str)?;
    let params = request.get("params").and_then(Value::as_object)?;
    let current =
        |key: &str| params.get(key).and_then(Value::as_str).is_none_or(|v| v == "current");
    let this_machine = current("machine") && current("session");
    let named =
        ["workspace", "screen", "pane", "caller"].iter().any(|key| params.contains_key(*key));
    if !OPERATIONS.contains(&operation) || !own_session || !this_machine || named {
        return None;
    }
    caller_from(env)
}

/// `{workspace?, agent_session?}` from the caller's environment, or `None`
/// outside cmux.
pub(super) fn caller_from(env: impl Fn(&str) -> Option<String>) -> Option<Value> {
    let set = |key: &str| env(key).filter(|value| !value.trim().is_empty());
    let mut caller = Map::new();
    if let Some(workspace) = set("CMUX_WORKSPACE_ID") {
        caller.insert("workspace".into(), json!(workspace));
    }
    if let Some(session) = set("CMUX_AGENT_SESSION") {
        caller.insert("agent_session".into(), json!(session));
    }
    (!caller.is_empty()).then_some(Value::Object(caller))
}

#[cfg(test)]
mod tests {
    use super::*;

    const WORKSPACE: &str = "42D98730-29AD-4AC5-974A-0B4F89ADBD07";

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| pairs.iter().find(|(name, _)| *name == key).map(|(_, value)| value.to_string())
    }

    fn request(operation: &str, params: Value) -> Value {
        json!({"operation": operation, "params": params})
    }

    #[test]
    fn an_agent_names_its_workspace_and_session() {
        let agent = env(&[("CMUX_WORKSPACE_ID", WORKSPACE), ("CMUX_AGENT_SESSION", "acp_a")]);
        for operation in OPERATIONS {
            let open = request(operation, json!({"machine": "current", "session": "current"}));
            assert_eq!(
                caller_for(&open, true, &agent),
                Some(json!({"workspace": WORKSPACE, "agent_session": "acp_a"})),
                "{operation}"
            );
        }
        let terminal = env(&[("CMUX_WORKSPACE_ID", WORKSPACE)]);
        let open = request("tab.create_browser", json!({"url": "https://example.com"}));
        assert_eq!(caller_for(&open, true, terminal), Some(json!({"workspace": WORKSPACE})));
    }

    #[test]
    fn no_caller_outside_cmux_elsewhere_or_with_a_named_place() {
        let agent = env(&[("CMUX_WORKSPACE_ID", WORKSPACE), ("CMUX_AGENT_SESSION", "acp_a")]);
        let open = |params| request("tab.create_browser", params);
        // Outside cmux: nothing names a caller.
        assert_eq!(caller_for(&open(json!({})), true, env(&[("CMUX_WORKSPACE_ID", " ")])), None);
        // Another session or machine is never the caller's.
        assert_eq!(caller_for(&open(json!({})), false, &agent), None);
        assert_eq!(caller_for(&open(json!({"machine": "m2"})), true, &agent), None);
        assert_eq!(caller_for(&open(json!({"session": "other"})), true, &agent), None);
        // A named place wins; an explicit caller stays.
        for key in ["workspace", "screen", "pane", "caller"] {
            assert_eq!(caller_for(&open(json!({key: "x"})), true, &agent), None, "{key}");
        }
        // Other operations take no caller.
        assert_eq!(caller_for(&request("tab.create_terminal", json!({})), true, &agent), None);
    }
}
