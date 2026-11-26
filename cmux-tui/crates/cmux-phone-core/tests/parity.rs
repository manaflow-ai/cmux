//! Parity with the Swift tests in Packages/macOS/CmuxNext/Tests/CmuxNextPhoneTests
//! (PhoneDeviceListTests, AndroidPhoneBackendTests, SimulatorLiveInputTests),
//! asked through the JSON door the app uses.
use serde_json::{Value, json};

fn ask(request: Value) -> Value {
    let reply = cmux_phone_core::respond(request.to_string().as_bytes()).expect("request decodes");
    serde_json::from_slice(&reply).expect("reply is JSON")
}

fn fixture(name: &str) -> String {
    std::fs::read_to_string(format!("{}/tests/fixtures/{name}", env!("CARGO_MANIFEST_DIR")))
        .unwrap()
}

fn names(devices: &Value) -> Vec<&str> {
    devices.as_array().unwrap().iter().map(|device| device["name"].as_str().unwrap()).collect()
}

#[test]
fn simctl_lists_ready_first_then_newest_runtime_without_watches() {
    let reply = ask(json!({"op": "simctl_devices", "output": fixture("simctl-list.json")}));
    let devices = &reply["devices"];
    assert_eq!(
        names(devices),
        [
            "iPhone 18 Pro",
            "iPhone 17e",
            "iPad Pro 11-inch (M4)",
            "iPhone 16",
            "iPhone SE (3rd generation)"
        ]
    );
    assert_eq!(devices[0]["state"], json!({"kind": "ready"}));
    assert_eq!(devices[0]["os_version"], "iOS 27.0");
    assert_eq!(devices[0]["id"], "sim:6A05764C-FFD1-4B40-AA2E-AD27ADAC7A56");
    assert_eq!(devices[3]["state"], json!({"kind": "booting"}));
    assert_eq!(
        devices[4]["state"],
        json!({"kind": "unavailable", "reason": "runtime profile not found"})
    );
}

#[test]
fn simulator_model_comes_from_the_device_type() {
    use cmux_phone_core::devices::simulator_model;
    assert_eq!(
        simulator_model(Some("com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro-Max"), "x"),
        "iPhone 18 Pro Max"
    );
    assert_eq!(
        simulator_model(Some("com.apple.CoreSimulator.SimDeviceType.Apple-TV-4K"), "fallback"),
        "fallback"
    );
    assert_eq!(simulator_model(None, "fallback"), "fallback");
}

#[test]
fn devicectl_lists_paired_phones_with_their_transport() {
    let reply = ask(json!({"op": "devicectl_devices", "output": fixture("devicectl-list.json")}));
    let devices = &reply["devices"];
    assert_eq!(names(devices), ["Test’s iPhone", "Lab iPhone"]);
    assert_eq!(devices[0]["id"], "dev:00008140-0000000000000001");
    assert_eq!(devices[0]["model"], "iPhone 16 Pro");
    let transports: Vec<&str> =
        devices.as_array().unwrap().iter().map(|d| d["transport"].as_str().unwrap()).collect();
    assert_eq!(transports, ["usb", "wifi"]);
    assert!(devices.as_array().unwrap().iter().all(|d| d["state"] == json!({"kind": "ready"})));
}

#[test]
fn unreadable_tool_output_is_an_unreadable_reply() {
    let reply = ask(json!({"op": "simctl_devices", "output": "not json"}));
    assert_eq!(reply["error"], "unreadable");
}

#[test]
fn phone_ids_round_trip_and_reject_junk() {
    use cmux_phone_core::devices::PhoneDeviceId;
    for text in ["sim:ABC", "dev:0000-1", "vm:my phone", "avd:Pixel_8", "adb:R58M123"] {
        assert_eq!(PhoneDeviceId::parse(text).unwrap().text(), text);
    }
    for text in ["", "sim:", "ABC", "usb:123"] {
        assert_eq!(PhoneDeviceId::parse(text), None, "{text}");
        assert_eq!(ask(json!({"op": "phone_id", "id": text}))["id"], Value::Null);
    }
    assert_eq!(
        ask(json!({"op": "phone_id", "id": "vm:my phone"}))["id"],
        json!({"mode": "vm", "raw": "my phone"})
    );
}

