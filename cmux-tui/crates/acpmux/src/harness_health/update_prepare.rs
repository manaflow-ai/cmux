//! Filesystem validation of the selected cached target before a visible
//! owner job. No CLI/version/auth probe, network, preference write or exec.

use std::path::Path;
use std::sync::PoisonError;

use serde_json::{Value, json};

use super::update_plan::{fixed_argv, refused, select_argv};
use super::{HarnessHealth, HealthService, channel};
use crate::rpc::RpcError;

pub(crate) const UPDATE_PREPARE_FEATURE: &str = "harnessUpdatePrepare";

fn executable(path: &Path) -> bool {
    let Ok(metadata) = path.metadata() else { return false };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn revalidated_argv(row: &HarnessHealth, cli: &str, home: &Path) -> Option<Vec<String>> {
    let mut argv = fixed_argv(row, cli)?;
    let path = Path::new(row.path.as_deref()?);
    if !path.is_absolute() || !executable(path) {
        return None;
    }
    let real = path.canonicalize().ok()?;
    let install = channel::detect(&row.program, Some(&real), home);
    if install.channel != row.channel || install.package != row.package {
        return None;
    }
    let fresh = channel::update_plan(&install, Some(path), Some(&real), home)?;
    if fresh.elevated {
        return None;
    }
    if row.channel == channel::Channel::Npm {
        if fresh.argv.get(1..) != argv.get(1..) {
            return None;
        }
        // Capture this owner's manager path once. Never leave PATH lookup
        // to a later frontend or the terminal's shell environment.
        let program = argv.first_mut()?;
        let manager = if program == "npm" {
            crate::config::which("npm")?
        } else if Path::new(program.as_str()).is_absolute() {
            program.clone()
        } else {
            return None;
        };
        if !Path::new(&manager).is_absolute() || !executable(Path::new(&manager)) {
            return None;
        }
        *program = manager;
    } else if row.channel == channel::Channel::Bun {
        let manager = argv.len().checked_sub(4)?;
        if fresh.argv.len() != argv.len()
            || fresh.argv.get(..manager) != argv.get(..manager)
            || fresh.argv.get(manager + 1..) != argv.get(manager + 1..)
        {
            return None;
        }
        argv = channel::bun::pin_manager(&argv, crate::config::which)?;
    } else if fresh.argv != argv {
        return None;
    }
    Some(argv)
}

impl HealthService {
    /// One cached snapshot plus current filesystem installation evidence.
    /// Execution authority and a durable intent still belong to the caller.
    pub(crate) fn prepare_update(&self, cli: &str) -> Result<Value, RpcError> {
        let home = self.settings.lock().unwrap_or_else(PoisonError::into_inner).home.clone();
        let rows = self.rows();
        let argv = select_argv(&rows, cli, |row| revalidated_argv(row, cli, &home))?;
        let settings = self.settings.lock().unwrap_or_else(PoisonError::into_inner);
        if settings.home != home
            || *self.rows.lock().unwrap_or_else(PoisonError::into_inner) != rows
        {
            return Err(refused("harness_update_plan.busy"));
        }
        Ok(json!({"cli":cli,"argv":argv}))
    }
}
