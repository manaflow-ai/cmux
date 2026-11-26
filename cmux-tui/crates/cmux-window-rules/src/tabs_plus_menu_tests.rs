use super::*;
use serde_json::json;

#[test]
fn plus_menu_keeps_default_and_rejects_invalid_lists() {
    for value in [
        Value::Null,
        json!([]),
        json!(false),
        json!("terminal"),
        json!(["typo"]),
        json!(["terminal", 1]),
        json!(["host", "host"]),
        json!(["terminal", "localWorkspace", "terminal"]),
    ] {
        assert!(rows(&value).is_empty(), "{value}");
    }
}

#[test]
fn plus_menu_preserves_order_and_destinations() {
    let rows = rows(&json!(["host", "machineWorkspace", "localWorkspace", "terminal"]));
    assert_eq!(
        rows,
        [
            row("remote.connect", true, false),
            row("workspace.newOnMachine", false, false),
            row("workspace.newOnMachine", false, true),
            row("newSurface", true, false),
        ]
    );
    assert_eq!(super::rows(&json!(["terminal"])).len(), 1);
}

#[test]
fn plus_menu_rows_encode_for_the_app() {
    let encoded = serde_json::to_value(rows(&json!(["localWorkspace"]))).unwrap();
    assert_eq!(
        encoded,
        json!([{ "action": "workspace.newOnMachine", "paneTarget": false, "localWorkspace": true }])
    );
}