const ADB_DEVICES: &str = "List of devices attached\nemulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1\nR58M123                device usb:1-1 product:panther model:Pixel_7 device:panther transport_id:2\n\n";

#[test]
fn adb_lists_emulators_and_usb_phones() {
    let reply = ask(json!({"op": "adb_devices", "output": ADB_DEVICES}));
    let devices = reply["devices"].as_array().unwrap();
    assert_eq!(devices.len(), 2);
    assert_eq!(devices[0]["serial"], "emulator-5554");
    assert_eq!(devices[1]["serial"], "R58M123");
    let usb: cmux_phone_core::android::AdbEntry =
        serde_json::from_value(devices[1].clone()).unwrap();
    assert!(!usb.is_emulator());
    assert_eq!(ask(json!({"op": "usb_model", "entry": devices[1]}))["model"], "Pixel 7");
    assert_eq!(
        ask(json!({"op": "avd_names", "output": "Pixel_8_API_35\nTablet_API_34\n"}))["names"],
        json!(["Pixel_8_API_35", "Tablet_API_34"])
    );
    assert_eq!(
        ask(json!({"op": "avd_name", "output": "Pixel_8_API_35\r\nOK\r\n"}))["name"],
        "Pixel_8_API_35"
    );
    assert_eq!(
        ask(json!({"op": "avd_display_name", "avd": "Pixel_8_API_35"}))["name"],
        "Pixel 8 API 35"
    );
}

#[test]
fn the_next_free_emulator_port_skips_running_ones() {
    assert_eq!(
        ask(json!({"op": "free_emulator_port", "serials": ["emulator-5554", "R58M123"]}))["port"],
        5556
    );
    assert_eq!(ask(json!({"op": "free_emulator_port", "serials": []}))["port"], 5554);
}

#[test]
fn density_and_screen_points() {
    assert_eq!(
        ask(json!({"op": "pixels_per_dp", "output": "Physical density: 420\n"}))["pixels_per_dp"],
        2.625
    );
    let reply = ask(json!({
        "op": "screen_points",
        "size_output": "Physical size: 1080x2400\n",
        "density_output": "Physical density: 420\n",
        "rotation": "1",
    }));
    // serde_json reads floats to within an ulp.
    assert!((reply["width"].as_f64().unwrap() - 2400.0 / 2.625).abs() < 1e-9);
    assert!((reply["height"].as_f64().unwrap() - 1080.0 / 2.625).abs() < 1e-9);
}

fn calls(input: Value, emulator: bool) -> Vec<Vec<String>> {
    let reply = ask(
        json!({"op": "android_input_calls", "input": input, "emulator": emulator, "scale": 2.625}),
    );
    reply["calls"]
        .as_array()
        .unwrap_or_else(|| panic!("{reply}"))
        .iter()
        .map(|call| serde_json::from_value(call["args"].clone()).unwrap())
        .collect()
}

fn argv(args: &[&str]) -> Vec<String> {
    args.iter().map(|arg| (*arg).to_owned()).collect()
}

#[test]
fn taps_and_swipes_are_sent_in_pixels() {
    assert_eq!(
        calls(json!({"kind": "tap", "x": 100, "y": 200}), true),
        [argv(&["shell", "input", "tap", "263", "525"])]
    );
    assert_eq!(
        calls(
            json!({"kind": "swipe", "from_x": 10, "from_y": 400, "to_x": 10, "to_y": 40, "seconds": 0.3}),
            true
        ),
        [argv(&["shell", "input", "swipe", "26", "1050", "26", "105", "300"])]
    );
}

#[test]
fn typed_text_is_quoted_for_the_device_shell() {
    assert_eq!(
        calls(json!({"kind": "text", "text": "it's a & b"}), true),
        [argv(&["shell", "input text 'it'\\''s%sa%s&%sb'"])]
    );
}

#[test]
fn buttons_are_key_events() {
    let keys: Vec<String> = ["home", "back", "lock", "volumeUp", "appSwitch"]
        .iter()
        .map(|button| {
            calls(json!({"kind": "button", "button": button}), true)[0].last().unwrap().clone()
        })
        .collect();
    assert_eq!(
        keys,
        [
            "KEYCODE_HOME",
            "KEYCODE_BACK",
            "KEYCODE_POWER",
            "KEYCODE_VOLUME_UP",
            "KEYCODE_APP_SWITCH"
        ]
    );
}

