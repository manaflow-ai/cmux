//! This host's version inventory (hq RFD "One update system for every place cmux runs"): what
//! the last `acpmux host self-update` run did, in `~/.acpmux/update-inventory.json`. The daemon's
//! status carries it as `updateInventory` beside `build` and `abiRange`, so NOW reads every lane
//! VM's sha, channel, previous build and last update result and time through the census
//! (`acpmux_lag`) with no new probe.
//!
//! One record per run, replaced each run; the last failure (a rollback, a failed install) is kept
//! as `lastFailure` across the runs after it, so a host that rolled back and then sat `current`
//! on its old build still says so.

use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub const SCHEMA: &str = "acpmux-update-inventory/v1";
pub const FILE: &str = "update-inventory.json";

/// The file under the acpmux home.
pub fn path_in(home: &Path) -> PathBuf {
    home.join(FILE)
}

/// The inventory under the default home, or null when no update has run here (or the file is
/// not an inventory).
pub fn read() -> Value {
    read_in(&crate::config::default_home())
}

pub fn read_in(home: &Path) -> Value {
    std::fs::read(path_in(home))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .filter(|v| v.get("schema").and_then(Value::as_str) == Some(SCHEMA))
        .unwrap_or(Value::Null)
}

/// Whether a run's outcome is a failure the inventory keeps as `lastFailure`.
fn failed(run: &Value) -> bool {
    matches!(run.get("outcome").and_then(Value::as_str), Some("rolledBack" | "failed"))
}

/// The record for `run` (the run's fields: channel, commit, sha256, source, outcome, reason,
/// error, build, prevBuild, revokedInstalled), stamped `at` (unix seconds), after `previous`.
pub fn next(previous: &Value, mut run: Value, at: u64) -> Value {
    if let Some(obj) = run.as_object_mut() {
        obj.retain(|_, v| !v.is_null());
        obj.insert("at".into(), json!(at));
    }
    let last_failure = if failed(&run) {
        Some(run.clone())
    } else {
        previous.get("lastFailure").filter(|v| !v.is_null()).cloned()
    };
    let mut out = json!({"schema": SCHEMA});
    if let (Some(out), Some(run)) = (out.as_object_mut(), run.as_object()) {
        out.extend(run.clone());
        if let Some(f) = last_failure {
            out.insert("lastFailure".into(), f);
        }
    }
    out
}

/// Record `run` in `home`'s inventory. A file that cannot be written is said on stderr and
/// never fails the update.
pub fn record_in(home: &Path, run: Value) {
    let at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let entry = next(&read_in(home), run, at);
    let path = path_in(home);
    let body = serde_json::to_vec_pretty(&entry).unwrap_or_default();
    if let Err(e) = crate::home_fs::write_durable(&path, &body) {
        eprintln!("acpmux: recording the update inventory ({}): {e}", path.display());
    }
}

#[cfg(test)]
#[path = "update_inventory_tests.rs"]
mod update_inventory_tests;
