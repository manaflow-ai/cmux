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

// ---- Part 3: pins that read the schema ----

use super::reader::{choices_of, range_of};

fn strs(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

#[test]
fn hardcoded_choice_orders_match_the_schema() {
    let focus = ["ring", "glow", "none"];
    let pins: Vec<(&str, Vec<String>)> = vec![
        ("focusRing.style", strs(&focus)),
        ("focusRing.contrast", strs(&["subtle", "standard", "strong"])),
        ("notifications.attention.style", strs(&["none", "steady", "pulse", "blink"])),
        ("notifications.attention.terminals", strs(&focus)),
        ("notifications.attention.agentChats", strs(&focus)),
        ("notifications.attention.mark", strs(&["badge", "glow"])),
        ("appearance.statusIndicator.style", strs(&["arc", "native", "dot", "braille", "none"])),
        ("appearance.statusIndicator.animation", strs(&["animated", "static"])),
        ("layout.splitSizing", strs(&["even", "halve"])),
        ("layout.dockColumnEdge", strs(&["nearest", "left", "right", "top", "bottom"])),
        ("layout.dockColumnMode", strs(&["docked", "overlay"])),
        ("layout.frameOrientation", strs(&["columnMajor", "rowMajor"])),
        ("layout.scrollModifier", strs(&["command", "none"])),
    ];
    // The pinned order is the one Swift's `allCases` prints in `expected one of`; the schema may list
    // the same values in another order (attention.style does), so the values are what must agree.
    for (key, expected) in pins {
        let mut schema = choices_of(key);
        let mut pinned = expected;
        schema.sort();
        pinned.sort();
        assert_eq!(schema, pinned, "{key}");
    }
}

#[test]
fn attention_ranges_match_the_schema() {
    for (key, range) in [
        ("notifications.attention.width", (0.5, 8.0)),
        ("notifications.attention.blinkCount", (1.0, 10.0)),
        ("notifications.attention.agentChatBlinkCount", (1.0, 10.0)),
        ("notifications.attention.duration", (0.3, 30.0)),
    ] {
        assert_eq!(range_of(key), range, "{key}");
    }
}

fn sections(root: Value) -> Value {
    run("fields.sidebar_sections", json!({"root": root}))
}

#[test]
fn sidebar_sections_defaults_and_bad_values() {
    let out = sections(json!({}));
    assert_eq!(out["diagnostics"], json!([]));
    assert_eq!(out["values"]["sidebar.stepping"], super::reader::default_of("sidebar.stepping"));
    assert!(out["values"]["sidebar.showAgentSessions"].is_boolean());
    let out = sections(json!({"sidebar": {
        "sectionLook": "nope", "topBandMaxShare": 5, "steppingWraps": "yes", "density": 3}}));
    let diags = diag_paths(&out);
    let paths: Vec<&str> = diags.iter().map(|d| d.0.as_str()).collect();
    assert_eq!(
        paths,
        [
            "sidebar.sectionLook",
            "sidebar.topBandMaxShare",
            "sidebar.steppingWraps",
            "sidebar.density"
        ]
    );
    assert!(diags[0].1.starts_with("expected one of \""));
    assert_eq!(
        out["values"]["sidebar.topBandMaxShare"],
        super::reader::default_of("sidebar.topBandMaxShare")
    );
}

#[test]
fn sidebar_share_scaling_and_legacy_key() {
    let out = sections(json!({"sidebar": {
        "topBandMaxShare": 0.6, "bottomBandMaxShare": 0.6, "stickyBandsScroll": true}}));
    let top = out["values"]["sidebar.topBandMaxShare"].as_f64().unwrap();
    let bottom = out["values"]["sidebar.bottomBandMaxShare"].as_f64().unwrap();
    assert!((top + bottom - 0.8).abs() < 1e-9);
    assert_eq!(out["values"]["sidebar.pinnedBandsScroll"], true);
    // The new key wins over the old.
    let out = sections(json!({"sidebar": {"pinnedBandsScroll": false, "stickyBandsScroll": true}}));
    assert_eq!(out["values"]["sidebar.pinnedBandsScroll"], false);
}

#[test]
fn indicator_style_aliases() {
    let get = |v: &str| {
        sections(json!({"workspaceColors": {"indicatorStyle": v}}))["values"]["workspaceColors.indicatorStyle"].clone()
    };
    assert_eq!(get("solidFill"), "fill");
    assert_eq!(get("wash"), "leftRail");
    let out = sections(json!({"workspaceColors": {"indicatorStyle": "zzz"}}));
    assert_eq!(diag_paths(&out)[0].0, "workspaceColors.indicatorStyle");
}

#[test]
fn workspace_row_parse() {
    let out = run("fields.workspace_row", json!({"root": {}}));
    assert_eq!(out["diagnostics"], json!([]));
    assert_eq!(out["values"]["overrides"], json!({}));
    let out = run(
        "fields.workspace_row",
        json!({"root": {"sidebar": {
        "showWorkspaceDirectory": false,
        "workspaceRow": {
            "branch": false, "log": true, "process": "x",
            "agent": {"branch": true, "secondLineOrder": ["branch", "nope"]},
            "terminal": {"icon": false},
            "statusPlacement": "bogus"
        }}}}),
    );
    let shown = out["values"]["shown"].as_array().unwrap();
    assert!(!shown.contains(&json!("directory")) && !shown.contains(&json!("branch")));
    assert!(shown.contains(&json!("log")));
    assert_eq!(out["values"]["overrides"]["terminal"], json!({"elements": {"icon": false}}));
    assert_eq!(out["values"]["overrides"]["agent"], json!({"elements": {"branch": true}}));
    let paths: Vec<String> = diag_paths(&out).into_iter().map(|d| d.0).collect();
    assert_eq!(
        paths,
        [
            "sidebar.workspaceRow.process",
            "sidebar.workspaceRow.agent.secondLineOrder",
            "sidebar.workspaceRow.statusPlacement"
        ]
    );
}

#[test]
fn sidebar_border_surface_look() {
    let out = run("fields.sidebar_border", json!({"root": {}}));
    assert!(out["values"]["width"].is_null());
    let out = run(
        "fields.sidebar_border",
        json!({"root": {"sidebar": {"border": 1, "borderWidth": 99}}, "defaultShows": true}),
    );
    assert_eq!(out["values"]["shows"], true);
    assert_eq!(out["values"]["width"], range_of("sidebar.borderWidth").1);
    assert_eq!(diag_paths(&out).len(), 2);
    let out =
        run("fields.sidebar_surface", json!({"root": {"appearance": {"sidebarSurface": "nope"}}}));
    assert!(out["value"].is_null());
    assert_eq!(diag_paths(&out).len(), 1);
    let out = run("fields.sidebar_look", json!({"root": {}}));
    assert!(out.get("look").is_some());
}

#[test]
fn toolbar_buttons() {
    let pane = |v: Value| {
        run("fields.pane_toolbar_buttons", json!({"root": {"tabs": {"toolbarButtons": v}}}))
    };
    let known = choices_of("tabs.toolbarButtons");
    let (a, b) = (known[0].clone(), known[1].clone());
    let out = pane(json!([b, a, b, "zzz"]));
    assert_eq!(out["pinned"], json!([b, a]));
    assert_eq!(diag_paths(&out).len(), 2);
    let out = pane(json!("x"));
    assert_eq!(diag_paths(&out).len(), 1);
    let out = run("fields.pane_toolbar_buttons", json!({"root": {}}));
    assert!(out["pinned"].is_array());
    let bknown = choices_of("browser.toolbarButtons");
    let out = run(
        "fields.browser_toolbar_buttons",
        json!({"root": {"browser": {"toolbarButtons": [bknown[1], bknown[0]]}}}),
    );
    assert_eq!(out["pinned"], json!([bknown[0], bknown[1]]));
}
