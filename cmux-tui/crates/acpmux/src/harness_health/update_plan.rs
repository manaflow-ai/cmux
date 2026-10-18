//! Cached advisory for a visible owner job. This selects no caller command
//! and authorizes no execution. The execution owner must separately admit
//! the caller and revalidate the installation before starting a terminal.

use std::path::{Component, Path};
use std::sync::PoisonError;

use serde_json::{Value, json};

use super::{HarnessHealth, HealthService, auto, channel::Channel, inventory, probe};
use crate::rpc::RpcError;

pub(crate) const UPDATE_PLAN_FEATURE: &str = "harnessUpdatePlan";

fn refused(reason: &str) -> RpcError {
    RpcError::new(-32000, reason).with_data(json!({"reason":reason}))
}

/// Bound the private advisory too: cached command/display/auth text never
/// crosses this boundary, and malformed argv must not reach an exec call.
fn fixed_argv(row: &HarnessHealth, cli: &str) -> Option<Vec<String>> {
    let installed = inventory::safe_version(row.version.as_deref())?;
    let latest = inventory::safe_version(row.latest.as_deref())?;
    if probe::compare_versions(latest, installed) != Some(std::cmp::Ordering::Greater) {
        return None;
    }
    let argv = auto::updatable(row)?;
    if argv.iter().any(|arg| arg.contains('\0'))
        || argv.iter().map(String::len).sum::<usize>() > 16 * 1024
    {
        return None;
    }
    match row.channel {
        // updatable checks the exact package, absolute prefix and fixed
        // install flags, preserving a recorded fork and all argument bytes.
        Channel::Npm => Some(argv),
        Channel::Native => {
            let [program, verb] = argv.as_slice() else { return None };
            let path = Path::new(program);
            let expected = match cli {
                "claude" => "update",
                "opencode" => "upgrade",
                _ => return None,
            };
            (path.is_absolute()
                && !path.components().any(|part| matches!(part, Component::ParentDir))
                && row.path.as_deref() == Some(program.as_str())
                && verb == expected)
                .then_some(argv)
        }
        // Old bun/brew argv select whichever global target the current
        // environment chooses. They need explicit installation binding.
        _ => None,
    }
}

impl HealthService {
    /// Reads one snapshot under the cache lock. No filesystem read, first
    /// check, profile lookup, registry fetch, preference write or auto-update.
    pub(crate) fn cached_update_plan(&self, cli: &str) -> Result<Value, RpcError> {
        if !inventory::safe_id(cli) {
            return Err(RpcError::invalid_params("harness_update_plan.bad_request"));
        }
        let rows = self.rows.lock().unwrap_or_else(PoisonError::into_inner);
        // Unlike inventory's bounded display projection, selection cannot
        // silently ignore an installation beyond the visible prefix.
        if rows.len() > inventory::MAX_HARNESSES {
            return Err(refused("harness_update_plan.not_updatable"));
        }
        let mut selected = None;
        for row in rows.iter().filter(|row| inventory::cli_family(row) == Some(cli)) {
            let argv =
                fixed_argv(row, cli).ok_or_else(|| refused("harness_update_plan.not_updatable"))?;
            match &selected {
                Some(previous) if previous != &argv => {
                    return Err(refused("harness_update_plan.ambiguous"));
                }
                Some(_) => {}
                None => selected = Some(argv),
            }
        }
        let argv = selected.ok_or_else(|| refused("harness_update_plan.unavailable"))?;
        Ok(json!({"cached":true,"cli":cli,"argv":argv}))
    }
}
