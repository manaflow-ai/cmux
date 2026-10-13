//! Browser device emulation (`browser-devices-v1`, cx-ocbf3) through the
//! curated CLI and a real daemon: the daemon serves Chrome's device toolbar
//! list from its one data file, keeps custom devices, keeps each browser
//! tab's emulated device, and shows the resolved values (CSS size, pixel
//! ratio, user agent with the Chromium version, client hints, touch, the
//! DevTools calls) on the tab as `extra.emulation`. The engines only apply
//! that record, so this is the whole product rule.
#![cfg(unix)]

use super::*;

fn cmux(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

fn ok(server: &HeadlessServer, args: &[&str]) -> serde_json::Value {
    let output = cmux(server, args);
    assert_success(&output);
    json_output(&output)
}

fn refused(server: &HeadlessServer, args: &[&str]) -> String {
    let output = cmux(server, args);
    assert!(!output.status.success(), "{args:?}: {}", String::from_utf8_lossy(&output.stdout));
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// The first object under `value` that has `key` (results nest a snapshot).
fn find<'a>(value: &'a serde_json::Value, key: &str) -> Option<&'a serde_json::Value> {
    match value {
        serde_json::Value::Object(map) => {
            map.get(key).or_else(|| map.values().find_map(|child| find(child, key)))
        }
        serde_json::Value::Array(items) => items.iter().find_map(|child| find(child, key)),
        _ => None,
    }
}

fn emulation(server: &HeadlessServer, tab: &str) -> Option<serde_json::Value> {
    find(&ok(server, &["tab", tab, "show"]), "emulation").cloned()
}

fn devices(server: &HeadlessServer) -> Vec<serde_json::Value> {
    let list = ok(server, &["browser", "devices", "list"]);
    find(&list, "devices").and_then(|devices| devices.as_array()).cloned().unwrap_or_default()
}

