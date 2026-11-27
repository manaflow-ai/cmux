//! Whether a machine's cmux-tui is older than this one (cx-3r9mt, hq-6d
//! 2026-10-15): the one rule the app asks through `cmux-tui remote
//! update-need` before it replaces a remote build. Capabilities order first,
//! the build time only when both builds serve the same capability set, so a
//! remote that lacks a capability this build serves is older even when its
//! commit is newer, and two builds never replace each other in turn.

use std::collections::BTreeSet;

use serde::Serialize;

/// What one build says about itself (`remote-probe --json`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BuildFacts {
    /// `build_identity`: the source commit (or a dirty-tree hash).
    pub commit: Option<String>,
    /// `build_time`: unix seconds of the commit the binary was built from;
    /// with the fleet's cmux-tui cache, the first build of that source tree
    /// (never the app's own commit time); 0 when unknown.
    pub time: u64,
    /// `daemon_capabilities`: the daemon capabilities the build always
    /// serves on any platform; None for a build before cx-3r9mt.
    pub capabilities: Option<BTreeSet<String>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Need {
    /// Same build, or no order between the two: change nothing.
    None,
    /// The remote is older: install this build there.
    Older,
    /// The remote is newer: never replace it from here.
    Newer,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reason {
    SameCommit,
    Capabilities,
    BuildTime,
    /// Each build serves a capability the other lacks.
    Incomparable,
    /// The remote predates the facts (no capability set), or this build
    /// does not know its own time.
    Unknown,
}

/// The rule. Same commit: none. Both capability sets known: a strict subset
/// is older, a strict superset newer, neither a subset of the other none
/// (incomparable). A remote without a capability set predates this rule:
/// older. Equal sets: this build's time unknown (0) is none; the remote's
/// time unknown (0) or earlier is older, later newer, the same time none.
pub fn update_need(local: &BuildFacts, remote: &BuildFacts) -> (Need, Reason) {
    if local.commit.is_some() && local.commit == remote.commit {
        return (Need::None, Reason::SameCommit);
    }
    let Some(remote_capabilities) = &remote.capabilities else {
        return (Need::Older, Reason::Unknown);
    };
    if let Some(local_capabilities) = &local.capabilities {
        let remote_has_all = local_capabilities.is_subset(remote_capabilities);
        let local_has_all = remote_capabilities.is_subset(local_capabilities);
        match (local_has_all, remote_has_all) {
            (true, false) => return (Need::Older, Reason::Capabilities),
            (false, true) => return (Need::Newer, Reason::Capabilities),
            (false, false) => return (Need::None, Reason::Incomparable),
            (true, true) => {}
        }
    }
    if local.time == 0 {
        return (Need::None, Reason::Unknown);
    }
    match remote.time.cmp(&local.time) {
        _ if remote.time == 0 => (Need::Older, Reason::BuildTime),
        std::cmp::Ordering::Less => (Need::Older, Reason::BuildTime),
        std::cmp::Ordering::Greater => (Need::Newer, Reason::BuildTime),
        std::cmp::Ordering::Equal => (Need::None, Reason::BuildTime),
    }
}
