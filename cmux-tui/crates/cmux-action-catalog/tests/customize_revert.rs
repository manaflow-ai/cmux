//! Undo Look Change (`customize.revert`): the recovery key, one fixed chord that runs
//! `cmux customize revert` (customization capability matrix row `recovery-hotkey`). The chord's
//! freedom from every other owner is `default_keymap_conflicts.rs`; this file pins the row itself.
use cmux_action_catalog::{
    CMD, CTRL, Decision, KEYBOARD, OPT, PALETTE, Shortcut, find, json, strings,
};

#[test]
fn undo_look_change_is_on_ctrl_opt_cmd_z() {
    let action = find("customize.revert").expect("the Undo Look Change action");
    assert_eq!(action.title.en, "Undo Look Change");
    assert_eq!(action.default_shortcut, Some(Shortcut { key: "z", modifiers: CTRL | OPT | CMD }));
    assert_eq!(action.surfaces & (PALETTE | KEYBOARD), PALETTE | KEYBOARD);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    // `cmux customize revert` is the CLI's own verb.
    assert_eq!(action.surface_plan.cli, Some(Decision::Exempt("ownerVerb")));
    assert_eq!(action.request, None, "the app binds it by id (CustomizeTryOnPage.bindRevert)");
    // Nothing else defaults to the chord.
    let shortcut = action.default_shortcut;
    let others: Vec<_> = cmux_action_catalog::actions()
        .filter(|a| a.id != action.id && a.default_shortcut == shortcut)
        .map(|a| a.id)
        .collect();
    assert!(others.is_empty(), "{others:?} also default to Ctrl-Opt-Cmd-Z");
}

#[test]
fn undo_look_change_is_translated_in_every_locale() {
    let action = find("customize.revert").expect("the Undo Look Change action");
    let hint = action.hint.expect("a hint");
    for (index, locale) in strings::LOCALES.iter().enumerate() {
        for text in [&action.title, &hint] {
            let value = strings::lookup(text.table, text.key, index)
                .unwrap_or_else(|| panic!("no {} for {locale}", text.key));
            if *locale != "en" {
                assert_ne!(value, text.en, "untranslated {} for {locale}", text.key);
            }
        }
    }
}

/// The row the app reads (`cmux_action_catalog_json`), printed for the PR's read back.
#[test]
fn the_exported_row_carries_the_shortcut() {
    let catalog = json::catalog_value(0);
    let row = catalog["actions"]
        .as_array()
        .expect("actions")
        .iter()
        .find(|row| row["id"] == "customize.revert")
        .expect("customize.revert in the export");
    println!("{}", serde_json::to_string(row).unwrap());
    assert_eq!(row["title"], "Undo Look Change");
    assert!(!row["defaultShortcut"].is_null(), "{row}");
}
