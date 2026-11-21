//! Death routing (H5): when a supervised thing dies, one event says what it owned (open
//! deliveries, sessions, circuits, its state paths), so its clients take over or wait on the
//! successor with a bound. Nobody infers death from silence.

use std::io::Write as _;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::budget::StopCause;
use crate::record::OwnerRecord;

/// One death.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Death {
    pub name: String,
    /// The owner record of the process that died.
    pub owner: OwnerRecord,
    pub cause: StopCause,
    /// What it owned, as its spec and its last report name them.
    pub owned: Vec<String>,
    pub at_ms: u64,
}

/// Append `death` as one JSON line to `path` (the death log beside the owner record).
pub fn append(path: &Path, death: &Death) -> std::io::Result<()> {
    let mut line = serde_json::to_vec(death).map_err(std::io::Error::other)?;
    line.push(b'\n');
    let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
    file.write_all(&line)
}

/// Every death logged at `path`, oldest first (lines that do not parse are skipped).
pub fn read_all(path: &Path) -> Vec<Death> {
    std::fs::read_to_string(path)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}
