//! The terminals and agent chats a person focused, newest first
//! (NEW-WORK-INHERITS-CONTEXT): what a new terminal or agent chat copies its
//! folder from, and what a new chat copies its harness, model, effort and
//! mode from.
//!
//! The rule, first match wins:
//! 1. The tab the person is in (`current`), when it is a terminal or an agent chat.
//! 2. The most recently focused terminal or chat of the target workspace.
//! 3. Only when that workspace holds no terminal or chat of its own (a
//!    browser-only or empty workspace): the most recently focused one of the
//!    same window.
//! 4. Nothing: the caller's own fallback (the daemon's resolver, then the home folder).
//!
//! A workspace that has terminals nobody focused yet (a restored launch) keeps
//! them: step 3 never brings another workspace's project into it. Another
//! window is never a source.
//!
//! The app reads each candidate's value live (its folder, its chat settings;
//! a closed tab has none), so [`WorkContextTrail::candidates`] answers the
//! entries in the rule's order and the app takes the first that has one.

use serde::{Deserialize, Serialize};

/// The entries kept; the oldest goes first.
pub const LIMIT: usize = 64;

/// What a trail entry was.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    /// A terminal tab.
    Terminal,
    /// An agent chat tab.
    Chat,
}

/// One focused terminal or chat tab.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// The tab's id.
    pub tab: String,
    /// The id of the workspace that holds the tab.
    pub workspace: String,
    /// The id of the window that showed it.
    pub window: String,
    /// Whether it is a terminal or a chat.
    pub kind: Kind,
}

/// Newest first, one per tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct WorkContextTrail {
    pub entries: Vec<Entry>,
}

/// Where a new terminal or chat goes, for [`WorkContextTrail::candidates`].
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    /// The tab the person is in, if any.
    #[serde(default)]
    pub current: Option<Entry>,
    /// The target workspace's id.
    #[serde(default)]
    pub workspace: Option<String>,
    /// The target window's id.
    #[serde(default)]
    pub window: Option<String>,
    /// Whether the target workspace holds a terminal or chat of its own.
    pub workspace_has_work: bool,
    /// The kinds of entry that may be a source.
    pub kinds: Vec<Kind>,
}

impl WorkContextTrail {
    /// `entry`'s tab was focused now.
    pub fn record(&mut self, entry: Entry) {
        if self.entries.first() == Some(&entry) {
            return;
        }
        self.entries.retain(|kept| kept.tab != entry.tab);
        self.entries.insert(0, entry);
        self.entries.truncate(LIMIT);
    }

    /// `tab` closed: it is no source any more.
    pub fn forget(&mut self, tab: &str) {
        self.entries.retain(|kept| kept.tab != tab);
    }

    /// The entries the rule reads, in its order: the first that gives a live
    /// value wins. The window's entries follow the workspace's only when the
    /// workspace holds no work of its own; an entry may then come twice (its
    /// value is read again, and skipped again).
    pub fn candidates<'a>(&'a self, target: &'a Target) -> Vec<&'a Entry> {
        let kinds = &target.kinds;
        let mut found: Vec<&Entry> = Vec::new();
        if let Some(current) = &target.current
            && kinds.contains(&current.kind)
        {
            found.push(current);
        }
        let current_tab = target.current.as_ref().map(|current| current.tab.as_str());
        let eligible =
            |entry: &&Entry| kinds.contains(&entry.kind) && Some(entry.tab.as_str()) != current_tab;
        if let Some(workspace) = &target.workspace {
            found.extend(
                self.entries.iter().filter(eligible).filter(|entry| &entry.workspace == workspace),
            );
        }
        if !target.workspace_has_work
            && let Some(window) = &target.window
        {
            found.extend(
                self.entries.iter().filter(eligible).filter(|entry| &entry.window == window),
            );
        }
        found
    }
}

#[cfg(test)]
#[path = "work_context_tests.rs"]
mod tests;
