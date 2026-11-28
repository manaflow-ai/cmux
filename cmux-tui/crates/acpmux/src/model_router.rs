//! Harness magic `router` (RFD 0158 §6), first piece: a subagent starts on the model its kind
//! needs, picked once when it starts, never per turn (a switch mid-chat throws away its cache).
//!
//! Claude Code's `Agent` tool (`Task` in older builds) takes an optional `model`; without one the
//! subagent runs the lead's model. On one lane VM, from 2026-11-20 to 2026-11-27
//! (`scripts/measure/subagent-model-mix.py`), 120 of 148 subagent runs were on Opus; past the 82
//! forks (which always run the lead's model), 17 `Agent` calls left `model` out, 1 of them an
//! `Explore` search. A read-only search on the lead's top model buys nothing a cheaper one
//! cannot do, and a wrong pick costs one retry: the lead asks again with `model` set.
//!
//! The PreToolUse hook (`bg_hook.rs`) hands this module every `Agent`/`Task` call ([`route`]).
//! It fills in `model` only when the call leaves it out and the subagent's kind has a route; a
//! model the lead names is never changed, which is also how a lead escalates. A fork
//! (`subagent_type: "fork"`) always runs the lead's model and is never routed.
//!
//! Routes: `Explore` goes to `sonnet` by default. `agents.harnessMagic.router.subagents`, an
//! object of kind to model, adds or replaces routes, and an empty string or `null` removes one.
//! A route never goes to Fable or to `inherit` ([`allowed_model`]).
//!
//! Off unless `agents.harnessMagic.router.enabled` is `true`: the RFD keeps §6 off until the
//! scorecard reads its cost per task. `ACPMUX_HM_ROUTER` `0` turns it off and `1` on, over the
//! setting. Fails open: anything it cannot read leaves the call as it was.

use serde_json::{Value, json};

/// The feature's name (its setting and its `harnessMagic` stamp).
pub const FEATURE: &str = "router";
/// The setting that turns it on (off unless `true`).
pub const SETTING_ENABLED: &str = "agents.harnessMagic.router.enabled";
/// The setting that adds, replaces or removes routes.
pub const SETTING_SUBAGENTS: &str = "agents.harnessMagic.router.subagents";
/// The daemon's switch, over the setting.
pub const KILL_ENV: &str = "ACPMUX_HM_ROUTER";

/// The tools that start a subagent.
pub const SUBAGENT_TOOLS: &[&str] = &["Agent", "Task"];

/// The built-in routes: the read-only search subagent on the cheaper model.
const DEFAULT_ROUTES: &[(&str, &str)] = &[("Explore", "sonnet")];

/// Whether the feature is on for `doc` and the switch's value `env`.
pub(crate) fn enabled_with(doc: Option<&Value>, env: Option<&str>) -> bool {
    match env.map(|v| v.trim().to_ascii_lowercase()).as_deref() {
        Some("0" | "false" | "off" | "no") => return false,
        Some("1" | "true" | "on" | "yes") => return true,
        _ => {}
    }
    doc.and_then(|d| crate::user_settings::value(d, SETTING_ENABLED)).and_then(|v| v.as_bool())
        == Some(true)
}

fn settings_doc() -> Option<Value> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => Some(doc),
        _ => None,
    }
}

/// Whether the feature is on now.
pub(crate) fn enabled() -> bool {
    enabled_with(settings_doc().as_ref(), std::env::var(KILL_ENV).ok().as_deref())
}

/// Whether a route may send a subagent to `model`: a name, not `inherit`, and never Fable.
pub(crate) fn allowed_model(model: &str) -> bool {
    let m = model.trim().to_ascii_lowercase();
    !m.is_empty() && m != "inherit" && !m.contains("fable")
}

/// The routes for `doc`: the built-in ones, then the setting's on top of them.
pub(crate) fn routes_with(doc: Option<&Value>) -> Vec<(String, String)> {
    let mut routes: Vec<(String, String)> =
        DEFAULT_ROUTES.iter().map(|(k, m)| ((*k).to_owned(), (*m).to_owned())).collect();
    let set = doc.and_then(|d| crate::user_settings::value(d, SETTING_SUBAGENTS));
    for (kind, model) in set.as_ref().and_then(Value::as_object).into_iter().flatten() {
        routes.retain(|(k, _)| k != kind);
        if let Some(model) = model.as_str().filter(|m| allowed_model(m)) {
            routes.push((kind.clone(), model.trim().to_owned()));
        }
    }
    routes
}

/// Whether `input` is a lead's PreToolUse call that starts a subagent (the text test, before any
/// setting is read).
pub fn starts_subagent(input: &Value) -> bool {
    input.get("hook_event_name").and_then(Value::as_str) == Some("PreToolUse")
        && input
            .get("tool_name")
            .and_then(Value::as_str)
            .is_some_and(|t| SUBAGENT_TOOLS.contains(&t))
}

/// The hook's answer for a subagent start under `routes`: the call with `model` filled in, or
/// `None` to leave it as it was (a model already named, a fork, a kind with no route).
pub(crate) fn route_with(input: &Value, routes: &[(String, String)]) -> Option<Value> {
    if !starts_subagent(input) {
        return None;
    }
    let tool_input = input.get("tool_input").filter(|t| t.is_object())?;
    let named =
        tool_input.get("model").and_then(Value::as_str).is_some_and(|m| !m.trim().is_empty());
    if named {
        return None;
    }
    let kind = tool_input.get("subagent_type").and_then(Value::as_str)?.trim();
    if kind == "fork" {
        return None;
    }
    let (_, model) = routes.iter().find(|(k, _)| k == kind)?;
    if !allowed_model(model) {
        return None;
    }
    let mut updated = tool_input.clone();
    updated.as_object_mut()?.insert("model".into(), json!(model));
    Some(json!({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "updatedInput": updated,
    }}))
}

/// [`route_with`] under this machine's settings, when the feature is on.
pub fn route(input: &Value) -> Option<Value> {
    if !starts_subagent(input) {
        return None;
    }
    let doc = settings_doc();
    if !enabled_with(doc.as_ref(), std::env::var(KILL_ENV).ok().as_deref()) {
        return None;
    }
    route_with(input, &routes_with(doc.as_ref()))
}

#[cfg(test)]
#[path = "model_router_tests.rs"]
mod tests;
