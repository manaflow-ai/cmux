//! Parity with `MacScreenPaneTests` (input gate) and the pane's layout and phase rules.

use serde_json::json;

use super::*;

fn call(op: &str, args: Value) -> Value {
    handle(op, &args).expect("known op").expect("ok")
}

#[test]
fn takes_input_only_open_with_no_card() {
    assert_eq!(call("takesInput", json!({"gate": "open", "hasCard": false})), true);
    assert_eq!(call("takesInput", json!({"gate": "open", "hasCard": true})), false);
    assert_eq!(call("takesInput", json!({"gate": "unsupported", "hasCard": false})), false);
    assert_eq!(
        call("takesInput", json!({"gate": "open", "hasCard": false, "viewOnly": true})),
        false
    );
}

#[test]
fn toolbar_and_screen_frames() {
    assert_eq!(
        call("toolbarFrame", json!({"placement": "topBar", "width": 800.0})),
        json!({"x": 0.0, "y": 0.0, "width": 800.0, "height": 0.0})
    );
    let floating = call(
        "toolbarFrame",
        json!({"placement": "floating", "width": 800.0, "inset": 12.0, "floatingWidth": 500.0}),
    );
    assert_eq!(floating, json!({"x": 150.0, "y": 12.0, "width": 500.0, "height": 0.0}));
    let narrow = call(
        "toolbarFrame",
        json!({"placement": "floating", "width": 300.0, "inset": 12.0, "floatingWidth": 500.0}),
    );
    assert_eq!(narrow["width"], 276.0);
    assert_eq!(
        call(
            "toolbarFrame",
            json!({"placement": "floating", "width": 10.0, "inset": 12.0, "floatingWidth": 500.0})
        )["width"],
        0.0
    );
    assert_eq!(
        call(
            "screenRect",
            json!({"placement": "topBar", "width": 800.0, "height": 600.0, "toolbarHeight": 40.0})
        ),
        json!({"x": 0.0, "y": 40.0, "width": 800.0, "height": 560.0})
    );
    assert_eq!(
        call(
            "screenRect",
            json!({"placement": "floating", "width": 800.0, "height": 600.0, "toolbarHeight": 40.0})
        )["y"],
        0.0
    );
    assert_eq!(
        call(
            "screenRect",
            json!({"placement": "topBar", "width": 800.0, "height": 20.0, "toolbarHeight": 40.0})
        )["height"],
        0.0
    );
}

fn layout_args() -> Value {
    json!({"screen": {"x": 0.0, "y": 40.0, "width": 801.0, "height": 561.0}, "scale": 2.0, "paneWidthPixels": 100,
           "pictureShadow": true, "videoEmpty": false, "stripShowsCard": true, "quietOutage": false, "gate": "open",
           "cardVeilOpacity": 0.4, "cardWidth": 300.0, "cardHeight": 120.0})
}

#[test]
fn layout_card_veil_and_pixels() {
    let l = call("layout", layout_args());
    assert_eq!(l["paneWidthPixels"], 1602);
    assert_eq!(l["cardHidden"], false);
    // Centre (400.5, 320.5): x 250.5 → 250 and 301 wide; y 260.5 → 260 and 121 tall.
    assert_eq!(l["card"], json!({"x": 250.0, "y": 260.0, "width": 301.0, "height": 121.0}));
    assert_eq!(
        (
            l["veilHidden"].as_bool(),
            l["pictureShadowHidden"].as_bool(),
            l["captureHidden"].as_bool()
        ),
        (Some(false), Some(false), Some(false))
    );

    let mut quiet = layout_args();
    quiet["quietOutage"] = json!(true);
    quiet["paneWidthPixels"] = json!(1602);
    let q = call("layout", quiet);
    assert!(q.get("card").is_none() && q.get("paneWidthPixels").is_none());
    assert_eq!((q["cardHidden"].as_bool(), q["veilHidden"].as_bool()), (Some(true), Some(true)));

    let mut empty = layout_args();
    empty["videoEmpty"] = json!(true);
    empty["gate"] = json!("unsupported");
    empty["paneWidthPixels"] = json!(null);
    let e = call("layout", empty);
    assert_eq!(
        (
            e["veilHidden"].as_bool(),
            e["pictureShadowHidden"].as_bool(),
            e["captureHidden"].as_bool()
        ),
        (Some(true), Some(true), Some(true))
    );
    assert!(e.get("paneWidthPixels").is_none());
}

#[test]
fn phase_effects() {
    let p = |phase: &str, streaming: bool| {
        call("phaseChange", json!({"phase": phase, "hubStreaming": streaming}))
    };
    assert_eq!(
        p("connected", true),
        json!({"everConnected": true, "clearFrame": false, "stopRecording": false, "hubStreamFailed": false})
    );
    assert_eq!(
        p("connecting", true),
        json!({"everConnected": false, "clearFrame": true, "stopRecording": false, "hubStreamFailed": false})
    );
    assert_eq!(p("failed", true)["hubStreamFailed"], true);
    assert_eq!(p("failed", false)["hubStreamFailed"], false);
    assert_eq!(p("ended", true)["stopRecording"], true);
}

#[test]
fn refresh_relay_start_close() {
    assert_eq!(
        call("displayRefresh", json!({"fps": 120, "hasSession": true, "sessionFps": 60})),
        120
    );
    assert_eq!(
        call("displayRefresh", json!({"fps": 120, "hasSession": true, "sessionFps": null})),
        120
    );
    assert_eq!(
        call("displayRefresh", json!({"fps": 120, "hasSession": true, "sessionFps": 120})),
        Value::Null
    );
    assert_eq!(
        call("displayRefresh", json!({"fps": 0, "hasSession": true, "sessionFps": 60})),
        Value::Null
    );
    assert_eq!(call("displayRefresh", json!({"fps": null, "hasSession": true})), Value::Null);
    assert_eq!(call("displayRefresh", json!({"fps": 120, "hasSession": false})), Value::Null);
    assert_eq!(
        call("relayOnly", json!({"on": true, "sessionRelayOnly": false, "hubStreaming": true})),
        json!({"set": true, "rerequest": true})
    );
    assert_eq!(
        call("relayOnly", json!({"on": true, "sessionRelayOnly": true, "hubStreaming": true})),
        json!({"set": false, "rerequest": false})
    );
    assert_eq!(call("relayOnly", json!({"on": true, "hubStreaming": true}))["set"], false);
    assert_eq!(call("start", json!({"hubPhase": "idle", "resumeScope": "view"})), "view");
    assert_eq!(call("start", json!({"hubPhase": "streaming", "resumeScope": "view"})), Value::Null);
    assert_eq!(call("start", json!({"hubPhase": "idle"})), Value::Null);
    assert_eq!(call("close", json!({"hubPhase": "streaming"})), "hub");
    assert_eq!(call("close", json!({"hubPhase": "idle"})), "session");
    assert_eq!(call("close", json!({})), "session");
}

#[test]
fn unknown_op() {
    assert!(handle("nope", &json!({})).is_none());
}
