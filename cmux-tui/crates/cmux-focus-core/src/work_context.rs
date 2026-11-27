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
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn entry(tab: &str, workspace: &str, window: &str, kind: Kind) -> Entry {
        Entry { tab: tab.into(), workspace: workspace.into(), window: window.into(), kind }
    }

    fn terminal(tab: &str) -> Entry {
        entry(tab, "w1", "win1", Kind::Terminal)
    }

    fn chat(tab: &str) -> Entry {
        entry(tab, "w1", "win1", Kind::Chat)
    }

    fn folders() -> HashMap<&'static str, &'static str> {
        HashMap::from([
            ("t1", "/repo/a"),
            ("t2", "/repo/b"),
            ("c1", "/repo/chat"),
            ("t9", "/other/x"),
            ("tw", "/win2/y"),
        ])
    }

    fn target(
        current: Option<Entry>,
        workspace: &str,
        window: &str,
        has_work: bool,
        kinds: &[Kind],
    ) -> Target {
        Target {
            current,
            workspace: Some(workspace.into()),
            window: Some(window.into()),
            workspace_has_work: has_work,
            kinds: kinds.to_vec(),
        }
    }

    const BOTH: &[Kind] = &[Kind::Terminal, Kind::Chat];

    /// The first live folder, as the app reads the candidates.
    fn resolve(trail: &WorkContextTrail, target: &Target) -> Option<&'static str> {
        let folders = folders();
        trail
            .candidates(target)
            .into_iter()
            .find_map(|entry| folders.get(entry.tab.as_str()).copied())
    }

    fn plain(trail: &WorkContextTrail) -> Option<&'static str> {
        resolve(trail, &target(None, "w1", "win1", true, BOTH))
    }

    #[test]
    fn the_newest_focused_terminal_or_chat_of_the_workspace_wins() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t1"));
        trail.record(chat("c1"));
        assert_eq!(plain(&trail), Some("/repo/chat"));
        trail.record(terminal("t2"));
        assert_eq!(plain(&trail), Some("/repo/b"));
        // Focusing an older tab again makes it the newest.
        trail.record(terminal("t1"));
        assert_eq!(plain(&trail), Some("/repo/a"));
    }

    #[test]
    fn the_tab_the_person_is_in_wins_over_the_trail() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t2"));
        assert_eq!(
            resolve(&trail, &target(Some(chat("c1")), "w1", "win1", true, BOTH)),
            Some("/repo/chat")
        );
    }

    #[test]
    fn a_closed_or_folderless_tab_is_skipped() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t1"));
        trail.record(terminal("gone"));
        assert_eq!(plain(&trail), Some("/repo/a"));
        trail.record(terminal("t2"));
        trail.forget("t2");
        assert_eq!(plain(&trail), Some("/repo/a"));
        assert!(!trail.entries.iter().any(|entry| entry.tab == "t2"));
    }

    #[test]
    fn another_workspace_is_no_source_while_the_workspace_has_its_own_work() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t1"));
        trail.record(entry("t9", "w2", "win1", Kind::Terminal));
        assert_eq!(plain(&trail), Some("/repo/a"));
        assert_eq!(resolve(&trail, &target(None, "w3", "win1", true, BOTH)), None);
    }

    #[test]
    fn a_workspace_with_no_work_of_its_own_takes_the_windows_newest() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t1"));
        trail.record(entry("tw", "w5", "win2", Kind::Terminal));
        assert_eq!(resolve(&trail, &target(None, "w3", "win1", false, BOTH)), Some("/repo/a"));
        assert_eq!(resolve(&trail, &target(None, "w3", "win3", false, BOTH)), None);
    }

    #[test]
    fn chat_settings_come_only_from_chats() {
        let mut trail = WorkContextTrail::default();
        trail.record(chat("c1"));
        trail.record(terminal("t1"));
        assert_eq!(
            resolve(&trail, &target(Some(terminal("t2")), "w1", "win1", true, &[Kind::Chat])),
            Some("/repo/chat")
        );
    }

    #[test]
    fn the_current_tab_is_never_read_twice() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t1"));
        trail.record(terminal("t2"));
        let target = target(Some(terminal("t2")), "w1", "win1", true, BOTH);
        let tabs: Vec<&str> =
            trail.candidates(&target).iter().map(|entry| entry.tab.as_str()).collect();
        assert_eq!(tabs, ["t2", "t1"]);
    }

    #[test]
    fn no_workspace_and_no_window_gives_only_the_current_tab() {
        let mut trail = WorkContextTrail::default();
        trail.record(terminal("t1"));
        let target = Target {
            current: None,
            workspace: None,
            window: None,
            workspace_has_work: false,
            kinds: BOTH.to_vec(),
        };
        assert!(trail.candidates(&target).is_empty());
    }

    #[test]
    fn the_trail_keeps_one_entry_per_tab_up_to_its_limit() {
        let mut trail = WorkContextTrail::default();
        for index in 0..(LIMIT + 10) {
            trail.record(terminal(&format!("t{index}")));
        }
        trail.record(terminal(&format!("t{}", LIMIT + 9)));
        assert_eq!(trail.entries.len(), LIMIT);
        assert_eq!(trail.entries[0].tab, format!("t{}", LIMIT + 9));
        let unique: std::collections::HashSet<_> =
            trail.entries.iter().map(|entry| &entry.tab).collect();
        assert_eq!(unique.len(), LIMIT);
    }

    #[test]
    fn the_trail_is_the_swift_entry_array_on_the_wire() {
        let mut trail = WorkContextTrail::default();
        trail.record(chat("c1"));
        let json = serde_json::to_string(&trail).unwrap();
        assert_eq!(json, r#"[{"tab":"c1","workspace":"w1","window":"win1","kind":"chat"}]"#);
        assert_eq!(serde_json::from_str::<WorkContextTrail>(&json).unwrap(), trail);
    }
}
