//! `settings.get`'s `value` is the effective value a row reads, its default included: after
//! `settings reset --group appearance` removes `appearance.accent` from the file, `settings get
//! appearance.accent` answered `null` while the row said `neutral` (settings-undo-reset-nightly probe,
//! 2026-11-26 17:54Z: "appearance.accent reads null, not its default \"neutral\"").

use cmux_config::{Domains, FileRead, ManagedPreferences, Schema, State, Target, TeamPolicyLayer};
use serde_json::json;

const SCHEMA: &str = include_str!("../../../../schemas/settings/settings-schema.json");

fn state(file: &str) -> State {
    let schema: &'static Schema =
        Box::leak(Box::new(Schema::parse(SCHEMA).expect("the settings schema parses")));
    State::new(
        schema,
        FileRead::Text(file.to_string()),
        ManagedPreferences::default(),
        TeamPolicyLayer::default(),
        Domains::default(),
        0,
    )
}

#[test]
fn an_unset_row_reads_its_default() {
    let unset = state("{}").get(&Target::Key("appearance.accent".into()));
    let default = unset.row.as_ref().and_then(|row| row.default.clone());
    assert!(default.is_some(), "appearance.accent has a schema default");
    assert_eq!(unset.value, default, "an unset row reads its default, not null");
    assert_eq!(unset.file_value, None);
}

#[test]
fn a_set_row_reads_its_value_and_a_rowless_key_its_stored_value() {
    let set = state(r#"{"appearance": {"accent": "theme"}, "notARow": {"x": 1}}"#);
    let accent = set.get(&Target::Key("appearance.accent".into()));
    assert_eq!(accent.value, Some(json!("theme")));
    assert_eq!(accent.file_value, Some(json!("theme")));
    let rowless = set.get(&Target::Key("notARow.x".into()));
    assert!(rowless.row.is_none());
    assert_eq!(rowless.value, Some(json!(1)));
}
