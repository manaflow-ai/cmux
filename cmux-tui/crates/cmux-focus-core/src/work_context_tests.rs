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
    trail.candidates(target).into_iter().find_map(|entry| folders.get(entry.tab.as_str()).copied())
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
