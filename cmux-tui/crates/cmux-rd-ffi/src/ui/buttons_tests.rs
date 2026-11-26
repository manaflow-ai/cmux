//! Parity with `MacScreenButton`, `MacScreenMenuButton` and `MacScreenSwitch`.

use serde_json::json;

use super::*;

fn call(op: &str, args: Value) -> Value {
    handle(op, &args).expect("known op").expect("ok")
}

fn space(kind: &str, compact: bool, w: f64, h: f64) -> Value {
    json!({"kind": kind, "compact": compact, "space1": 4.0, "space3": 12.0, "space4": 16.0, "space6": 24.0,
           "contentWidth": w, "contentHeight": h})
}

#[test]
fn sizes() {
    let plain = call("metrics", space("plain", false, 40.2, 16.0));
    assert_eq!(
        plain,
        json!({"horizontalPadding": 16.0, "minHeight": 26.0, "width": 73.0, "height": 26.0, "emphasized": false})
    );
    let compact = call("metrics", space("primary", true, 40.0, 30.5));
    assert_eq!(compact["width"], 64.0);
    assert_eq!(compact["height"], 31.0);
    assert_eq!(compact["emphasized"], true);
    let icon = call("metrics", space("icon", false, 12.0, 12.0));
    assert_eq!((icon["width"].as_f64(), icon["minHeight"].as_f64()), (Some(24.0), Some(22.0)));
    assert_eq!(call("metrics", space("icon", false, 20.0, 12.0))["width"], 28.0);
}

fn st(kind: &str, enabled: bool, hovering: bool, pressed: bool) -> Value {
    call(
        "style",
        json!({"kind": kind, "enabled": enabled, "hovering": hovering, "pressed": pressed}),
    )
}

#[test]
fn styles() {
    assert_eq!(
        st("primary", true, false, false),
        json!({"foreground": "onAccent", "fill": {"color": "accent", "alpha": 1.0}, "alpha": 1.0})
    );
    assert_eq!(st("primary", true, true, false)["fill"]["alpha"], 0.9);
    assert_eq!(st("primary", true, true, true)["fill"]["alpha"], 0.75);
    assert_eq!(st("destructive", false, false, false)["foreground"], "danger");
    assert_eq!(st("destructive", false, false, false)["alpha"], 0.45);
    assert_eq!(st("plain", true, false, false)["fill"]["color"], "hover");
    assert_eq!(st("plain", true, true, false)["fill"]["color"], "selection");
    assert_eq!(st("plain", true, true, true)["fill"]["color"], "pressed");
    assert_eq!(st("icon", true, false, false)["foreground"], "secondary");
    assert_eq!(st("icon", true, false, false)["fill"]["color"], "clear");
    assert_eq!(st("icon", true, true, false)["foreground"], "primary");
    assert_eq!(st("icon", true, true, false)["fill"]["color"], "hover");
    assert_eq!(st("icon", false, true, false)["fill"]["color"], "clear");
    assert_eq!(st("icon", false, true, true)["fill"]["color"], "pressed");
}

#[test]
fn kern_focus_and_menu_titles() {
    assert_eq!(call("hintKern", json!({"space2": 8.0, "spaceWidth": 3.5})), 4.5);
    assert_eq!(call("hintKern", json!({"space2": 2.0, "spaceWidth": 3.5})), 0.0);
    let focus = |e: bool, t: bool, f: bool| {
        call("takesFocus", json!({"enabled": e, "takesKeyFocus": t, "fullKeyboardAccess": f}))
    };
    assert_eq!(focus(true, true, false), true);
    assert_eq!(focus(true, false, true), true);
    assert_eq!(focus(true, false, false), false);
    assert_eq!(focus(false, true, true), false);
    assert_eq!(
        call("menuTitle", json!({"label": "A", "title": "B"})),
        json!({"retitle": true, "hasTitle": true})
    );
    assert_eq!(
        call("menuTitle", json!({"label": "A", "title": "A"})),
        json!({"retitle": false, "hasTitle": true})
    );
    assert_eq!(
        call("menuTitle", json!({"label": null, "title": "B"})),
        json!({"retitle": false, "hasTitle": false})
    );
    assert_eq!(
        call("menuTitle", json!({"label": "A", "title": ""})),
        json!({"retitle": true, "hasTitle": false})
    );
}

#[test]
fn switch_knob_matches_the_system_switch() {
    // 32 × 20 in a 54 × 24 track.
    let on = switch_knob(&SwitchArgs { width: 54.0, height: 24.0, on: true, dark: true });
    assert_eq!((on.x, on.y, on.width, on.height), (20.0, 2.0, 32.0, 20.0));
    assert_eq!((on.track, on.track_border_width, on.knob_white), ("focus", 0.0, None));
    let off = switch_knob(&SwitchArgs { width: 54.0, height: 24.0, on: false, dark: true });
    assert_eq!(
        (off.x, off.track, off.track_alpha, off.track_border_width),
        (2.0, "primary", 0.1, 0.5)
    );
    assert_eq!(off.knob_white, Some(0.886));
    assert_eq!(
        switch_knob(&SwitchArgs { width: 54.0, height: 24.0, on: false, dark: false }).knob_white,
        None
    );
    // A narrow track caps the knob.
    assert_eq!(
        switch_knob(&SwitchArgs { width: 20.0, height: 24.0, on: false, dark: false }).width,
        16.0
    );
}

#[test]
fn unknown_op() {
    assert!(handle("nope", &json!({})).is_none());
}
