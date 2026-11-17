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

#[cfg(test)]
#[path = "launch_tests.rs"]
mod tests;
