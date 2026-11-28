use super::*;

#[test]
fn workspace_color_indicator_accepts_swift_legacy_values() {
    let row = super::super::Schema::embedded()
        .row("workspaceColors.indicatorStyle")
        .expect("workspace color indicator row");
    for value in [
        "solidFill",
        "rail",
        "border",
        "wash",
        "lift",
        "typography",
        "washRail",
        "blueWashColorRail",
    ] {
        assert!(
            accepts(row, &Value::String(value.to_owned()), &Default::default()).is_ok(),
            "{value}"
        );
    }
    assert!(
        accepts(row, &Value::String("__not_a_choice__".to_owned()), &Default::default()).is_err()
    );
}

#[test]
fn profile_menu_style_takes_app_or_account_and_defaults_to_app() {
    // ask-aad661801e: the Claude Code and Codex looks set the account-first profile menu;
    // cmux's own app menu stays the default.
    let row = super::super::Schema::embedded()
        .row("sidebar.profileMenu.style")
        .expect("profile menu style row");
    assert_eq!(row.default, Some(json!("app")));
    let domains = Domains::default();
    for value in ["app", "account"] {
        assert!(accepts(row, &json!(value), &domains).is_ok(), "{value}");
    }
    for value in [json!("accounts"), json!(""), json!(true), json!(1)] {
        assert!(accepts(row, &value, &domains).is_err(), "{value}");
    }
}

#[test]
fn app_font_takes_any_family_not_only_the_fixed_pitch_domain() {
    let row = super::super::Schema::embedded().row("appearance.appFont").expect("app font row");
    assert_eq!(row.validation, super::super::Validation::Domain(DomainKind::UiFontFamily));
    let mono = Domains::published(Vec::new(), vec!["Menlo".to_owned()], Vec::new());
    assert!(accepts(row, &json!("Avenir Next"), &mono).is_ok());
    assert!(accepts(row, &json!("Bad#Name"), &mono).is_err());
    assert!(accepts(row, &json!(3), &mono).is_err());
}
