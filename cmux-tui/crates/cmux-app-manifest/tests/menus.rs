//! `contributes.menus`: rows an app adds to cmux's own right-click menus.

use cmux_app_manifest::{MENU_TARGETS, is_valid, validate_catalog, validate_manifest};
use serde_json::{Value, json};

fn manifest(menus: Value) -> Value {
    json!({ "manifestVersion": 2, "id": "local/branchy", "name": "Branchy", "version": "1.0.0", "description": "d",
            "engines": { "cmux": "^2.0" }, "icon": "assets/icon.png", "contributes": { "menus": menus } })
}

fn catalog() -> Value {
    json!({ "family": "local.branchy", "operations": [{
        "name": "local.branchy.copy_branch", "owner": "app:local/branchy", "class": "read", "risk": "read",
        "idempotency": "forbidden", "input": { "type": "object" }, "docs": "Copies the branch.", "since": "1"
    }] })
}

fn row(id: &str, target: &str, op: &str) -> Value {
    json!({ "id": id, "target": target, "title": "Copy Branch", "op": op, "icon": { "symbol": "arrow.branch" } })
}

fn codes(issues: &[cmux_app_manifest::Issue]) -> Vec<&'static str> {
    issues.iter().map(|i| i.code).collect()
}

#[test]
fn a_row_on_each_menu_is_valid() {
    let m = manifest(json!(
        MENU_TARGETS
            .iter()
            .map(|t| row(&format!("copy-{t}"), t, "local.branchy.copy_branch"))
            .collect::<Vec<_>>()
    ));
    let issues = validate_manifest(&m);
    assert!(is_valid(&issues), "{issues:?}");
    assert!(validate_catalog(&m, &catalog()).is_empty());
}

#[test]
fn an_unknown_menu_is_refused() {
    // Chat-area menus are not offered.
    let issues =
        validate_manifest(&manifest(json!([row("copy", "chat", "local.branchy.copy_branch")])));
    assert!(!is_valid(&issues));
    assert!(issues.iter().any(|i| i.path.starts_with("/contributes/menus/0")), "{issues:?}");
}

#[test]
fn the_schema_offers_exactly_the_menu_targets() {
    let schema: Value = serde_json::from_str(cmux_app_manifest::SCHEMA).expect("schema");
    let targets: Vec<&str> = schema["$defs"]["menuItem"]["properties"]["target"]["enum"]
        .as_array()
        .expect("enum")
        .iter()
        .filter_map(Value::as_str)
        .collect();
    assert_eq!(targets, MENU_TARGETS);
}

#[test]
fn a_row_needs_an_op_of_the_apps_own_catalog() {
    let unknown =
        validate_catalog(&manifest(json!([row("copy", "tab", "local.branchy.nope")])), &catalog());
    assert_eq!(codes(&unknown), vec!["menus.unknownOp"]);
    assert_eq!(unknown[0].path, "/contributes/menus/0/op");
    let foreign =
        validate_catalog(&manifest(json!([row("copy", "tab", "workspace.close")])), &catalog());
    assert_eq!(codes(&foreign), vec!["menus.foreignOp"]);
}

#[test]
fn a_row_id_is_declared_once() {
    let m = manifest(json!([
        row("copy", "tab", "local.branchy.copy_branch"),
        row("copy", "terminal", "local.branchy.copy_branch")
    ]));
    assert!(codes(&validate_manifest(&m)).contains(&"menus.duplicate"));
}

#[test]
fn a_row_without_an_op_is_refused_by_the_schema() {
    let issues =
        validate_manifest(&manifest(json!([{ "id": "copy", "target": "tab", "title": "Copy" }])));
    assert!(!is_valid(&issues), "{issues:?}");
}