#[test]
fn browser_devices_list_custom_devices_and_tab_emulation_through_a_real_daemon() {
    let server = HeadlessServer::start("browser-devices");
    let identity = raw_json(&server, serde_json::json!({"id": "who", "cmd": "identify"}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "browser-devices-v1"),
        "{identity}"
    );

    // The list: Chrome's devices verbatim and in Chrome's order, then newer ones.
    let list = ok(&server, &["browser", "devices", "list"]);
    assert_eq!(find(&list, "ref").unwrap(), "chromium/8037", "{list}");
    let all = devices(&server);
    let titles: Vec<&str> = all.iter().filter_map(|d| d["title"].as_str()).collect();
    assert_eq!(titles.first(), Some(&"iPhone SE"), "{titles:?}");
    for title in [
        "iPhone 15",
        "Pixel 7",
        "Surface Duo",
        "Nest Hub Max",
        "iPhone 17 Pro",
        "Pixel 10 Pro",
        "Galaxy S26",
    ] {
        assert!(titles.contains(&title), "{title} missing from {titles:?}");
    }
    assert_eq!(all.iter().filter(|d| d["origin"] == "chrome").count(), 46);
    assert!(all.iter().filter(|d| d["origin"] == "cmux").all(|d| d["sources"].is_array()));

    // Custom devices persist in the daemon and come first; Chrome's limits hold.
    let kiosk = r#"{"title":"Kiosk","type":"tablet","screen":{"vertical":{"width":600,"height":1000},"horizontal":{"width":1000,"height":600},"device-pixel-ratio":1.5},"capabilities":["touch"],"user-agent":"KioskBrowser/%s"}"#;
    ok(&server, &["browser", "devices", "add", "--device-json", kiosk]);
    let all = devices(&server);
    assert_eq!(all[0]["title"], "Kiosk");
    assert_eq!(all[0]["origin"], "custom");
    let too_dense = r#"{"title":"Dense","screen":{"vertical":{"width":600,"height":1000},"horizontal":{"width":1000,"height":600},"device-pixel-ratio":20}}"#;
    let error = refused(&server, &["browser", "devices", "add", "--device-json", too_dense]);
    assert!(error.contains("device-pixel-ratio"), "{error}");

    // A browser tab (frontend-rendered, as the app's tabs are).
    raw_json(
        &server,
        serde_json::json!({"id": "b", "cmd": "new-frontend-browser-tab",
                           "url": "https://example.com/", "engine": "cef"}),
    );
    ok(&server, &["tab", "create", "terminal"]);
    let tabs = ok(&server, &["tab", "list"]);
    let tabs = find(&tabs, "items").or_else(|| tabs.as_array().map(|_| &tabs)).unwrap().clone();
    let tab_of = |kind: &str| -> String {
        tabs.as_array()
            .unwrap()
            .iter()
            .find(|tab| tab["content_kind"] == kind)
            .and_then(|tab| tab["id"].as_str())
            .unwrap_or_else(|| panic!("no {kind} tab in {tabs}"))
            .to_string()
    };
    let browser = tab_of("browser");
    assert_eq!(emulation(&server, &browser), None);

    // A Chrome device in landscape: Chrome's numbers and DevTools' calls.
    let result = ok(
        &server,
        &["tab", &browser, "emulate", "--device", "iphone 15", "--orientation", "landscape"],
    );
    let applied = find(&result, "emulation").expect("result shows extra.emulation").clone();
    assert_eq!(applied["device"], "iPhone 15");
    assert_eq!(applied["orientation"], "horizontal");
    assert_eq!((applied["width"].as_i64(), applied["height"].as_i64()), (Some(852), Some(393)));
    assert_eq!(applied["device_scale_factor"], 3.0);
    assert_eq!((applied["mobile"].as_bool(), applied["touch"].as_bool()), (Some(true), Some(true)));
    assert!(applied["user_agent"].as_str().unwrap().contains("iPhone OS"), "{applied}");
    assert_eq!(applied["screen_orientation"]["type"], "landscapePrimary");
    let calls = applied["chromium_calls"].as_array().unwrap();
    assert_eq!(calls[0]["method"], "Emulation.setDeviceMetricsOverride");
    assert_eq!(calls[0]["params"]["width"], 852);
    assert_eq!(calls[0]["params"]["dontSetVisibleSize"], true);
    assert_eq!(calls[2]["params"], serde_json::json!({"enabled": true, "maxTouchPoints": 1}));
    // Every client reads the same record on the tab.
    assert_eq!(emulation(&server, &browser).as_ref(), Some(&applied));

    // Orientation alone turns the device the tab emulates.
    let turned = ok(&server, &["tab", &browser, "emulate", "--orientation", "portrait"]);
    let turned = find(&turned, "emulation").unwrap();
    assert_eq!((turned["width"].as_i64(), turned["height"].as_i64()), (Some(393), Some(852)));

    // An Android device: "%s" is the Chromium version; client hints go with it.
    let pixel = ok(&server, &["tab", &browser, "emulate", "--device", "Pixel 7"]);
    let pixel = find(&pixel, "emulation").unwrap();
    assert!(pixel["user_agent"].as_str().unwrap().contains("Chrome/154.0.0.0"), "{pixel}");
    assert_eq!(pixel["user_agent_metadata"]["platform"], "Android");
    assert_eq!(pixel["device_scale_factor"], 2.625);

    // A foldable's unfolded screen sends its hinge as the display feature.
    let duo = ok(
        &server,
        &[
            "tab",
            &browser,
            "emulate",
            "--device",
            "Surface Duo",
            "--orientation",
            "unfolded-portrait",
        ],
    );
    let duo = find(&duo, "emulation").unwrap();
    assert_eq!(duo["width"], 1114);
    assert_eq!(
        duo["display_feature"],
        serde_json::json!({"orientation": "vertical", "offset": 540, "maskLength": 34})
    );
    assert_eq!(duo["device_posture"], "folded");

    // A custom device, by title.
    let custom = ok(&server, &["tab", &browser, "emulate", "--device", "Kiosk"]);
    let custom = find(&custom, "emulation").unwrap();
    assert_eq!(custom["origin"], "custom");
    assert_eq!(custom["user_agent"], "KioskBrowser/154.0.0.0");
    assert_eq!((custom["mobile"].as_bool(), custom["touch"].as_bool()), (Some(false), Some(true)));

    // Refusals: an unknown device, a missing orientation, a terminal tab.
    assert!(
        refused(&server, &["tab", &browser, "emulate", "--device", "Nokia 3310"])
            .contains("no device named")
    );
    assert!(
        refused(
            &server,
            &["tab", &browser, "emulate", "--device", "Nest Hub Max", "--orientation", "portrait"]
        )
        .contains("no vertical orientation")
    );
    let terminal = tab_of("terminal");
    assert!(
        refused(&server, &["tab", &terminal, "emulate", "--device", "iPhone 15"])
            .contains("only to browser tabs")
    );

    // A removed custom device leaves the tab's own copy; clear ends emulation.
    ok(&server, &["browser", "devices", "remove", "--title", "Kiosk"]);
    assert!(devices(&server).iter().all(|d| d["title"] != "Kiosk"));
    assert_eq!(emulation(&server, &browser).unwrap()["device"], "Kiosk");
    ok(&server, &["tab", &browser, "emulate", "clear"]);
    assert_eq!(emulation(&server, &browser), None);
}
