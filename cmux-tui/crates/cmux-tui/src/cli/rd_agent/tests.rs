use serde_json::json;

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn run_request(words: &[&str]) -> (String, Verb, bool) {
    match parse(&args(words)).unwrap() {
        Request::Run { device, verb, json } => (device, verb, json),
        Request::Help => panic!("expected a command, got help"),
    }
}

fn row(tab: &str, id: &str, name: &str, live: bool) -> TabRow {
    TabRow {
        tab: tab.into(),
        device_id: Some(id.into()),
        device: name.into(),
        connected: live,
        has_frame: live,
        frame: live.then_some((1920, 1080)),
    }
}

#[test]
fn the_four_verbs_parse_with_their_flags() {
    let (device, verb, json) =
        run_request(&["screenshot", "--device", "studio", "--out", "/tmp/s.png", "--json"]);
    assert_eq!((device.as_str(), json), ("studio", true));
    assert_eq!(verb, Verb::Screenshot { out: Some("/tmp/s.png".into()) });

    let (_, verb, json) = run_request(&[
        "click",
        "--device=studio",
        "--x",
        "0.5",
        "--y=0.25",
        "--button",
        "right",
        "--double",
    ]);
    assert!(!json);
    assert_eq!(verb, Verb::Click { x: 0.5, y: 0.25, button: Button::Right, double: true });

    let (_, verb, _) = run_request(&["type", "--device", "studio", "hello", "world"]);
    assert_eq!(verb, Verb::Type { text: "hello world".into() });
    // `--` makes a dash-led text literal.
    let (_, verb, _) = run_request(&["type", "--device", "studio", "--", "--not-a-flag"]);
    assert_eq!(verb, Verb::Type { text: "--not-a-flag".into() });

    let (_, verb, _) = run_request(&["key", "--device", "studio", "cmd+shift+4"]);
    assert_eq!(
        verb,
        Verb::Key { combo: "cmd+shift+4".into(), usages: vec![0x07_00E1, 0x07_00E3, 0x07_0021] }
    );

    for help in [&[][..], &["help"][..], &["--help"][..]] {
        assert_eq!(parse(&args(help)).unwrap(), Request::Help);
    }
}

#[test]
fn bad_arguments_are_usage_refusals_that_point_at_help() {
    for words in [
        &["click", "--device", "s", "--x", "1.5", "--y", "0"][..],
        &["click", "--device", "s", "--x", "-0.1", "--y", "0"][..],
        &["click", "--device", "s", "--x", "0.5"][..],
        &["click", "--device", "s", "--x", "0.5", "--y", "0.5", "--button", "side"][..],
        &["screenshot", "--device", "s", "--x", "0.5"][..],
        &["screenshot", "--device", "s", "extra"][..],
        &["type", "--device", "s"][..],
        &["key", "--device", "s"][..],
        &["key", "--device", "s", "cmd+a", "cmd+b"][..],
        &["key", "--device", "s", "hyper+a"][..],
        &["key", "--device", "s", "fn+f1"][..],
        &["drag", "--device", "s"][..],
        &["click", "--device"][..],
    ] {
        let error = parse(&args(words)).unwrap_err();
        assert_eq!((error.error, error.next.as_str()), ("usage", "cmux rd help"), "{words:?}");
    }
    // No device: the tabs list says which devices there are.
    let error = parse(&args(&["screenshot"])).unwrap_err();
    assert_eq!((error.error, error.next.as_str()), ("usage", "cmux app mac-screens"));
}

#[test]
fn fractions_map_onto_stream_pixels_inside_the_picture() {
    assert_eq!(to_stream_pixels(0.0, 0.0, 1920, 1080), (0, 0));
    assert_eq!(to_stream_pixels(0.5, 0.25, 1920, 1080), (960, 270));
    // The far edge is the last pixel, never one past it.
    assert_eq!(to_stream_pixels(1.0, 1.0, 1920, 1080), (1919, 1079));
    assert_eq!(to_stream_pixels(0.9999, 0.9999, 2560, 1600), (2559, 1599));
    // An odd size rounds down.
    assert_eq!(to_stream_pixels(0.5, 0.5, 1001, 3), (500, 1));
    assert_eq!(to_stream_pixels(0.5, 0.5, 1, 1), (0, 0));
    assert_eq!(frame_size("3024x1964"), Some((3024, 1964)));
    for empty in ["0x0", "", "x", "12", "-1x5"] {
        assert_eq!(frame_size(empty), None, "{empty}");
    }
}

