//! Every app a tool call names, resolved and checked before the call runs: the
//! Rust twin of the macOS helper's `CuaTargetGuard`
//! (`Packages/macOS/CmuxComputerUseHelper/Sources/CmuxCuaHelperCore/CuaTargetGuard.swift`).

use async_trait::async_trait;
use serde_json::Value;

use crate::approval::Target;
use crate::worker::driver::CallError;

/// How the guard learns which app a pid, window or name is (never the agent's words).
#[async_trait]
pub trait TargetResolver: Send + Sync {
    async fn app_for_pid(&self, pid: u32) -> Option<Target>;
    async fn app_for_window(&self, window_id: u32) -> Option<Target>;
    async fn app_named(&self, name: &str) -> Option<Target>;
    async fn app_for_bundle_id(&self, bundle_id: &str) -> Option<Target>;
}

/// The apps one call targets, distinct, in the order the call names them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Checked {
    pub targets: Vec<Target>,
}

/// Checks `tool`'s arguments (the worker's old rule: the top-level pid, else window).
pub async fn check(
    _tool: &str,
    arguments: &Value,
    resolver: &dyn TargetResolver,
    allow_terminals: &[String],
) -> Result<Checked, CallError> {
    let target = if let Some(pid) = arguments.get("pid").and_then(Value::as_u64) {
        resolver.app_for_pid(u32::try_from(pid).unwrap_or(0)).await
    } else if let Some(window) = arguments.get("window_id").and_then(Value::as_u64) {
        resolver.app_for_window(u32::try_from(window).unwrap_or(0)).await
    } else {
        return Ok(Checked::default());
    };
    let Some(target) = target else {
        return Err(CallError::new("target_unresolved", "cannot resolve the target"));
    };
    if let Some(reason) = crate::policy::refusal(&target, allow_terminals) {
        return Err(CallError::new("target_refused", reason));
    }
    Ok(Checked { targets: vec![target] })
}

#[cfg(test)]
mod tests;
