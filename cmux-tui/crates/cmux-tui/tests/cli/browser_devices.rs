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

fn profile_tree(server: &HeadlessServer) -> serde_json::Value {
    raw_json(server, serde_json::json!({"id": 1, "cmd": "list-workspaces"}))
}

fn frontend_browser_tab(tree: &serde_json::Value) -> &serde_json::Value {
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["browser_renderer"] == "frontend")
        .expect("frontend browser tab")
}

#[test]
fn browser_devices_list_custom_devices_and_tab_emulation_through_a_real_daemon() {
    let server = HeadlessServer::start("browser-devices");
    let identity = raw_json(&server, serde_json::json!({"id": "who", "cmd": "identify"}));
    assert!(
        identity["capabilities"].as_array().unwrap().iter().any(|v| v == "browser-devices-v1"),
        "{identity}"
    );
    assert!(
        ["browser-fit-v1", "browser-fit-width-v1"].iter().all(|cap| identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == cap)),
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
    // Chrome's menu sections come from the daemon too.
    let section =
        |title: &str| all.iter().find(|d| d["title"] == title).unwrap()["category"].clone();
    assert_eq!(section("Surface Duo"), "foldable");
    assert_eq!(section("iPad Mini"), "tablet-desktop");
    assert_eq!(section("Nest Hub Max"), "smart-display");
    assert_eq!(section("iPhone 17 Pro"), "mobile");
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
    assert!(applied["safe_area_insets"].is_object(), "{applied}");
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
    // Client hints as the device gives them: the engine keeps its own brands.
    assert!(pixel["user_agent_metadata"].get("brands").is_none(), "{pixel}");
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
    let bad_agent = r#"{"title":"Bad","screen":{"vertical":{"width":600,"height":1000},"horizontal":{"width":1000,"height":600},"device-pixel-ratio":2},"user-agent":"A\r\nX-Injected: 1"}"#;
    assert!(
        refused(&server, &["tab", &browser, "emulate", "--custom-json", bad_agent])
            .contains("user-agent")
    );
    let terminal = tab_of("terminal");
    assert!(
        refused(&server, &["tab", &terminal, "emulate", "--device", "iPhone 15"])
            .contains("only to browser tabs")
    );

    // Fit as 16:9 Desktop: the tab keeps a fit in place of the device; the
    // record names the aspect and width bounds, the engine sizes the layout
    // from its view, and the calls reset the device's user agent and touch.
    let fit = ok(&server, &["tab", &browser, "emulate", "--fit", "16:9"]);
    let fit = find(&fit, "emulation").expect("result shows extra.emulation").clone();
    assert_eq!(fit["mode"], "fit", "{fit}");
    assert_eq!(
        fit["fit"],
        serde_json::json!({"value": "16:9", "aspect": "16:9", "aspect_width": 16, "aspect_height": 9,
                           "min_width": 1024, "max_width": 1920})
    );
    assert!(fit.get("device").is_none(), "a fit names no device: {fit}");
    assert_eq!((fit["mobile"].as_bool(), fit["touch"].as_bool()), (Some(false), Some(false)));
    assert_eq!(fit["user_agent"], "");
    let calls = fit["chromium_calls"].as_array().unwrap();
    assert_eq!(calls[0]["method"], "Emulation.setDeviceMetricsOverride");
    assert_eq!(calls[0]["params"]["mobile"], false);
    assert_eq!(calls[0]["params"]["dontSetVisibleSize"], true);
    assert_eq!(calls[1]["params"], serde_json::json!({"userAgent": ""}));
    assert_eq!(calls[2]["params"], serde_json::json!({"enabled": false}));
    assert_eq!(emulation(&server, &browser).as_ref(), Some(&fit));
    // "16x9" is the same fit; a bad ratio or fit with a device is refused.
    let same = ok(&server, &["tab", &browser, "emulate", "--fit", "16x9"]);
    assert_eq!(find(&same, "emulation"), Some(&fit));
    assert!(refused(&server, &["tab", &browser, "emulate", "--fit", "wide"]).contains("W:H"));
    assert!(refused(&server, &["tab", &browser, "emulate", "--fit", "9:40"]).contains("W:H"));
    assert!(
        refused(&server, &["tab", &browser, "emulate", "--fit", "16:9", "--device", "Kiosk"])
            .contains("fit alone")
    );
    assert!(
        refused(&server, &["tab", &terminal, "emulate", "--fit", "16:9"])
            .contains("only to browser tabs")
    );
    // Orientation alone needs a device, not a fit.
    assert!(
        refused(&server, &["tab", &browser, "emulate", "--orientation", "portrait"])
            .contains("emulates no device")
    );
    // Fit as Desktop (1280): a fixed layout width (min = max = 1280) in
    // place of the 16:9 fit; only one fit is on a tab at a time.
    let fixed = ok(&server, &["tab", &browser, "emulate", "--fit", "1280"]);
    let fixed = find(&fixed, "emulation").expect("result shows extra.emulation").clone();
    assert_eq!(fixed["mode"], "fit", "{fixed}");
    assert_eq!(
        fixed["fit"],
        serde_json::json!({"value": "1280", "aspect": "16:9", "aspect_width": 16, "aspect_height": 9,
                           "min_width": 1280, "max_width": 1280})
    );
    let trimmed = ok(&server, &["tab", &browser, "emulate", "--fit", " 1280 "]);
    assert_eq!(find(&trimmed, "emulation"), Some(&fixed));
    assert_eq!(emulation(&server, &browser).as_ref(), Some(&fixed));
    assert!(refused(&server, &["tab", &browser, "emulate", "--fit", "99999"]).contains("1280"));
    assert!(refused(&server, &["tab", &browser, "emulate", "--fit", "300"]).contains("1280"));
    // `--fit off` ends the fit.
    ok(&server, &["tab", &browser, "emulate", "--fit", "16:10"]);
    assert_eq!(emulation(&server, &browser).unwrap()["fit"]["value"], "16:10");
    ok(&server, &["tab", &browser, "emulate", "--fit", "off"]);
    assert_eq!(emulation(&server, &browser), None);
    // A device again replaces the fit.
    ok(&server, &["tab", &browser, "emulate", "--device", "Kiosk"]);

    // A removed custom device leaves the tab's own copy; clear ends emulation.
    ok(&server, &["browser", "devices", "remove", "--title", "Kiosk"]);
    assert!(devices(&server).iter().all(|d| d["title"] != "Kiosk"));
    assert_eq!(emulation(&server, &browser).unwrap()["device"], "Kiosk");
    ok(&server, &["tab", &browser, "emulate", "clear"]);
    assert_eq!(emulation(&server, &browser), None);
}

