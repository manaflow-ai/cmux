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