#[test]
fn deep_links_dark_mode_and_location() {
    assert_eq!(
        calls(json!({"kind": "open_url", "url": "myapp://item?a=1&b=2"}), true),
        [argv(&["shell", "am start -a android.intent.action.VIEW -d 'myapp://item?a=1&b=2'"])]
    );
    assert_eq!(
        calls(json!({"kind": "appearance", "dark": true}), true),
        [argv(&["shell", "cmd", "uimode", "night", "yes"])]
    );
    // The console's geo fix takes the longitude first.
    assert_eq!(
        calls(json!({"kind": "location", "latitude": 37.33, "longitude": -122.03}), true),
        [argv(&["emu", "geo", "fix", "-122.03", "37.33"])]
    );
    let usb = ask(
        json!({"op": "android_input_calls", "input": {"kind": "location", "latitude": 1.0, "longitude": 2.0}, "emulator": false, "scale": 1.0}),
    );
    assert_eq!(usb["error"], "unsupported");
}

#[test]
fn install_and_launch_an_app() {
    assert_eq!(
        calls(json!({"kind": "install", "path": "/tmp/app.apk"}), true),
        [argv(&["install", "-r", "/tmp/app.apk"])]
    );
    assert_eq!(
        calls(json!({"kind": "launch", "package": "com.example.app"}), true),
        [argv(&[
            "shell",
            "monkey",
            "-p",
            "com.example.app",
            "-c",
            "android.intent.category.LAUNCHER",
            "1"
        ])]
    );
}

const DUMP: &str = r#"<?xml version='1.0' encoding='UTF-8' standalone='yes' ?><hierarchy rotation="0"><node index="0" text="" resource-id="" class="android.widget.FrameLayout" content-desc="" clickable="false" bounds="[0,0][1080,2400]"><node index="0" text="Sign in" resource-id="com.example:id/login" class="android.widget.Button" content-desc="" clickable="true" bounds="[105,525][420,630]" /></node></hierarchy>UI hierchary dumped to: /dev/tty"#;

#[test]
fn the_accessibility_tree_comes_from_ui_automator() {
    let reply = ask(json!({"op": "uiautomator_tree", "output": DUMP, "pixels_per_point": 2.625}));
    let root = &reply["root"];
    assert_eq!(root["role"], "Screen");
    let button = &root["children"][0]["children"][0];
    assert_eq!(button["label"], "Sign in");
    assert_eq!(button["role"], "Button");
    assert_eq!(button["identifier"], "com.example:id/login");
    // Frames are in points (420 dpi: 2.625 px per point), like taps.
    assert_eq!(button["frame"], json!({"x": 40.0, "y": 200.0, "width": 120.0, "height": 40.0}));
    assert_eq!(root["children"][0]["role"], "FrameLayout");
}

#[test]
fn ui_automator_decodes_entities_and_refuses_junk() {
    let dump = r#"<hierarchy><node text="a &amp; b &#x41;&#66;" class='x.y.TextView' bounds="[0,0][10,10]"/></hierarchy>"#;
    let root = cmux_phone_core::uiautomator::parse(dump, 1.0).unwrap();
    assert_eq!(root.children[0].label, "a & b AB");
    assert_eq!(root.children[0].role, "TextView");
    let reply = ask(
        json!({"op": "uiautomator_tree", "output": "ERROR: null root node", "pixels_per_point": 1.0}),
    );
    assert_eq!(reply, json!({"error": "unreadable", "what": "the UI Automator dump"}));
    assert!(cmux_phone_core::uiautomator::parse("<hierarchy><node></hierarchy>", 1.0).is_err());
}

#[test]
fn a_tap_is_a_down_and_up_at_the_normalized_point() {
    let reply = ask(json!({"op": "tap", "screen": [400, 800], "point": [100, 200]}));
    assert_eq!(
        reply["touches"],
        json!([
            {"phase": "began", "x": 0.25, "y": 0.25, "offset_micros": 0},
            {"phase": "ended", "x": 0.25, "y": 0.25, "offset_micros": 50000},
        ])
    );
    assert_eq!(
        ask(json!({"op": "tap", "screen": [400, 800], "point": [500, 10]})),
        json!({"error": "outside_screen"})
    );
}

