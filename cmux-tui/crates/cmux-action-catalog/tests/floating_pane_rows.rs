//! The catalog rows of floating panes: Float Pane, New Floating Pane and Toggle Quick Terminal.
//!
//! Float Pane and New Floating Pane each have a plain default key. Toggle Quick Terminal is a
//! chord under the leader (Cmd-J, then T): the leader arms the chord, so the action has no plain
//! key of its own. Each row is in the `pane` category, so the app must bind a handler for it
//! (`swift_parity`'s `new_rows_in_handler_coverage_categories_have_an_app_binding`), and each
//! title has a value in every language of the catalog.

use cmux_action_catalog::{
    Action, CMD, CTRL, Decision, LOCALES, OPT, SHIFT, Shortcut, find, strings,
};

const ROWS: [(&str, &str, &str); 3] = [
    ("toggleFloatingPane", "action.toggleFloatingPane", "Float Pane"),
    ("newFloatingPane", "action.newFloatingPane", "New Floating Pane"),
    ("toggleQuickTerminal", "action.toggleQuickTerminal", "Toggle Quick Terminal"),
];

fn row(id: &str) -> &'static Action {
    find(id).unwrap_or_else(|| panic!("{id} is not a catalog action"))
}

fn stroke(shortcut: Option<Shortcut>) -> Option<(&'static str, u8)> {
    shortcut.map(|s| (s.key, s.modifiers))
}

#[test]
fn the_three_rows_are_pane_actions_with_their_titles() {
    for (id, key, title) in ROWS {
        let action = row(id);
        assert_eq!(action.category, "pane", "{id}");
        assert_eq!(action.group, "PaneActionCatalog", "{id}");
        assert_eq!(action.title.table, "ActionCatalog", "{id}");
        assert_eq!(action.title.key, key, "{id}");
        assert_eq!(action.title.en, title, "{id}");
        assert!(action.is_palette_visible(), "{id}: the palette lists it");
        assert!(!action.is_debug_only, "{id}");
        assert!(!action.cli_name.is_empty(), "{id}: a row has a CLI name");
        assert!(action.surface_plan.cli.is_some(), "{id}: the CLI offers it or says why not");
        assert!(
            action.surface_plan.context_menu().is_some(),
            "{id}: a right-click menu offers it or says why not"
        );
    }
}

#[test]
fn float_pane_has_its_key_and_acts_on_a_pane() {
    let action = row("toggleFloatingPane");
    assert_eq!(stroke(action.default_shortcut), Some(("\r", OPT | SHIFT | CMD)));
    assert!(action.default_chord.is_none());
    assert_eq!(action.targets, &["pane"]);
    assert_eq!(action.surface_plan.cli, Some(Decision::Offered));
    assert_eq!(action.cli_name, "pane toggle-floating");
    // One place: the Layout folder of the pane's right-click menu, after Equalize Splits (101).
    let places: Vec<_> = action
        .surface_plan
        .context_menus
        .iter()
        .map(|place| (place.context, place.group, place.rank, place.folder))
        .collect();
    assert_eq!(places, [("pane", "layout", 102, Some("layout"))]);
    assert!(!action.starts_terminal, "Float Pane moves a pane that exists");
}

#[test]
fn new_floating_pane_has_its_key_and_starts_a_terminal() {
    let action = row("newFloatingPane");
    assert_eq!(stroke(action.default_shortcut), Some(("n", CTRL | SHIFT | CMD)));
    assert!(action.default_chord.is_none());
    assert_eq!(action.targets, &["pane"]);
    assert_eq!(action.surface_plan.cli, Some(Decision::Offered));
    assert_eq!(action.cli_name, "pane new-floating");
    // No right-click row: the palette and the key are its surfaces.
    assert_eq!(action.surface_plan.context_menu(), Some(Decision::Exempt("pointerMenuTrim")));
    assert!(action.starts_terminal);
    assert!(action.opens_workspace_content);
}

#[test]
fn quick_terminal_is_a_chord_under_the_leader_with_no_plain_key() {
    let action = row("toggleQuickTerminal");
    assert!(action.default_shortcut.is_none(), "the leader is never also a plain key");
    let chord = action.default_chord.expect("a default chord");
    assert_eq!((chord.first.key, chord.first.modifiers), ("j", CMD));
    assert_eq!((chord.second.key, chord.second.modifiers), ("t", 0));
    // The leader is the one that the other chords have.
    let other = row("terminal.scrollToSelection").default_chord.expect("a default chord");
    assert_eq!(chord.first, other.first);
    assert!(action.starts_terminal, "the first run makes the terminal");
    assert!(action.opens_workspace_content);
    assert!(action.targets.is_empty(), "it acts on the workspace that has the focus");
    // No CLI verb (`guiOnly`) and no right-click row (`noObject`).
    assert_eq!(action.surface_plan.cli, Some(Decision::Exempt("guiOnly")));
    assert_eq!(action.surface_plan.context_menu(), Some(Decision::Exempt("noObject")));
}

#[test]
fn each_title_has_a_value_in_every_language() {
    for (id, key, title) in ROWS {
        assert_eq!(strings::lookup("ActionCatalog", key, 0), Some(title), "{id} in en");
        for (index, locale) in LOCALES.iter().enumerate().skip(1) {
            let value = strings::lookup("ActionCatalog", key, index);
            assert!(value.is_some_and(|v| !v.trim().is_empty()), "{id} has no title in {locale}");
        }
        let japanese = strings::locale_index("ja");
        assert_ne!(
            strings::lookup("ActionCatalog", key, japanese),
            Some(title),
            "{id}: the Japanese title is not the English one"
        );
    }
}