#[test]
fn a_click_is_a_move_then_presses_and_a_key_releases_in_reverse() {
    let click = Verb::Click { x: 0.5, y: 0.5, button: Button::Left, double: false };
    assert_eq!(
        input_events(&click, (200, 100)),
        vec![
            json!({"t": "pointer", "x": 100, "y": 50}),
            json!({"t": "button", "button": 1, "down": true}),
            json!({"t": "button", "button": 1, "down": false}),
        ]
    );
    let double = Verb::Click { x: 0.0, y: 0.0, button: Button::Right, double: true };
    let events = input_events(&double, (200, 100));
    assert_eq!(events.len(), 5);
    assert!(events[1..].iter().all(|e| e["button"] == 3));

    let key = Verb::Key { combo: "ctrl+c".into(), usages: key_usages("ctrl+c").unwrap() };
    let usages: Vec<_> = input_events(&key, (1, 1))
        .iter()
        .map(|e| (e["usage"].clone(), e["down"].clone()))
        .collect();
    assert_eq!(
        usages,
        vec![
            (json!(0x07_00E0), json!(true)),
            (json!(0x07_0006), json!(true)),
            (json!(0x07_0006), json!(false)),
            (json!(0x07_00E0), json!(false))
        ]
    );
    assert_eq!(
        input_events(&Verb::Type { text: "hi".into() }, (1, 1)),
        vec![json!({"t": "text", "text": "hi"})]
    );
}

#[test]
fn key_combos_become_hid_usages() {
    assert_eq!(key_usages("return").unwrap(), vec![0x07_0028]);
    assert_eq!(key_usages("escape").unwrap(), vec![0x07_0029]);
    assert_eq!(key_usages("f5").unwrap(), vec![0x07_003E]);
    assert_eq!(key_usages("f13").unwrap(), vec![0x07_0068]);
    assert_eq!(key_usages("up").unwrap(), vec![0x07_0052]);
    assert_eq!(key_usages("ctrl+alt+delete").unwrap(), vec![0x07_00E0, 0x07_00E2, 0x07_004C]);
    assert_eq!(key_usages("0").unwrap(), vec![0x07_0027]);
    // A shifted character adds Shift once.
    assert_eq!(key_usages("A").unwrap(), vec![0x07_00E1, 0x07_0004]);
    assert_eq!(key_usages("shift+A").unwrap(), vec![0x07_00E1, 0x07_0004]);
    assert_eq!(key_usages("cmd+?").unwrap(), vec![0x07_00E3, 0x07_00E1, 0x07_0038]);
    assert_eq!(key_usages("cmd++").unwrap(), vec![0x07_00E3, 0x07_00E1, 0x07_002E]);
    assert!(key_usages("é").is_err());
    assert!(key_usages("fn+left").is_err());
}

#[test]
fn a_device_is_found_by_id_name_or_prefix_and_a_live_tab_wins() {
    let rows = vec![
        row("tab_2", "dev-aaaa-1111", "Studio", false),
        row("tab_3", "dev-aaaa-1111", "Studio", true),
        row("tab_4", "dev-bbbb-2222", "linux-box", true),
    ];
    let shot = Verb::Screenshot { out: None };
    assert_eq!(pick_tab(&rows, "studio", &shot).unwrap().tab, "tab_3");
    assert_eq!(pick_tab(&rows, "dev-aaaa-1111", &shot).unwrap().tab, "tab_3");
    assert_eq!(pick_tab(&rows, "dev-bbbb", &shot).unwrap().tab, "tab_4");
    assert_eq!(pick_tab(&rows, "tab_2", &shot).unwrap().tab, "tab_2");
    // Prefix needs four characters and one device.
    assert_eq!(pick_tab(&rows, "dev-", &shot).unwrap_err().error, "ambiguous_device");
    assert_eq!(pick_tab(&rows, "dev", &shot).unwrap_err().error, "no_screen_tab");

    let missing = pick_tab(&rows, "office mac", &shot).unwrap_err();
    assert_eq!(missing.error, "no_screen_tab");
    assert_eq!(missing.next, "cmux tab new-mac-screen --device 'office mac' --scope view");
    let click = Verb::Click { x: 0.1, y: 0.1, button: Button::Left, double: false };
    assert_eq!(
        pick_tab(&rows, "pc", &click).unwrap_err().next,
        "cmux tab new-mac-screen --device pc --scope full"
    );
}

