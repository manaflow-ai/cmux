//! What the catalog's own palette rows rank first for the words people type
//! (`support/catalog.rs`): Screen Sharing for its phrases, and the daily commands for their
//! everyday queries.
//!
//! Cmd-Shift-P "share screen" listed Share Screen with Chief first and Screen Sharing third: the
//! Screen Sharing phrases were keywords only. They are its built-in aliases now, and a row's own
//! alias ranks it like the user's `palette.aliases`.

#[path = "support/catalog.rs"]
mod catalog;

use catalog::{ranked, ranked_rows};

fn top(query: &str, count: usize) -> Vec<String> {
    ranked(query).into_iter().take(count).collect()
}

#[test]
fn screen_sharing_is_first_for_its_phrases() {
    for query in ["share screen", "screen share", "vnc", "remote desktop", "screen sharing"] {
        for with_alias_table in [true, false] {
            let order: Vec<String> = ranked_rows(query, with_alias_table)
                .into_iter()
                .take(5)
                .map(|row| row.id)
                .collect();
            assert_eq!(
                order.first().map(String::as_str),
                Some("action:macScreen.open"),
                "{query:?} (alias table {with_alias_table}): {order:?}"
            );
        }
    }
}

#[test]
fn chief_screen_sharing_stays_in_reach_for_share_screen() {
    let order = top("share screen", 5);
    assert!(order.iter().any(|id| id == "action:chief.screenShare.start"), "{order:?}");
}

/// The everyday queries (the daily commands' titles and their short forms) and the row each
/// ranked first before word stems and the rows' own aliases. Each keeps it.
const COMMON: &[(&str, &str)] = &[
    ("new tab", "action:newTab.default"),
    ("split right", "action:splitRight"),
    ("split down", "action:splitDown"),
    ("split", "action:splitRight"),
    ("settings", "action:openSettings"),
    ("close tab", "action:closeTab"),
    ("close pane", "action:closePane"),
    ("close workspace", "action:closeWorkspace"),
    ("new window", "action:newWindow"),
    ("find", "action:find"),
    ("open folder", "action:openFolder"),
    ("rename tab", "action:renameTab"),
    ("rename workspace", "action:renameWorkspace"),
    ("toggle sidebar", "action:toggleSidebar"),
    ("new workspace", "action:newTab"),
    ("reopen closed", "action:reopenClosedWorkspace"),
    ("theme", "action:terminal.setTheme"),
    ("font", "action:terminal.increaseFontSize"),
    ("background", "action:appearance.changeBackground"),
    ("zoom", "action:zoomWindow"),
    ("check for updates", "action:palette.checkForUpdates"),
    ("keybindings", "action:keybindings.open"),
    ("reload configuration", "action:reloadConfiguration"),
    ("go to workspace", "action:goToWorkspace"),
    ("jump to unread", "action:jumpToUnread"),
    ("equalize splits", "action:equalizeSplits"),
    ("new agent chat", "action:palette.newAgentChat"),
    ("global search", "action:globalSearch"),
    ("recently closed", "action:recentlyClosed"),
    ("screen sharing", "action:macScreen.open"),
];

#[test]
fn the_common_queries_keep_their_first_row() {
    assert!(COMMON.len() >= 20);
    let changed: Vec<String> = COMMON
        .iter()
        .filter_map(|(query, want)| {
            let order = top(query, 3);
            (order.first().map(String::as_str) != Some(*want))
                .then(|| format!("{query:?}: want {want}, got {order:?}"))
        })
        .collect();
    assert!(changed.is_empty(), "{changed:#?}");
}