#[test]
fn browser_profile_commands_create_move_and_open_and_refuse_delete_through_a_real_daemon() {
    let server = HeadlessServer::start("browser-profiles");

    let created = ok(&server, &["browser", "profile", "create", "--name", "Work"]);
    let profile_id = find(&created, "browser_profile")
        .and_then(|profile| profile["id"].as_str())
        .expect("created browser profile id")
        .to_owned();

    let listed = ok(&server, &["browser", "profile", "list"]);
    let profiles = find(&listed, "browser_profiles").cloned().unwrap_or_default();
    assert_eq!(profiles[1]["name"], "Work", "{listed}");
    assert_eq!(profiles[1]["id"], profile_id, "{listed}");

    let opened = ok(
        &server,
        &[
            "browser",
            "profile",
            "open",
            "https://example.com/agents",
            "--engine",
            "webkit",
            "--profile",
            "Work",
        ],
    );
    assert!(find(&opened, "browser_id").and_then(|id| id.as_str()).is_some(), "{opened}");
    assert_eq!(frontend_browser_tab(&profile_tree(&server))["browser_profile_id"], profile_id);

    let opened_with_flag = ok(
        &server,
        &[
            "browser",
            "profile",
            "open",
            "--url",
            "https://example.com/agents-flag",
            "--engine",
            "webkit",
            "--profile",
            "Work",
        ],
    );
    assert!(
        find(&opened_with_flag, "browser_id").and_then(|id| id.as_str()).is_some(),
        "{opened_with_flag}"
    );

    ok(&server, &["browser", "profile", "move", "--profile", "Work", "--index", "0"]);
    let moved = ok(&server, &["browser", "profile", "list"]);
    assert_eq!(find(&moved, "browser_profiles").unwrap()[0]["name"], "Work", "{moved}");

    // Only a person deletes a browser profile, in the app: the CLI is refused and the profile stays.
    let refusal = refused(&server, &["browser", "profile", "delete", "--profile", "Work"]);
    assert!(refusal.contains("only a person deletes a browser profile"), "{refusal}");
    let after_delete = ok(&server, &["browser", "profile", "list"]);
    assert!(
        find(&after_delete, "browser_profiles")
            .and_then(|profiles| profiles.as_array())
            .unwrap()
            .iter()
            .any(|profile| profile["id"] == profile_id),
        "{after_delete}"
    );
}