#[test]
fn every_app_refusal_names_the_command_that_moves_on() {
    let click = Verb::Click { x: 0.5, y: 0.25, button: Button::Left, double: false };
    let shot = Verb::Screenshot { out: None };
    let case = |code: &str, verb: &Verb| explain_refusal(code, "studio", verb, true);

    let view_only = case("mac_screen.view_only", &click);
    assert_eq!(view_only.error, "view_only");
    assert_eq!(view_only.next, "cmux tab new-mac-screen --device studio --scope full");
    assert!(!view_only.retryable);

    let waiting = case("mac_screen.waiting_for_approval", &click);
    assert_eq!(waiting.next, "cmux rd click --device studio --x 0.5 --y 0.25 --json");
    assert!(waiting.retryable);

    assert_eq!(case("mac_screen.not_signed_in", &shot).next, "cmux login");
    assert_eq!(
        case("mac_screen.connect_card", &shot).next,
        "cmux tab new-mac-screen --device studio --scope view"
    );
    assert_eq!(
        case("mac_screen.ended", &click).next,
        "cmux tab new-mac-screen --device studio --scope full"
    );
    assert_eq!(case("mac_screen.scope_exceeds", &click).next, "cmux rd screenshot --device studio");
    assert_eq!(
        case("mac_screen.connecting", &shot).next,
        "cmux rd screenshot --device studio --json"
    );
    assert_eq!(case("mac_screen.host_offline", &shot).next, "cmux device list");
    assert_eq!(case("mac_screen.something_new", &shot).error, "refused");
    for code in [
        "no_tab",
        "connect_card",
        "requesting",
        "connecting",
        "no_frame",
        "waiting_for_approval",
        "declined",
        "view_only",
        "not_signed_in",
        "scope_exceeds",
        "permission_none",
        "host_offline",
        "not_shared",
        "not_found",
        "frame_changed",
        "revoked",
        "ended",
        "stream_failed",
        "unsupported",
    ] {
        let error = case(&format!("mac_screen.{code}"), &click);
        assert_ne!(error.error, "refused", "{code} has its own refusal");
        assert!(
            error.next.starts_with("cmux ") || error.next.starts_with("open "),
            "{code}: {}",
            error.next
        );
    }
}

#[test]
fn a_refusal_in_json_is_error_reason_next_and_the_cli_envelope() {
    let error =
        explain_refusal("mac_screen.view_only", "studio", &Verb::Type { text: "x".into() }, false);
    let value = error.to_json();
    assert_eq!(value["error"], "view_only");
    assert_eq!(value["next"], "cmux tab new-mac-screen --device studio --scope full");
    assert!(value["reason"].as_str().unwrap().contains("rd type needs Full Control"));
    assert_eq!(value["code"], "rd.view_only");
    assert_eq!(value["details"]["next"], value["next"]);
    assert_eq!(value["retryable"], false);
    assert!(
        value["message"]
            .as_str()
            .unwrap()
            .ends_with("next: cmux tab new-mac-screen --device studio --scope full")
    );

    let outdated = app_error(&json!({"code": "method_not_found", "message": "unknown method"}));
    assert_eq!(
        (outdated.error, outdated.next.as_str()),
        ("app_outdated", "cmux settings check-for-updates")
    );
    let gone = app_error(&json!({"code": "socket.unreachable", "message": "no socket"}));
    assert_eq!(
        (gone.error, gone.next.as_str(), gone.retryable),
        ("app_unreachable", "open -a cmux", true)
    );
}

#[test]
fn a_command_line_quotes_what_the_shell_would_split() {
    let verb = Verb::Type { text: "it's -here".into() };
    assert_eq!(
        command_line("my mac", &verb, false),
        "cmux rd type --device 'my mac' 'it'\\''s -here'"
    );
    let verb = Verb::Type { text: "-n".into() };
    assert_eq!(command_line("m", &verb, true), "cmux rd type --device m -- -n --json");
    let verb = Verb::Key { combo: "cmd+shift+4".into(), usages: vec![] };
    assert_eq!(command_line("m", &verb, false), "cmux rd key --device m cmd+shift+4");
    let verb = Verb::Click { x: 1.0, y: 0.0, button: Button::Middle, double: true };
    assert_eq!(
        command_line("m", &verb, false),
        "cmux rd click --device m --x 1 --y 0 --button middle --double"
    );
}

#[test]
fn state_rows_and_default_screenshot_paths() {
    let state = json!({"tabs": [
        {"tab": "t1", "device_id": "d1", "device": "Studio", "connected": true, "has_frame": true, "frame": "3024x1964"},
        {"tab": "t2", "device_id": null, "device": "Old", "phase": null},
        {"device": "no tab key"},
    ]});
    let rows = tab_rows(&state);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].frame, Some((3024, 1964)));
    assert_eq!(
        (rows[1].device_id.as_deref(), rows[1].connected, rows[1].frame),
        (None, false, None)
    );

    let path = screenshot_path(None, "Leo's Studio / 2").unwrap();
    let name = std::path::Path::new(&path).file_name().unwrap().to_string_lossy().into_owned();
    assert!(name.starts_with("cmux-rd-leo-s-studio---2-") && name.ends_with(".png"), "{name}");
    assert_eq!(screenshot_path(Some("/tmp/a.png"), "x").unwrap(), "/tmp/a.png");
    assert!(screenshot_path(Some("rel.png"), "x").unwrap().ends_with("/rel.png"));
    assert!(screenshot_path(Some("-"), "x").is_err());
}

#[test]
fn only_the_agent_verbs_leave_the_rd_engine() {
    for verb in ["screenshot", "click", "type", "key", "help", "--help"] {
        assert!(owns(Some(verb)), "{verb}");
    }
    for verb in ["serve", "connect", "host", "view", "linux-host"] {
        assert!(!owns(Some(verb)), "{verb}");
    }
    assert!(!owns(None));
}
