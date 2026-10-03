//! Conformance with Swift `SettingDescriptor.accepts`: every row's exported
//! `accepts` samples are accepted and every `refuses` sample is refused, so
//! the Rust validator agrees with Swift on every row.

use std::collections::BTreeSet;

use cmux_config::domains::Domains;
use cmux_config::schema::{
    Kind, Schema, Validation, accepts, is_hex_color, new_tab_page_url_is_valid,
};
use serde_json::json;

#[test]
fn every_row_accepts_and_refuses_the_swift_samples() {
    let schema = Schema::embedded();
    assert!(schema.rows.len() >= 78, "schema lost rows");
    let domains = Domains::default();
    let mut checked = 0;
    for row in &schema.rows {
        for sample in &row.accepts {
            assert!(
                accepts(row, sample, &domains).is_ok(),
                "{} refused accepted sample {sample}",
                row.key
            );
            checked += 1;
        }
        for sample in &row.refuses {
            let refusal = accepts(row, sample, &domains)
                .expect_err(&format!("{} accepted refused sample {sample}", row.key));
            assert_eq!(refusal.code(), "invalid_params", "{}", row.key);
            checked += 1;
        }
        if let Some(default) = &row.default {
            assert!(
                accepts(row, default, &domains).is_ok(),
                "{} refuses its default {default}",
                row.key
            );
        }
    }
    assert!(checked > 300, "too few samples checked: {checked}");
}

#[test]
fn lookups_by_key_and_path_agree() {
    let schema = Schema::embedded();
    for row in &schema.rows {
        assert_eq!(schema.row(&row.key).map(|r| &r.key), Some(&row.key));
        assert_eq!(schema.row_at(&row.path).map(|r| &r.key), Some(&row.key));
        assert_eq!(row.path.join("."), row.key);
    }
    assert_eq!(schema.schema_hash.len(), 64);
    assert!(schema.rows_in(Some("browser")).all(|row| row.section == "browser"));
}

#[test]
fn domain_kinds_check_the_published_domain() {
    let schema = Schema::embedded();
    let row_of = |kind: &str| schema.rows.iter().find(|row| row.kind.name() == kind).expect(kind);
    let theme = row_of("theme");
    let font = row_of("font_family");
    let sound = row_of("sound");
    assert!(matches!(theme.validation, Validation::Domain(_)));
    let none = Domains::default();
    // Shape only while no domain is published.
    assert!(accepts(theme, &json!("Anything Goes"), &none).is_ok());
    assert!(accepts(theme, &json!("light:A,dark:B"), &none).is_ok());
    assert!(accepts(theme, &json!(""), &none).is_err());
    assert!(accepts(theme, &json!("a=b"), &none).is_err());
    assert!(accepts(theme, &json!("A,B"), &none).is_err());
    assert!(accepts(font, &json!("Menlo"), &none).is_ok());
    assert!(accepts(font, &json!("  "), &none).is_err());
    assert!(accepts(sound, &json!("Glass"), &none).is_ok());

    let published = Domains::published(
        vec!["Nord".into(), "Rose Pine".into(), "Rose Pine Dawn".into()],
        vec!["Menlo".into()],
        vec!["Glass".into()],
    );
    assert!(accepts(theme, &json!("Nord"), &published).is_ok());
    assert!(accepts(theme, &json!("light:Rose Pine Dawn,dark:Rose Pine"), &published).is_ok());
    assert!(accepts(theme, &json!("light:Rose Pine Dawn,dark:Dracula"), &published).is_err());
    assert!(accepts(font, &json!(" Menlo "), &published).is_ok());
    assert!(accepts(font, &json!("Monaco"), &published).is_err());
    assert!(accepts(sound, &json!("default"), &published).is_ok());
    assert!(accepts(sound, &json!("none"), &published).is_ok());
    assert!(accepts(sound, &json!("Basso"), &published).is_err());
    let refusal = accepts(sound, &json!("Basso"), &published).unwrap_err();
    assert_eq!(refusal.data()["accepted"]["values"], json!(["Glass"]));
}

#[test]
fn portable_rules_match_swift_edge_cases() {
    assert!(is_hex_color("#a1B2c3"));
    assert!(is_hex_color("a1b2c3d4"));
    assert!(!is_hex_color("##a1b2c3"));
    assert!(!is_hex_color("#a1b2c"));
    assert!(new_tab_page_url_is_valid("HTTPS://cmux.com"));
    assert!(new_tab_page_url_is_valid("127.0.0.1:8080"));
    assert!(!new_tab_page_url_is_valid("localhost:3000"));
    assert!(!new_tab_page_url_is_valid("/tmp/a.html"));
    assert!(!new_tab_page_url_is_valid("mailto:a@b.c"));
    let schema = Schema::embedded();
    let quiet = schema.rows.iter().find(|row| row.kind == Kind::TimeRange).unwrap();
    let none = Domains::default();
    assert!(accepts(quiet, &json!({"start": "22::00", "end": "+7:05"}), &none).is_ok());
    assert!(accepts(quiet, &json!({"start": "24:00", "end": "07:00"}), &none).is_err());
    let invalid = accepts(quiet, &json!("x"), &none).unwrap_err();
    assert_eq!(invalid.to_string(), format!("{} does not accept \"x\"", quiet.key));
}

#[test]
fn agent_policy_and_reset_flags_come_from_the_export() {
    let schema = Schema::embedded();
    let refused: BTreeSet<&str> =
        schema.rows.iter().filter(|row| !row.agent_settable).map(|row| row.key.as_str()).collect();
    assert!(refused.contains("history.terminalCommands"));
    for row in schema.rows.iter().filter(|row| !row.agent_settable) {
        assert!(row.agent_refusal.is_some(), "{} has no refusal reason", row.key);
    }
    let kept: BTreeSet<&str> = schema
        .rows
        .iter()
        .filter(|row| row.kept_on_reset_all)
        .map(|row| row.key.as_str())
        .collect();
    assert!(kept.contains("appearance.theme"));
    assert!(kept.contains("terminal.fontFamily"));
}

#[test]
fn sound_accepts_any_string_until_a_domain_is_published() {
    let schema = Schema::embedded();
    let sound = schema.rows.iter().find(|row| row.kind.name() == "sound").unwrap();
    let none = Domains::default();
    assert!(accepts(sound, &json!(""), &none).is_ok(), "Swift accepts any string");
    assert!(accepts(sound, &json!("Glass"), &none).is_ok());
    assert!(accepts(sound, &json!(1), &none).is_err());
}
