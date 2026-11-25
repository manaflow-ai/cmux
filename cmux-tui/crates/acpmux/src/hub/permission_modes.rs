//! Part of `Hub`; see `hub/mod.rs`. What a harness's ACP `modes` are worth to a client as
//! permission modes (the Mac's and the phone's Mode picker, a new chat's start mode).
//!
//! ACP's Session Config Options supersede Session Modes; an agent that has config options may
//! still send `modes` for older clients, as a copy of one of its options. Claude Code's and
//! Codex's copy is their `mode` option: their permission modes. Pi's (pi-acp 0.0.33) is its
//! `thought_level` option: "Thinking: off" … "Thinking: xhigh", which the effort picker already
//! draws. Those are no Mode (Lawrence 2026-11-19: "pi should not have a "mode""), so no client is
//! given them: not a chat's `session/new`, `session/load` or fork answer, not `_acpmux/info`
//! (the phone's chat), not the harness list's `reported` (the phone's New Task), not the start
//! mode. The session keeps them as the harness sent them: the remote guard (`web_modes::mode_of`,
//! `remote_floor.rs`) reads the mode the harness runs in, and a chat with no modes would count as
//! one that asks. The webview applies the same rule (`webviews/.../permissionModes.ts`).

use crate::store::SessionMeta;
use serde_json::Value;

/// A session's `modes` as clients get them: [`permission_modes`] of its modes and config options.
pub(crate) fn of_session(meta: &SessionMeta) -> Option<Value> {
    permission_modes(meta.modes.as_ref(), meta.config_options.as_deref())
}

/// `modes` (an ACP `SessionModeState`), unless its modes only copy one of `config_options` that
/// is not a mode option (`id` or `category` `mode`): then None, the agent has no permission modes.
/// Modes with no config options beside them (OpenCode, Gemini) are its real ones.
pub(crate) fn permission_modes(
    modes: Option<&Value>,
    config_options: Option<&Value>,
) -> Option<Value> {
    let modes = modes.filter(|m| !m.is_null())?;
    let ids: Vec<&str> = modes
        .get("availableModes")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .collect();
    let copied = !ids.is_empty()
        && config_options.and_then(Value::as_array).into_iter().flatten().any(|option| {
            !is_mode_option(option) && same_values(&choice_values(option.get("options")), &ids)
        });
    (!copied).then(|| modes.clone())
}

fn is_mode_option(option: &Value) -> bool {
    option.get("category").and_then(Value::as_str) == Some("mode")
        || option.get("id").and_then(Value::as_str) == Some("mode")
}

/// An option's choice values, its groups' included (ACP `SessionConfigSelectGroup`).
fn choice_values(raw: Option<&Value>) -> Vec<&str> {
    raw.and_then(Value::as_array)
        .into_iter()
        .flatten()
        .flat_map(|choice| match choice.get("options") {
            Some(group) if group.is_array() => choice_values(Some(group)),
            _ => choice.get("value").and_then(Value::as_str).into_iter().collect(),
        })
        .collect()
}

/// The same non-empty set of values.
fn same_values(values: &[&str], ids: &[&str]) -> bool {
    use std::collections::BTreeSet;
    let values: BTreeSet<&str> = values.iter().copied().collect();
    !values.is_empty() && values == ids.iter().copied().collect()
}

#[cfg(test)]
#[path = "permission_modes_tests.rs"]
mod tests;
