//! Update Status (`updates.status`): a palette row and `cmux settings update-status` that read the
//! running build, the staged update and relaunch readiness. The answer's fields are the app's
//! (`UpdateStatusAnswerTests`); this file pins the row.
use cmux_action_catalog::{Decision, PALETTE, find, json, strings};

#[test]
fn update_status_is_on_the_palette_and_the_cli() {
    let action = find("updates.status").expect("the Update Status action");
    assert_eq!(action.title.en, "Update Status");
    assert_eq!(action.surfaces & PALETTE, PALETTE);
    assert_eq!(action.surface_plan.palette, Decision::Offered);
    assert_eq!(action.surface_plan.cli, Some(Decision::Offered));
    assert_eq!(action.cli_name, "settings update-status");
    assert!(action.waits_for_result, "the CLI waits for the answer's fields");
    assert!(!action.is_destructive);
    assert_eq!(action.request, None, "the app binds it by id (UpdateHandlers)");
}

#[test]
fn update_status_is_translated_in_every_locale() {
    let action = find("updates.status").expect("the Update Status action");
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

#[test]
fn the_exported_row_is_update_status() {
    let catalog = json::catalog_value(0);
    let row = catalog["actions"]
        .as_array()
        .expect("actions")
        .iter()
        .find(|row| row["id"] == "updates.status")
        .expect("updates.status in the export");
    println!("{}", serde_json::to_string(row).unwrap());
    assert_eq!(row["title"], "Update Status");
}
