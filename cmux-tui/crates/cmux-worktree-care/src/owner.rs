//! The session `wt new` recorded as a worktree's owner, and whether it
//! still runs here: a worktree whose owner lives is in use wherever the
//! owner works (`policy::decide`).

use std::path::Path;

use serde::{Deserialize, Serialize};

/// The file `wt new` writes in a worktree's private git folder, naming the
/// session that owns it.
pub const OWNER_FILE: &str = "wt-owner.json";

/// A worktree's owner, from [`OWNER_FILE`]: `{"owner": {"session_id",
/// "ids", "pid", "host", ...}, ...}`.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Owner {
    /// Its agent identity's session id.
    pub session_id: Option<String>,
    /// Every id its chat goes by (the harness's own session ids).
    pub ids: Vec<String>,
    pub pid: Option<u32>,
    /// Its recorded process runs on this machine, at the scan.
    pub runs: bool,
}

impl Owner {
    /// Whether `id` names this owner's session.
    pub fn is(&self, id: &str) -> bool {
        !id.is_empty()
            && (self.session_id.as_deref() == Some(id) || self.ids.iter().any(|i| i == id))
    }
}

#[derive(Deserialize)]
struct OwnerFile {
    owner: OwnerRecord,
}

#[derive(Deserialize)]
struct OwnerRecord {
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    ids: Vec<String>,
    #[serde(default)]
    pid: Option<u32>,
    #[serde(default)]
    host: Option<String>,
}

/// The owner `git_dir` records; `None` when there is no record or it does
/// not read.
pub fn owner(git_dir: &Path) -> Option<Owner> {
    let bytes = std::fs::read(git_dir.join(OWNER_FILE)).ok()?;
    let record = serde_json::from_slice::<OwnerFile>(&bytes).ok()?.owner;
    // A process on another machine cannot be checked from here.
    let here = record.host.as_deref().is_none_or(crate::procs::is_this_host);
    let runs = here && record.pid.is_some_and(crate::procs::owner_runs);
    Some(Owner { session_id: record.session_id, ids: record.ids, pid: record.pid, runs })
}
