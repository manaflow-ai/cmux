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
fn app_font_takes_any_family_not_only_the_fixed_pitch_domain() {
    let row = super::super::Schema::embedded().row("appearance.appFont").expect("app font row");
    assert_eq!(row.validation, super::super::Validation::Domain(DomainKind::UiFontFamily));
    let mono = Domains::published(Vec::new(), vec!["Menlo".to_owned()], Vec::new());
    assert!(accepts(row, &json!("Avenir Next"), &mono).is_ok());
    assert!(accepts(row, &json!("Bad#Name"), &mono).is_err());
    assert!(accepts(row, &json!(3), &mono).is_err());
}
