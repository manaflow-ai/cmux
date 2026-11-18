//! Whether the launch snapshot the app drew before it connected is this
//! daemon's (cmuxterm-hq#12660). The app draws its first window from the
//! snapshot file its defaults name (`cmuxNext.launchSnapshotPath.<session>`),
//! before the daemon answers. When the daemon then answers with another
//! session, or without the workspaces the drawn window shows, the snapshot is
//! stale: a reset or recovered daemon state that kept the default, a restored
//! backup that brought back only one of the two, or two copies of a build with
//! one bundle id. The app then drops what it drew from it and the launch goes
//! on as one with nothing to restore, which lands on Home. Never a workspace
//! made to stand in for one the daemon does not have.
//!
//! A current snapshot changes nothing: the daemon's saved windows still
//! decide what reopens.

use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::Path;

/// What the app knows once the live tree applied.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SnapshotFacts {
    /// The snapshot tree's registry id (the session it was written by); none
    /// from an older daemon's file.
    pub snapshot_session: Option<String>,
    /// The live daemon's registry id.
    pub live_session: Option<String>,
    /// The workspace the launch window showed from the snapshot (its saved
    /// front window's), if any.
    pub shown: Option<String>,
    /// Every workspace the launch window listed from the snapshot.
    pub listed: Vec<String>,
    /// Those of `shown` and `listed` the live tree has.
    pub live: Vec<String>,
}

/// The snapshot's standing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Verdict {
    /// The daemon's own snapshot: keep what the launch drew from it.
    Current,
    /// Written by another session than the one that answered.
    OtherSession,
    /// The daemon has the session but not the workspaces the window drew.
    UnknownWorkspaces,
}

impl Verdict {
    /// The launch drops what it drew from the snapshot.
    pub fn is_stale(self) -> bool {
        self != Verdict::Current
    }
}

/// The snapshot's standing from `facts`. Another session first; then the
/// shown workspace the daemon lacks, or a listed set none of which it has.
/// A session either side does not name is not compared, and a window that
/// drew no workspace has none to miss.
pub fn verdict(facts: &SnapshotFacts) -> Verdict {
    if let (Some(snapshot), Some(live)) = (&facts.snapshot_session, &facts.live_session)
        && snapshot != live
    {
        return Verdict::OtherSession;
    }
    let has = |id: &String| facts.live.contains(id);
    let shown_missing = facts.shown.as_ref().is_some_and(|shown| !has(shown));
    let listed_missing = !facts.listed.is_empty() && !facts.listed.iter().any(has);
    if shown_missing || listed_missing { Verdict::UnknownWorkspaces } else { Verdict::Current }
}

/// The registry file's name prefix: `cmux-next/launch-snapshot-registry.<session>`
/// under a home's Application Support.
pub const REGISTRY_FILE_PREFIX: &str = "launch-snapshot-registry.";
/// A registry id longer than this is not one the app wrote.
pub const MAX_REGISTRY_ID_BYTES: usize = 256;

/// The registry id (session) this home's app last saw live for `session`:
/// what its last handshake wrote to
/// `<app_support>/cmux-next/launch-snapshot-registry.<session>` (the id alone,
/// UTF-8). The one reader of that file: the app's launch read compares it with
/// the launch snapshot's before drawing (`verdict`), and the launch shell's
/// stage 0 with its launch record's. `app_support` is the home's
/// `Library/Application Support`; `session` the daemon session name as in the
/// app's `cmuxNext.launchSnapshotPath.<session>` default. None when the file is
/// missing, empty, not UTF-8 or longer than [`MAX_REGISTRY_ID_BYTES`].
pub fn current_registry_id(app_support: &Path, session: &str) -> Option<String> {
    if session.is_empty() || session.contains(['/', '\0']) {
        return None;
    }
    let path = app_support.join("cmux-next").join(format!("{REGISTRY_FILE_PREFIX}{session}"));
    let mut bytes = Vec::with_capacity(64);
    let file = std::fs::File::open(path).ok()?;
    // One byte past the bound tells an over-long file from a full one.
    file.take(MAX_REGISTRY_ID_BYTES as u64 + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() > MAX_REGISTRY_ID_BYTES {
        return None;
    }
    let id = std::str::from_utf8(&bytes).ok()?.trim();
    (!id.is_empty()).then(|| id.to_owned())
}

#[cfg(test)]
#[path = "launch_tests.rs"]
mod tests;
