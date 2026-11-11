//! The `server-stats` `registry_cleanup` section: what the registry's
//! rebuild (`workspace_registry::output_cleanup`) and journal retention
//! left behind that a person has to know about.
//!
//! - The file that the last rebuild replaced. It is the whole registry from
//!   before the rebuild and stays beside the new one for at least 7 days
//!   and 3 full starts: until then the registry's directory is larger than
//!   the registry by the size of that file, and no rebuild runs.
//! - Saved reducer states that a start could not load. After retention
//!   deleted records, such a state is the only copy of what it folded, so
//!   it is kept as it was, and the start folds again from the records that
//!   are left: the agent list or History can be shorter than before.
//!
//! Cost per request: two `stat` calls, and on its own read-only connection
//! (no registry lock) at most four `meta` rows by key and one key range.

use std::path::Path;

use serde::Serialize;

/// The `server-stats` `registry_cleanup` section.
#[derive(Clone, Debug, Default, Serialize)]
pub struct RegistryCleanupSnapshot {
    /// The file that the last rebuild replaced, while it is beside the
    /// registry; `null` when none is.
    pub kept_file: Option<KeptRegistryFileSnapshot>,
    /// Saved reducer states that did not load and are kept as they were
    /// (`meta` keys `journal_reducer_kept.<reducer>`).
    pub kept_raw: u64,
    /// `null` unless the registry could not be read; `kept_raw` is then 0.
    pub error: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct KeptRegistryFileSnapshot {
    /// The file name beside the registry: `.pre-output-cleanup` until one
    /// full start on the new registry, then `.kept-before-cleanup`.
    pub name: String,
    pub bytes: u64,
    /// When the rebuild replaced it, in milliseconds since the Unix epoch;
    /// `null` when that is not known (the file then stays).
    pub swapped_at_ms: Option<u64>,
    /// The first time the file can go: 7 days after `swapped_at_ms`.
    pub kept_until_ms: Option<u64>,
    /// Full starts counted since the rebuild, and how many more the file
    /// stays through. It goes at the first start after both conditions.
    pub full_starts: u64,
    pub full_starts_left: u64,
}

/// Reads the `registry_cleanup` section of the registry at `database_path`.
pub fn read_registry_cleanup(database_path: &Path) -> RegistryCleanupSnapshot {
    let kept_file =
        crate::workspace_registry::output_cleanup::held_backup(database_path).map(|held| {
            KeptRegistryFileSnapshot {
                name: held.name,
                bytes: held.bytes,
                swapped_at_ms: held.swapped_at_ms,
                kept_until_ms: held.kept_until_ms,
                full_starts: held.full_starts,
                full_starts_left: held.full_starts_left,
            }
        });
    let kept_raw = crate::workspace_registry::open_registry_database_read_only(database_path)
        .and_then(|connection| {
            connection.busy_timeout(std::time::Duration::from_millis(250))?;
            crate::workspace_registry::journal_retention::kept_reducer_states(&connection)
        });
    match kept_raw {
        Ok(kept_raw) => RegistryCleanupSnapshot { kept_file, kept_raw, error: None },
        Err(error) => {
            RegistryCleanupSnapshot { kept_file, kept_raw: 0, error: Some(format!("{error:#}")) }
        }
    }
}
