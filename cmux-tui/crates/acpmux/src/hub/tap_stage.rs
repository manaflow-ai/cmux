//! Stateful tap preparation shared by v1 and the actor.
//!
//! The helpers in this module are deliberately independent of `Hub` and
//! `Session`; callers provide the read-only values and holder accessors.

use serde_json::Value;
use std::path::Path;

/// Enrich a Gemini plan update using the caller's resolved working directory
/// and configured home roots. The file helper remains the single policy owner.
pub(super) fn enrich_gemini_plan(update: &mut Value, cwd: &Path, homes: &[std::path::PathBuf]) {
    if update.get("update").is_some_and(super::gemini_plan::names_plan) {
        super::gemini_plan::with_plan_update(update, cwd, homes);
    }
}

pub(super) fn observe_todo(
    watch: &mut Option<super::acp_todo_plan::Watch>,
    update: &mut Value,
) -> Option<Value> {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return None;
    }
    if watch.is_none()
        && kind == Some("tool_call")
        && super::acp_todo_plan::entries(update).is_some()
    {
        *watch = Some(Default::default());
    }
    let plan = watch.as_mut()?.observe(update);
    if watch.as_ref().is_some_and(|w| w.is_empty()) {
        *watch = None;
    }
    plan
}

pub(super) fn filter_suggestion(
    gate: &std::sync::Mutex<super::suggestion_gate::Gate>,
    session: &str,
    harness: &str,
    update: &mut Value,
) {
    super::suggestion_gate::filter_update(gate, session, harness, update);
}