#[test]
fn a_swipe_moves_in_even_steps_over_its_duration() {
    let reply = ask(
        json!({"op": "swipe", "screen": [400, 800], "from": [200, 700], "to": [200, 100], "seconds": 0.2}),
    );
    let touches = reply["touches"].as_array().unwrap();
    assert_eq!(touches[0]["phase"], "began");
    assert_eq!(
        touches.last().unwrap(),
        &json!({"phase": "ended", "x": 0.5, "y": 0.125, "offset_micros": 200000})
    );
    assert!(touches[1..touches.len() - 1].iter().all(|touch| touch["phase"] == "moved"));
    let offsets: Vec<u64> =
        touches.iter().map(|touch| touch["offset_micros"].as_u64().unwrap()).collect();
    assert!(offsets.windows(2).all(|pair| pair[0] < pair[1]));
    assert!(touches.len() >= 12);
}

#[test]
fn typed_ascii_becomes_hid_key_strokes_with_shift() {
    let reply = ask(json!({"op": "key_strokes", "text": "aB1!\n"}));
    let pairs: Vec<(u64, bool)> = reply["strokes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|stroke| (stroke["usage"].as_u64().unwrap(), stroke["shift"].as_bool().unwrap()))
        .collect();
    assert_eq!(pairs, [(0x04, false), (0x05, true), (0x1E, false), (0x1E, true), (0x28, false)]);
    // Text a US keyboard cannot type is pasted instead.
    assert_eq!(ask(json!({"op": "key_strokes", "text": "héllo 日本"}))["strokes"], Value::Null);
}

#[test]
fn a_click_in_the_tab_maps_through_the_aspect_fit_screen() {
    let screen = json!([400, 800]);
    let view = json!([300, 300]);
    assert_eq!(
        ask(json!({"op": "drawn_rect", "screen": screen, "view": view}))["rect"],
        json!({"x": 75.0, "y": 0.0, "width": 150.0, "height": 300.0})
    );
    let normalized = |point: Value| {
        ask(json!({"op": "normalized_view_point", "screen": screen, "view": view, "point": point}))
            ["point"]
            .clone()
    };
    // AppKit points are bottom-left; the top-left of the screen is at y = 300.
    assert_eq!(normalized(json!([75, 300])), json!([0.0, 0.0]));
    assert_eq!(normalized(json!([150, 150])), json!([0.5, 0.5]));
    assert_eq!(normalized(json!([10, 150])), Value::Null);
    assert_eq!(
        ask(json!({"op": "device_point", "screen": screen, "view": view, "point": [150, 75]}))["point"],
        json!([200.0, 600.0])
    );
}

#[test]
fn mac_keys_map_to_hid_usages() {
    for (code, usage) in [
        (36, json!(0x28)),
        (51, json!(0x2A)),
        (123, json!(0x50)),
        (0, json!(0x04)),
        (9999, Value::Null),
    ] {
        assert_eq!(ask(json!({"op": "mac_key_usage", "code": code}))["usage"], usage, "{code}");
    }
}

#[test]
fn the_log_tail_keeps_the_last_errors_and_faults() {
    let long = "x".repeat(300);
    let ndjson = format!(
        "Filtering the log data\n{}\n{}\n{}\n",
        json!({"messageType": "Default", "eventMessage": "fine", "processImagePath": "/a/App"}),
        json!({"messageType": "Error", "eventMessage": "bad", "processImagePath": "/a/App"}),
        json!({"messageType": "Fault", "eventMessage": long, "processImagePath": "/usr/libexec/backboardd"}),
    );
    let reply = ask(json!({"op": "log_tail", "ndjson": ndjson, "limit": 5}));
    let lines = reply["lines"].as_array().unwrap();
    assert_eq!(lines.len(), 2);
    assert_eq!(lines[0], json!({"level": "error", "process": "App", "message": "bad"}));
    assert_eq!(lines[1]["process"], "backboardd");
    assert!(lines[1]["message"].as_str().unwrap().ends_with('…'));
}

#[test]
fn a_request_that_does_not_decode_is_an_error() {
    assert!(cmux_phone_core::respond(b"{\"op\":\"nope\"}").is_err());
    assert!(cmux_phone_core::respond(b"junk").is_err());
}
