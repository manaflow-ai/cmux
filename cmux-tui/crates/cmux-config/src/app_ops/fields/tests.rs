use serde_json::{Value, json};

use super::call;
use super::context_menus::layout;

fn run(op: &str, request: Value) -> Value {
    call(op, &request).expect("op").expect("ok")
}

fn diag_paths(out: &Value) -> Vec<(String, String)> {
    out["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .map(|d| (d["path"].as_str().unwrap().into(), d["message"].as_str().unwrap().into()))
        .collect()
}

#[test]
fn focus_ring_defaults_and_values() {
    let out = run("fields.focus_ring", json!({"root": {}}));
    assert_eq!(out["values"], json!({}));
    assert_eq!(out["defaults"]["style"], "ring");
    assert_eq!(out["defaults"]["width"], 1);
    assert_eq!(out["defaults"]["cornerRadius"], Value::Null);
    let out = run(
        "fields.focus_ring",
        json!({"root": {"focusRing": {
        "enabled": true, "style": "glow", "color": "#ff0000", "width": 20, "cornerRadius": "pane"}}}),
    );
    assert_eq!(out["values"]["enabled"], true);
    assert_eq!(out["values"]["style"], "glow");
    assert_eq!(out["values"]["width"], 8.0);
    assert_eq!(out["values"]["color"]["red"], 1.0);
    assert!(out["values"]["cornerRadius"].is_null() && out["values"].get("cornerRadius").is_some());
    assert_eq!(diag_paths(&out), vec![("focusRing.width".into(), "clamped to 0.5...8.0".into())]);
}

#[test]
fn focus_ring_bad_values() {
    let out = run(
        "fields.focus_ring",
        json!({"root": {"focusRing": {
        "style": "x", "color": 3, "enabled": "yes", "cornerRadius": 30}}}),
    );
    assert_eq!(out["values"]["cornerRadius"], 24.0);
    assert_eq!(
        diag_paths(&out),
        vec![
            ("focusRing.enabled".into(), "expected true or false".into()),
            ("focusRing.style".into(), "expected one of \"ring\", \"glow\", \"none\"".into()),
            ("focusRing.color".into(), "expected a #RRGGBB color".into()),
            ("focusRing.cornerRadius".into(), "clamped to 0.0...24.0".into()),
        ]
    );
}

#[test]
fn focus_ring_not_an_object() {
    let out = run("fields.focus_ring", json!({"root": {"focusRing": 3}}));
    assert_eq!(diag_paths(&out), vec![("focusRing".into(), "expected an object".into())]);
}

#[test]
fn attention_rounds_counts_and_orders_choices() {
    let out = run(
        "fields.attention",
        json!({"root": {"notifications": {"attention": {
        "blinkCount": 2.5, "style": "nope", "mark": "glow", "duration": 100, "color": null}}}}),
    );
    assert_eq!(out["values"]["blinkCount"], 3);
    assert_eq!(out["values"]["mark"], "glow");
    assert!(out["values"]["color"].is_null());
    assert_eq!(
        diag_paths(&out),
        vec![
            (
                "notifications.attention.style".into(),
                "expected one of \"none\", \"steady\", \"pulse\", \"blink\"".into()
            ),
            ("notifications.attention.duration".into(), "clamped to 0.3...30.0".into()),
        ]
    );
    assert_eq!(out["defaults"]["style"], "steady");
}

#[test]
fn status_indicator_debug_sets_and_honor_list() {
    let out = run(
        "fields.status_indicator",
        json!({"root": {"appearance": {"statusIndicator": {
        "iconSet": "stillDots", "honorStatusStyle": ["agent", "run"], "size": 9, "style": "dot"}}}}),
    );
    assert!(out["values"].get("iconSet").is_none());
    assert_eq!(out["values"]["honorStatusStyle"], json!(["run", "agent"]));
    assert_eq!(out["values"]["style"], "dot");
    assert_eq!(out["values"]["size"], 1.5);
    // Direct diagnostics first, then the reader's.
    assert_eq!(
        diag_paths(&out),
        vec![
            (
                "appearance.statusIndicator.iconSet".into(),
                "\"stillDots\" is a Debug Settings set".into()
            ),
            ("appearance.statusIndicator.size".into(), "clamped to 0.5...1.5".into()),
        ]
    );
    assert_eq!(out["defaults"]["honorStatusStyle"].as_array().unwrap().len(), 7);
    let out = run(
        "fields.status_indicator",
        json!({"root": {"appearance": {"statusIndicator": {
        "honorStatusStyle": ["nope"], "iconSet": "pips"}}}}),
    );
    assert_eq!(out["values"]["iconSet"], "pips");
    assert_eq!(diag_paths(&out)[0].1, "expected true, false or a list of sources");
    let out = run(
        "fields.status_indicator",
        json!({"root": {"appearance": {"statusIndicator": {"honorStatusStyle": false}}}}),
    );
    assert_eq!(out["values"]["honorStatusStyle"], json!([]));
}

#[test]
fn status_behavior_ranges() {
    let out = run(
        "fields.status_behavior",
        json!({"root": {"status": {
        "inferCommandBusyAfter": 9999, "runNotifyMinimumSeconds": -1, "inferCommandBusy": true}}}),
    );
    assert_eq!(out["values"]["inferCommandBusyAfter"], 600.0);
    assert_eq!(out["values"]["runNotifyMinimumSeconds"], 0.0);
    assert_eq!(diag_paths(&out)[0].1, "clamped to 0.0...600.0");
    assert_eq!(out["defaults"]["inferCommandBusyAfter"], 3);
}

#[test]
fn column_layout_resolves_and_refuses() {
    let out = run("fields.column_layout", json!({"root": {}}));
    assert_eq!(out["values"]["splitSizing"], "even");
    assert_eq!(out["values"]["minimumPaneWidth"], 200);
    assert_eq!(out["values"]["rows"], true);
    assert_eq!(out["values"]["newColumnWidth"], json!({"mode": "fixed", "fixed": null}));
    let out = run(
        "fields.column_layout",
        json!({"root": {"layout": {
        "newColumnWidth": 0.5, "stickyColumnEdge": "left", "dockColumnMode": "floating",
        "minimumPaneWidth": 5, "rows": "x", "splitSizing": "z"}}}),
    );
    assert_eq!(out["values"]["newColumnWidth"], json!({"mode": "fixed", "fixed": 0.5}));
    assert_eq!(out["values"]["dockColumnEdge"], "left");
    assert_eq!(out["values"]["dockColumnMode"], "overlay");
    assert_eq!(out["values"]["minimumPaneWidth"], 200);
    let paths: Vec<String> = diag_paths(&out).into_iter().map(|d| d.1).collect();
    assert_eq!(
        paths,
        vec![
            "expected one of \"even\", \"halve\"",
            "expected points from 80 to 800",
            "expected true or false"
        ]
    );
    let out = run("fields.column_layout", json!({"root": {"layout": {"newColumnWidth": 5}}}));
    assert_eq!(out["values"]["newColumnWidth"]["mode"], "fixed");
    assert_eq!(diag_paths(&out)[0].0, "layout.newColumnWidth");
}

#[test]
fn context_menu_layouts() {
    let tree = layout(&json!({"items": ["a", "-", {"key": "group:1", "title": "G", "items": ["b"]}], "hidden": ["c"]})).unwrap();
    assert_eq!(tree["items"][2], json!({"key": "group:1", "items": ["b"], "title": "G"}));
    assert_eq!(tree["hidden"], json!(["c"]));
    // A group needs a title; a non-string item is refused.
    assert!(layout(&json!({"items": [{"key": "group:1", "items": []}]})).is_none());
    assert!(layout(&json!({"items": [3]})).is_none());
    assert!(layout(&json!({"items": [], "hidden": null})).is_none());
    assert!(layout(&json!(3)).is_none());
    // Too deep.
    let mut deep = json!([]);
    for _ in 0..10 {
        deep = json!([{"key": "folder:x", "items": deep}]);
    }
    assert!(layout(&json!({"items": deep})).is_none());
    // The first shape: top and more.
    let old = layout(&json!({"top": ["a", "-", "folder:new"], "more": ["z"]})).unwrap();
    assert_eq!(old["items"][3], json!("-"));
    assert_eq!(old["items"][4], json!({"key": "folder:more", "items": ["z", "-"]}));
    let old = layout(&json!({"top": ["a", "folder:more"], "more": ["z"]})).unwrap();
    assert_eq!(old["items"][1], json!({"key": "folder:more", "items": ["z", "-"]}));
}

#[test]
fn context_menus_op() {
    let out = run(
        "fields.context_menus",
        json!({"contexts": ["tab", "pane"], "root": {"contextMenus": {
        "showCustomizeItem": 1, "layouts": {"tab": {"items": ["a"]}, "nope": {"items": []}, "pane": 5}}}}),
    );
    assert_eq!(out["showCustomizeItem"], false);
    assert_eq!(out["layouts"]["tab"]["items"], json!(["a"]));
    let paths: Vec<String> = diag_paths(&out).into_iter().map(|d| d.0).collect();
    assert_eq!(
        paths,
        vec![
            "contextMenus.showCustomizeItem",
            "contextMenus.layouts.nope",
            "contextMenus.layouts.pane"
        ]
    );
}
