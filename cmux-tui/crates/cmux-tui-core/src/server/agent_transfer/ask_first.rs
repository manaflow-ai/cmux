//! "Ask first, then bring back" (cx-rppd.10): `agent-transfer-begin
//! {surface, ask_first: true}` narrows the tab's chat in this daemon's own
//! acpmux before the move begins, so a Mac that takes chats back only under
//! the Web's control (its guard refuses `transfer.policy` and `transfer.mode`)
//! takes it. The guard on the receiving side is never changed: this only
//! makes the chat ask before it acts, here, then moves it as any other.
//!
//! Each step only narrows, and runs only when needed, over acpmux's own
//! unix-socket methods:
//! - a permission policy that does not ask (anything but `ask` and
//!   `deny-all`; the chat's own, else acpmux's default) becomes `ask`
//!   (`_acpmux/set_policy`), so a `deny-all` default is never touched;
//! - permission rules lose what could approve on its own (`autoApprove`, a
//!   `default` other than `ask` or `deny`, any field acpmux's check does not
//!   know), keeping `autoDeny` and `ask` (`_acpmux/set_rules`);
//! - a mode this acpmux's asking table (`_acpmux/web_modes`) does not list
//!   for the chat's family becomes the first mode of the table's list the
//!   chat offers (`session/set_mode`), and so does a `mode` config option
//!   (`session/set_config_option`). A chat offering no listed mode keeps its
//!   mode, and the receiving guard refuses it as before.
//!
//! A chat already in a move is left alone: its begin answers acpmux's
//! `transfer.moving` with that move's id, as without `ask_first`.
//!
//! The asking table is this machine's; the Mac's guard checks its own, built
//! from the same reviewed defaults. A step acpmux refuses stops the begin:
//! the chat stays here, unmoved, with only the narrowing done so far.

use crate::panic_free::JsonFields;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{CALL_TIMEOUT, Failure};

/// The permission policies that ask before anything runs (acpmux
/// `person::asking_policy_value`).
const ASKING_POLICIES: &[&str] = &["ask", "deny-all"];
/// A mode change may start the chat's agent first.
const SET_MODE_TIMEOUT: Duration = Duration::from_secs(30);

/// Narrows acpmux chat `session` to an asking policy, rules and mode.
pub(super) fn narrow(
    call: &impl Fn(&str, Value, Duration) -> Result<Value, Failure>,
    session: &str,
) -> Result<(), Failure> {
    let info = call("_acpmux/info", json!({"sessionId": session}), CALL_TIMEOUT)?;
    if *info.field("moving") == json!(true) {
        return Ok(());
    }
    // The chat's own policy, else the daemon default it runs under.
    let policy = info
        .field("policy")
        .as_str()
        .or_else(|| info.field("enforcement").field("policy").as_str());
    if policy.is_some_and(|policy| !ASKING_POLICIES.contains(&policy)) {
        call("_acpmux/set_policy", json!({"sessionId": session, "policy": "ask"}), CALL_TIMEOUT)?;
    }
    if let Some(rules) = narrowed_rules(info.field("rulesJson")) {
        call("_acpmux/set_rules", json!({"sessionId": session, "rules": rules}), CALL_TIMEOUT)?;
    }
    let table = call("_acpmux/web_modes", json!({"sessionId": session}), CALL_TIMEOUT)?;
    let family = table.field("session").field("family").as_str().unwrap_or_default();
    let asking: Vec<&str> = table
        .field("families")
        .field(family)
        .as_array()
        .map(|modes| modes.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if asking.is_empty() {
        return Ok(());
    }
    let listed = |mode: &str| asking.contains(&mode);
    let mut info = info;
    if !table.field("session").field("mode").as_str().is_some_and(listed) {
        let offered =
            info.field("modes").field("availableModes").as_array().cloned().unwrap_or_default();
        let offers = |id: &str| offered.iter().any(|mode| *mode.field("id") == json!(id));
        let mode = asking.iter().copied().find(|id| offers(id));
        if let Some(mode) = mode {
            let params = json!({"sessionId": session, "modeId": mode});
            call("session/set_mode", params, SET_MODE_TIMEOUT)?;
            info = call("_acpmux/info", json!({"sessionId": session}), CALL_TIMEOUT)?;
        }
    }
    let options = info.field("configOptions").as_array().cloned().unwrap_or_default();
    let mode_option = options.iter().find(|option| *option.field("id") == json!("mode"));
    if let Some(option) = mode_option
        && !option.field("currentValue").as_str().is_some_and(listed)
    {
        let values = option.field("options").as_array().cloned().unwrap_or_default();
        let offers = |id: &str| values.iter().any(|value| *value.field("value") == json!(id));
        let value = asking.iter().copied().find(|id| offers(id));
        if let Some(value) = value {
            let params = json!({"sessionId": session, "configId": "mode", "value": value});
            call("session/set_config_option", params, SET_MODE_TIMEOUT)?;
        }
    }
    Ok(())
}

/// The chat's permission rules without anything that could approve on its
/// own (`None`: there are none, or nothing to take out).
fn narrowed_rules(rules: &Value) -> Option<Value> {
    let object = rules.as_object()?;
    let mut narrowed = Map::new();
    for key in ["autoDeny", "ask"] {
        if let Some(list) = object.get(key).filter(|list| list.is_array()) {
            narrowed.insert(key.to_owned(), list.clone());
        }
    }
    if let Some(default @ ("ask" | "deny")) = object.get("default").and_then(Value::as_str) {
        narrowed.insert("default".to_owned(), json!(default));
    }
    let narrowed = Value::Object(narrowed);
    (narrowed != *rules).then_some(narrowed)
}
