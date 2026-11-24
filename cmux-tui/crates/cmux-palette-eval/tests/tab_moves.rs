//! Moving the focused tab from the Command Palette by the words a person types (user, 2026-11-11:
//! "im in a tab and i want to move it to right split"; Cmd-Shift-P "move to right split" listed
//! only "Tab: Move…" and "Tab Group: Move…").
//!
//! The rows are the catalog's own palette rows in English (`support/catalog.rs`), ranked by the
//! real ranker. So a catalog edit that loses one of these phrases fails here, not in a person's
//! palette.

#[path = "support/catalog.rs"]
mod catalog;

use catalog::{ranked, ranked_rows};
use cmux_action_catalog::palette;

/// What a person types, and the action that must be the first row.
const FIRST: &[(&str, &str)] = &[
    ("move to right split", "moveSurfaceToPaneRight"),
    ("move tab to right split", "moveSurfaceToPaneRight"),
    ("move to split right", "moveSurfaceToPaneRight"),
    ("send tab right", "moveSurfaceToPaneRight"),
    ("move to left split", "moveSurfaceToPaneLeft"),
    ("send tab left", "moveSurfaceToPaneLeft"),
    ("move to split below", "moveSurfaceToPaneDown"),
    ("move to bottom split", "moveSurfaceToPaneDown"),
    ("move to split above", "moveSurfaceToPaneUp"),
    ("move to top split", "moveSurfaceToPaneUp"),
    ("move to new split", "tab.moveToNewSplit"),
    ("move to new column", "tab.moveToNewColumn"),
    ("move to new workspace", "palette.moveTabToNewWorkspace"),
    ("move to workspace", "tab.moveToWorkspace"),
    ("move to new window", "tab.moveToNewWindow"),
    ("pop out", "tab.moveToNewWindow"),
    ("pop out tab", "tab.moveToNewWindow"),
    ("move to other window", "tab.moveToWindow"),
    ("move to window", "tab.moveToWindow"),
    ("duplicate to split", "tab.duplicateToNewSplit"),
    ("duplicate tab to split", "tab.duplicateToNewSplit"),
    ("move group to new split", "tabGroup.moveToNewSplit"),
    ("move group to new window", "tabGroup.moveToNewWindow"),
];

#[test]
fn each_tab_move_phrase_puts_its_action_first() {
    let failed: Vec<String> = FIRST
        .iter()
        .filter_map(|(query, id)| {
            let top = ranked(query);
            let want = format!("action:{id}");
            (top.first() != Some(&want))
                .then(|| format!("{query:?}: want {want}, got {:?}", &top[..top.len().min(4)]))
        })
        .collect();
    assert!(failed.is_empty(), "{failed:#?}");
}

/// The rows' own aliases alone (no alias table in the request) put each phrase's action first
/// too: the ranker, not the host, ranks a built-in alias like the user's.
#[test]
fn each_tab_move_phrase_puts_its_action_first_by_the_rows_own_aliases() {
    let failed: Vec<String> = FIRST
        .iter()
        .filter_map(|(query, id)| {
            let top: Vec<String> =
                ranked_rows(query, false).into_iter().map(|row| row.id).collect();
            let want = format!("action:{id}");
            (top.first() != Some(&want))
                .then(|| format!("{query:?}: want {want}, got {:?}", &top[..top.len().min(4)]))
        })
        .collect();
    assert!(failed.is_empty(), "{failed:#?}");
}

/// "split right" stays the Split Right command (a daily row, the new terminal beside), with the move
/// close behind it.
#[test]
fn split_right_still_splits_and_the_move_is_in_reach() {
    let top = ranked("split right");
    assert_eq!(top.first().map(String::as_str), Some("action:splitRight"), "{top:?}");
    assert!(
        top.iter().take(10).any(|id| id == "action:moveSurfaceToPaneRight"),
        "{:?}",
        &top[..top.len().min(10)]
    );
}

/// Tab: Move… lists every tab move this file names, so a person who opens it finds them there too.
#[test]
fn tab_move_lists_every_tab_move() {
    let family =
        palette::FAMILIES.iter().find(|family| family.id == "tab.move").expect("Tab: Move…");
    for id in ["tab.moveToWindow", "tab.duplicateToNewSplit", "tab.moveToSpace"] {
        assert!(family.members.contains(&id), "Tab: Move… lacks {id}");
    }
}
