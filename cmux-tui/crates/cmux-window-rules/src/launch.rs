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
//!
//! [`landing`]: where the launch's front window lands once the saved windows
//! loaded: the workspace and tab the person was last on, Home when Home was
//! last or on a true first launch, and Home for a saved workspace the daemon
//! does not have (the one exception).
//!
//! [`fresh_landing`]: what a launch opens before the saved windows decide:
//! nothing until Home is ensured, then Home or a New Tab workspace for a tree
//! with no workspace of the person's own, and a New Tab workspace when no saved
//! window is open.

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

/// Where the person last was, from the daemon's saved front window (its record, not the launch snapshot). Home is
/// its own answer, never read off a missing tab: a tab or workspace that went is the unknown case below.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum LastFront {
    /// No saved window: a true first launch.
    #[default]
    Nothing,
    /// Home: the home workspace, or classic Home's top page.
    Home,
    /// A workspace, its focused pane and the tab that pane showed.
    Workspace {
        workspace: String,
        #[serde(default)]
        pane: Option<String>,
        #[serde(default)]
        tab: Option<String>,
    },
}

/// The saved tab in the live tree.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabStanding {
    /// Listed, its process running.
    Live,
    /// Listed, its process ended (a reboot, a killed daemon): the daemon relaunches it under the same terminal,
    /// or shows its restart placeholder. Still the tab to land on.
    Ended,
    /// Not listed (closed meanwhile), or no tab was saved.
    #[default]
    Gone,
}

/// What the app knows once the live tree applied and the saved windows loaded.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LandingFacts {
    pub last: LastFront,
    /// The live tree has `last`'s workspace.
    pub workspace_live: bool,
    /// `last`'s tab in the live tree.
    pub tab: TabStanding,
}

/// Why a launch lands on Home.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HomeWhy {
    /// Nothing saved: a true first launch.
    FirstLaunch,
    /// The person was last on Home.
    LastWasHome,
    /// The saved workspace is one the daemon does not have (the known exception: nothing stands in for it).
    UnknownWorkspace,
}

/// Where the launch's front window lands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Landing {
    Home {
        why: HomeWhy,
    },
    /// That workspace; that tab in that pane when the tree still lists it, else the pane's current tab.
    Workspace {
        workspace: String,
        pane: Option<String>,
        tab: Option<String>,
    },
}

/// Where a launch lands (Leo 2026-11-18: "if it's not first time and the user was on a workspace and a tab, obv
/// just take them there"; "ofc reopening home if they were prev on home is fine"). Exactly where the person was:
/// Home only on a true first launch, when Home was last, or when the daemon lacks the saved workspace. A tab whose
/// process ended is still that tab (the daemon relaunches it), and neither which copy of the app runs nor a cold
/// daemon is an input.
pub fn landing(facts: &LandingFacts) -> Landing {
    match &facts.last {
        LastFront::Nothing => Landing::Home { why: HomeWhy::FirstLaunch },
        LastFront::Home => Landing::Home { why: HomeWhy::LastWasHome },
        LastFront::Workspace { .. } if !facts.workspace_live => {
            Landing::Home { why: HomeWhy::UnknownWorkspace }
        }
        LastFront::Workspace { workspace, pane, tab } => Landing::Workspace {
            workspace: workspace.clone(),
            pane: pane.clone(),
            tab: tab.clone().filter(|_| facts.tab != TabStanding::Gone),
        },
    }
}

/// What the app knows when the launch decides whether it opens something fresh: before the restore places the saved
/// windows, and again once it found none of them open (`no_saved_window_open`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FreshFacts {
    /// The tree has no workspace of the person's own (Home, incognito leftovers and recovered terminals do not
    /// count). Read with the Home workspace `ensure_home` named, so it means nothing while Home is not ensured yet.
    pub empty_tree: bool,
    /// Saved windows exist and none of them is open (#31514: a relaunch restores only what was open at quit).
    pub no_saved_window_open: bool,
    /// Home is classic Home, which has no Home workspace to land on.
    pub classic_home: bool,
    /// `ensure_home` named a Home workspace.
    pub home_ensured: bool,
    /// Home is not ensured yet: an `ensure_home` is in flight, or this launch ensures Home and none answered yet
    /// (its Home can start after the first frame).
    pub home_not_ensured_yet: bool,
}

/// What a launch opens before, or instead of, the saved windows.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FreshLanding {
    /// Home, the Chief's workspace.
    Home,
    /// A new workspace on its New Tab page.
    NewTab,
    /// Open nothing yet: ask again once Home is ensured or the launch can no longer ensure it.
    WaitForHome,
    /// Nothing fresh: the saved windows reopen, and [`landing`] picks where.
    Saved,
}

/// What a launch opens fresh (Leo 2026-11-18: "fresh startup opening home is obv fine but if it's not first time and
/// the user was on a workspace and a tab, obv just take them there"). It waits while Home is not ensured yet: until
/// then the tree cannot tell Home from a workspace of the person's own, so a relaunch would make a workspace over its
/// saved front and a fresh install would miss Home. Then an empty tree lands on Home, or on a New Tab workspace under
/// classic Home or when `ensure_home` named none; a tree with workspaces of the person's own reopens the saved
/// windows, or opens a New Tab workspace when none of them is open.
pub fn fresh_landing(facts: &FreshFacts) -> FreshLanding {
    if facts.home_not_ensured_yet {
        FreshLanding::WaitForHome
    } else if !facts.empty_tree {
        if facts.no_saved_window_open { FreshLanding::NewTab } else { FreshLanding::Saved }
    } else if facts.classic_home || !facts.home_ensured {
        FreshLanding::NewTab
    } else {
        FreshLanding::Home
    }
}

#[cfg(test)]
#[path = "launch_tests.rs"]
mod tests;
