//! Adopting the nightly's Chief home (CmuxNextHomeEngine `ChiefAdoption.swift`,
//! `ChiefAdoption+SQLite.swift`): whether it applies, where the backup goes and the record it writes.
//! The lock, the tree clone and the SQLite backups stay in Swift.

use super::{home, path, time};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// `ChiefAdoption.recordName`.
pub const RECORD_NAME: &str = "adopted.json";

/// `ChiefAdoption.applies`: only the shared nightly home is adopted.
pub fn applies(isolated: bool, build_id: Option<&str>) -> bool {
    !isolated && build_id == Some(home::NIGHTLY_BUNDLE_ID)
}

/// What `ChiefAdoption.run` read before it decides.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanInputs {
    pub root: String,
    #[serde(default)]
    pub isolated: bool,
    #[serde(default, rename = "buildID")]
    pub build_id: Option<String>,
    /// `adopted.json` is already there.
    #[serde(default)]
    pub record_exists: bool,
    /// The home's top-level names.
    #[serde(default)]
    pub names: Vec<String>,
    /// Seconds since 1970.
    #[serde(default)]
    pub now: f64,
}

/// `ChiefAdoption.run`'s paths and steps.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    /// `nothingToDo` or `adopt` (take the lock, re-check the record, back up when `backupNeeded`).
    pub step: &'static str,
    pub record_path: String,
    pub lock_path: String,
    /// Anything besides `state` is in the home.
    pub backup_needed: bool,
    pub backups: String,
    /// The finished backup's folder; already there means `busy`.
    pub target: String,
}

/// `ChiefAdoption.run`'s decisions.
pub fn plan(inputs: &PlanInputs) -> Plan {
    let root = path::standardized(&inputs.root);
    let step = if applies(inputs.isolated, inputs.build_id.as_deref()) && !inputs.record_exists {
        "adopt"
    } else {
        "nothingToDo"
    };
    let backups = path::join(&path::parent(&root), ".backups");
    let target = path::join(
        &backups,
        &format!("{}-{}", path::last_component(&root), time::basic_stamp(inputs.now)),
    );
    Plan {
        step,
        record_path: path::join(&root, RECORD_NAME),
        lock_path: path::join(&root, "state/host.lock"),
        backup_needed: inputs.names.iter().any(|name| name != "state"),
        backups,
        target,
    }
}

/// `adopted.json`'s text: `{at, backup, by, raw}`, as `JSONSerialization` pretty-prints it sorted.
pub fn record(by: &str, now: f64, backup: Option<&str>, raw: &[String]) -> String {
    let value: Value = json!({
        "by": by,
        "at": time::internet(now),
        "backup": backup,
        "raw": raw,
    });
    time::pretty_sorted(&value)
}

/// `isSidecar(_:of:)`: a database's `-wal`, `-shm` or `-journal`, cloned with its database.
pub fn is_sidecar(name: &str, databases: &[String]) -> bool {
    ["-wal", "-shm", "-journal"].iter().any(|suffix| {
        name.strip_suffix(suffix)
            .is_some_and(|base| databases.iter().any(|database| database == base))
    })
}

/// The files cloned raw when a database's backup fails: it and its sidecars that are there.
pub fn raw_files(name: &str, names: &[String]) -> Vec<String> {
    std::iter::once(name.to_owned())
        .chain(["-wal", "-shm", "-journal"].iter().map(|suffix| format!("{name}{suffix}")))
        .filter(|file| names.contains(file))
        .collect()
}
