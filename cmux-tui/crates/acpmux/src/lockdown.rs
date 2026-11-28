//! Lockdown mode on this Mac (RFD 0211, "The app on the Mac" 3 and 4): `sessions.lockdown`
//! with its allowlists `sessions.lockdownHarnesses` and `sessions.lockdownModels`.
//!
//! The app reads the setting through its layers (the person's file, the team policy, an MDM
//! profile in the managed domain, which locks the key in Settings) and pushes the effective value
//! with each `_acpmux/chat_settings` (`lockdown`: `null` when off, else `{harnesses, models}`).
//! The app turns Cloud and computer use off itself (the `cloud` and `computerUse` features, as
//! `DisabledFeatures` does). acpmux holds the allowlists: under lockdown every agent start
//! (`Hub::spawn_profile_read`, which every launch and the session pool go through) and every model
//! switch (`Hub::set_model`) checks its harness and model against them.
//!
//! An empty list allows every harness (or model): lockdown with no list only turns Cloud and
//! computer use off. A model entry allows that id and every id it starts (`claude-opus` allows
//! `claude-opus-5-5`). A start with no model named runs the harness's default, which the list
//! does not see. Kept in memory and in `start-mode.json` (`hub/start_mode_state.rs`), so it holds
//! across a daemon restart before the app pushes again. Best effort like the other pushed
//! settings: any process of the same user can push or edit these files.

use std::sync::RwLock;

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The allowlists in force while lockdown is on.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Lockdown {
    pub harnesses: Vec<String>,
    pub models: Vec<String>,
}

static CURRENT: RwLock<Option<Lockdown>> = RwLock::new(None);

/// Records the lockdown the app pushed (`None`: off).
pub(crate) fn set(lockdown: Option<Lockdown>) {
    *CURRENT.write().unwrap_or_else(|e| e.into_inner()) = lockdown;
}

/// The lockdown in force, `None` when off.
pub(crate) fn current() -> Option<Lockdown> {
    CURRENT.read().unwrap_or_else(|e| e.into_inner()).clone()
}

/// The `lockdown` of a `_acpmux/chat_settings` push. No key or `null` is off (an older app sends
/// none). Each list is an array of strings or one string the Settings field holds, split on commas
/// and whitespace. A value that is not an object, or a list of anything else, is an error: the
/// person or an administrator meant to restrict, so it must not read as off.
pub(crate) fn from_params(params: &Value) -> Result<Option<Lockdown>, String> {
    let value = match params.get("lockdown") {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Object(map)) => map,
        Some(_) => return Err("lockdown must be an object or null".into()),
    };
    let list = |key: &str| -> Result<Vec<String>, String> {
        match value.get(key) {
            None | Some(Value::Null) => Ok(Vec::new()),
            Some(Value::String(text)) => Ok(text
                .split(|c: char| c == ',' || c.is_whitespace())
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect()),
            Some(Value::Array(items)) => items
                .iter()
                .map(|i| {
                    i.as_str()
                        .map(|s| s.trim().to_owned())
                        .ok_or_else(|| format!("lockdown.{key} must list strings"))
                })
                .filter(|r| !matches!(r, Ok(s) if s.is_empty()))
                .collect(),
            Some(_) => Err(format!("lockdown.{key} must be an array or a string")),
        }
    };
    Ok(Some(Lockdown { harnesses: list("harnesses")?, models: list("models")? }))
}

impl Lockdown {
    /// Why `harness` may not start under this lockdown, or `None` when it may.
    pub fn refuses_harness(&self, harness: &str) -> Option<String> {
        if self.harnesses.is_empty() || self.harnesses.iter().any(|h| h == harness) {
            return None;
        }
        Some(format!(
            "lockdown mode allows only these agents on this Mac: {} (sessions.lockdownHarnesses); {harness} is not one",
            self.harnesses.join(", ")
        ))
    }

    /// Why `model` may not run under this lockdown, or `None` when it may.
    pub fn refuses_model(&self, model: &str) -> Option<String> {
        if self.models.is_empty() || self.models.iter().any(|m| model.starts_with(m.as_str())) {
            return None;
        }
        Some(format!(
            "lockdown mode allows only these models on this Mac: {} (sessions.lockdownModels); {model} is not one",
            self.models.join(", ")
        ))
    }
}

/// The refusal of a start of `harness` on `model` under the lockdown in force.
pub(crate) fn check_start(harness: &str, model: Option<&str>) -> Result<(), crate::rpc::RpcError> {
    refusal(start_refusal(current().as_ref(), harness, model))
}

/// The refusal of a switch to `model` under the lockdown in force.
pub(crate) fn check_model(model: &str) -> Result<(), crate::rpc::RpcError> {
    refusal(current().and_then(|l| l.refuses_model(model)))
}

fn start_refusal(
    lockdown: Option<&Lockdown>,
    harness: &str,
    model: Option<&str>,
) -> Option<String> {
    let lockdown = lockdown?;
    lockdown
        .refuses_harness(harness)
        .or_else(|| model.filter(|m| !m.is_empty()).and_then(|m| lockdown.refuses_model(m)))
}

fn refusal(why: Option<String>) -> Result<(), crate::rpc::RpcError> {
    why.map_or(Ok(()), |why| Err(crate::rpc::RpcError::invalid_params(why)))
}

#[cfg(test)]
#[path = "lockdown_tests.rs"]
mod tests;
