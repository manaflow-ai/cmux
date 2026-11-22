//! Strict tab history: Go Back One Tab and Go to Recent Tab, in any
//! workspace or only in the current one (Leo, 2026-11-21: "all of rex's
//! stuff"). Opt in: the actions have no default shortcut.
//!
//! This is not the location trail. The trail's steps follow
//! `navigation.history.scope` (by default one step per workspace) and its
//! `workspace` scope still admits top pages of the window, so a trail walk is
//! not tab history. Here every settled tab is a visit, whatever that
//! setting is, and the workspace scope is strict: only tabs of the current
//! workspace on the same machine, never a page or another workspace.
//!
//! The model is most recent last, one visit per tab:
//! - [`TabHistory::record`] moves a settled tab to the newest place. While a
//!   Back walk is on, settling on its target changes nothing (the walk goes
//!   on); settling anywhere else ends the walk, and the tab the walk stopped
//!   at becomes the newest visit before the new one.
//! - [`TabHistory::step`] `back` walks one older tab in scope per repeat;
//!   `recent` is the newest other tab in scope, so repeating it toggles.
//! - [`TabHistory::forget`] drops a closed tab.
//!
//! Pure: the app keeps the value (its JSON) and sends it with each op.

use serde::{Deserialize, Serialize};

/// Visits kept (the oldest go).
pub const CAPACITY: usize = 100;

/// One settled tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabVisit {
    pub tab: String,
    /// The workspace showing it.
    pub workspace: String,
    /// The machine of that workspace (empty: this Mac).
    #[serde(default)]
    pub machine: String,
}

impl TabVisit {
    fn same_workspace(&self, other: &TabVisit) -> bool {
        self.machine == other.machine && self.workspace == other.workspace
    }
}

/// Which tabs a step may reach.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabScope {
    /// Every tab in the history.
    Any,
    /// Only tabs of the current tab's workspace on the same machine.
    Workspace,
}

/// What a step does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TabStep {
    /// One tab further back each repeat.
    Back,
    /// The tab before this one; again returns.
    Recent,
}

/// A Back walk in progress: the index of the visit it showed last.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Walk {
    pub at: usize,
    pub scope: TabScope,
}

/// The tab history the app keeps.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabHistory {
    /// Oldest first, one per tab.
    #[serde(default)]
    pub visits: Vec<TabVisit>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub walk: Option<Walk>,
}

impl TabHistory {
    /// A tab settled. Answers whether the history changed.
    pub fn record(&mut self, visit: TabVisit) -> bool {
        if let Some(walk) = self.walk {
            if self.visits.get(walk.at).is_some_and(|shown| shown.tab == visit.tab) {
                return false;
            }
            // The walk ended: where it stopped is the place the person left.
            self.walk = None;
            if walk.at < self.visits.len() {
                let stopped = self.visits.remove(walk.at);
                self.visits.push(stopped);
            }
        }
        if self.visits.last() == Some(&visit) {
            return false;
        }
        self.visits.retain(|old| old.tab != visit.tab);
        self.visits.push(visit);
        let excess = self.visits.len().saturating_sub(CAPACITY);
        self.visits.drain(..excess);
        true
    }

    /// The tab to show for `step` within `scope` from `current` (the focused
    /// tab), or none: nowhere to go. The app shows it and then records it.
    pub fn step(&mut self, step: TabStep, scope: TabScope, current: &TabVisit) -> Option<TabVisit> {
        let in_scope = |visit: &TabVisit| {
            visit.tab != current.tab
                && match scope {
                    TabScope::Any => true,
                    TabScope::Workspace => visit.same_workspace(current),
                }
        };
        let from = match (step, self.walk) {
            (TabStep::Back, Some(walk))
                if walk.scope == scope
                    && self.visits.get(walk.at).is_some_and(|shown| shown.tab == current.tab) =>
            {
                walk.at
            }
            _ => {
                // A new step starts from the current tab as the newest visit.
                self.walk = None;
                self.record(current.clone());
                self.visits.len()
            }
        };
        let at = self.visits[..from].iter().rposition(in_scope)?;
        if step == TabStep::Back {
            self.walk = Some(Walk { at, scope });
        }
        Some(self.visits[at].clone())
    }

    /// A tab closed (or could not be shown): it leaves the history.
    pub fn forget(&mut self, tab: &str) -> bool {
        let Some(index) = self.visits.iter().position(|visit| visit.tab == tab) else {
            return false;
        };
        self.visits.remove(index);
        if let Some(walk) = &mut self.walk {
            match walk.at.cmp(&index) {
                std::cmp::Ordering::Equal => self.walk = None,
                std::cmp::Ordering::Greater => walk.at -= 1,
                std::cmp::Ordering::Less => {}
            }
        }
        true
    }
}

/// One `window_history_tab` request: the app's history and what to do.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    #[serde(default)]
    pub history: TabHistory,
    #[serde(flatten)]
    pub op: Op,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum Op {
    Record { visit: TabVisit },
    Step { step: TabStep, scope: TabScope, current: TabVisit },
    Forget { tab: String },
}

/// The answer: the history to keep and, for a step, the tab to show.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub history: TabHistory,
    pub changed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<TabVisit>,
}

/// Runs one request.
pub fn apply(request: Request) -> Reply {
    let Request { mut history, op } = request;
    let before = history.clone();
    let target = match op {
        Op::Record { visit } => {
            history.record(visit);
            None
        }
        Op::Step { step, scope, current } => history.step(step, scope, &current),
        Op::Forget { tab } => {
            history.forget(&tab);
            None
        }
    };
    let changed = history != before;
    Reply { history, changed, target }
}

#[cfg(test)]
#[path = "tab_history_tests.rs"]
mod tests;
