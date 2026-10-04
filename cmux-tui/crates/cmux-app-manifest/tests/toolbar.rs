//! `contributes.toolbarItems` (app-platform.md 17).

use cmux_app_manifest::{Severity, validate_catalog, validate_manifest};
use serde_json::{Value, json};

fn manifest(extra: Value) -> Value {
    let mut m = json!({ "manifestVersion": 2, "id": "local/x", "name": "X", "version": "1.0.0", "description": "d",
        "engines": { "cmux": "^2.0" }, "icon": "icon.png" });
    for (k, v) in extra.as_object().expect("object") {
        m[k] = v.clone();
    }
    m
}

fn errors(m: &Value) -> Vec<(String, &'static str)> {
    validate_manifest(m)
        .into_iter()
        .filter(|i| i.severity == Severity::Error)
        .map(|i| (i.path, i.code))
        .collect()
}

fn items(list: Value) -> Value {
    json!({ "contributes": { "toolbarItems": list } })
}

#[test]
fn buttons_menus_and_views_validate() {
    let mut m = manifest(items(json!([
        { "id": "compose", "kind": "button", "title": "Compose", "icon": { "symbol": "square.and.pencil" }, "action": { "op": "x.compose" } },
        { "id": "more", "kind": "menu", "title": "More", "items": [{ "title": "Refresh", "action": { "op": "x.refresh" } }] },
        { "id": "meter", "kind": "view", "title": "Usage", "width": 120 },
        { "id": "back", "kind": "button", "title": "Back in Mail", "action": { "op": "x.back" }, "overrides": "nav.back" }
    ])));
    m["runtime"] = json!({ "web": { "root": "web/" } });
    assert_eq!(errors(&m), vec![]);
}

#[test]
fn the_sidebar_toggle_is_fixed_and_overrides_name_built_in_buttons() {
    let m = manifest(items(json!([
        { "id": "a", "kind": "button", "title": "A", "action": { "op": "x.a" }, "overrides": "sidebar.toggle" },
        { "id": "b", "kind": "button", "title": "B", "action": { "op": "x.b" }, "overrides": "tab.close" },
        { "id": "c", "kind": "menu", "title": "C", "items": [{ "title": "C", "action": { "op": "x.c" } }], "overrides": "nav.forward" }
    ])));
    let got: Vec<&str> = errors(&m).into_iter().map(|(_, c)| c).collect();
    assert_eq!(got, vec!["toolbar.toggleFixed", "toolbar.overrideUnknown", "toolbar.overrideKind"]);
}

#[test]
fn schema_limits() {
    // No position field exists, so nothing can go left of the toggle; at most 4 items; views at most 160 pt.
    for bad in [
        items(json!([{ "id": "a", "kind": "button", "title": "A", "action": { "op": "x.a" }, "before": "sidebar.toggle" }])),
        items(json!([{ "id": "v", "kind": "view", "title": "V", "width": 200 }])),
        items(json!([{ "id": "b", "kind": "button", "title": "B" }])),
        items(json!((0..5).map(|i| json!({ "id": format!("i{i}"), "kind": "button", "title": "T", "action": { "op": "x.a" } })).collect::<Vec<_>>())),
    ] {
        assert!(errors(&manifest(bad.clone())).iter().any(|(_, c)| *c == "schema"), "{bad}");
    }
}

#[test]
fn views_need_a_page_and_ids_are_unique() {
    let m = manifest(items(json!([
        { "id": "v", "kind": "view", "title": "V", "width": 80 },
        { "id": "v", "kind": "button", "title": "B", "action": { "op": "x.b" } }
    ])));
    let got: Vec<&str> = errors(&m).into_iter().map(|(_, c)| c).collect();
    assert_eq!(got, vec!["toolbar.viewNeedsWeb", "toolbar.duplicate"]);
}

#[test]
fn actions_on_the_apps_own_family_must_exist_in_its_catalog() {
    let m = manifest(items(
        json!([{ "id": "a", "kind": "button", "title": "A", "action": { "op": "demo.missing" } },
        { "id": "b", "kind": "button", "title": "B", "action": { "op": "workspace.new" } }]),
    ));
    let catalog = json!({ "family": "demo", "operations": [] });
    let got: Vec<(String, &str)> =
        validate_catalog(&m, &catalog).into_iter().map(|i| (i.path, i.code)).collect();
    assert_eq!(
        got,
        vec![("/contributes/toolbarItems/0/action/op".to_string(), "toolbar.unknownOp")]
    );
}
