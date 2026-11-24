use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}
fn env(k: &str) -> Option<String> {
    (k == "CMUX_CLOUD_API_URL").then(|| "https://api.cmux.test".to_owned())
}

/// `inference route --machine` with no API flags goes through the app (as `vm exec`); any direct flag keeps the API path.
#[test]
fn a_route_without_api_flags_goes_through_the_app() {
    let none = |_: &str| None;
    let machine = "vm_abcdefghij0123456789";
    assert_eq!(
        app_route(&words(&["route", "--machine", machine, "--agent", "claude"]), &none),
        Some((machine.to_owned(), "claude".to_owned()))
    );
    assert_eq!(
        app_route(&words(&["route", "--machine", machine, "--api", "https://a.test"]), &none),
        None
    );
    assert_eq!(app_route(&words(&["route", "--machine", machine, "--token-file=/t"]), &none), None);
    let token = |k: &str| (k == "CMUX_CLOUD_ACCESS_TOKEN").then(|| "t".to_owned());
    assert_eq!(app_route(&words(&["route", "--machine", machine]), &token), None);
    assert_eq!(app_route(&words(&["route", "--machine", "nope"]), &none), None);
}

/// The app's exec answer reads like the API's: the route from stdout, or the exec's failure.
#[test]
fn the_apps_exec_answer_is_the_route() {
    let routed = app_route_answer(
        "vm_a",
        "codex",
        Ok(json!({"stdout": "{\"ok\":true,\"route\":\"team_key\"}\n200", "exit_code": 0})),
    );
    assert_eq!(routed["route"], "team_key");
    let shared =
        app_route_answer("vm_a", "codex", Ok(json!({"stdout": "not found\n404", "exit_code": 0})));
    assert_eq!(shared["route"], "shared_coderouter");
    let failed = app_route_answer(
        "vm_a",
        "codex",
        Err(json!({"code": "unavailable", "message": "vm_a is paused"})),
    );
    assert_eq!(failed["error"]["code"], "machine.exec_failed");
    assert!(failed["error"]["message"].as_str().unwrap().contains("vm_a is paused"));
}

#[test]
fn parses_status_mode_and_route() {
    let (c, v) = parse(&words(&["status", "--personal"]), &env).unwrap();
    assert_eq!(c.api.as_deref(), Some("https://api.cmux.test"));
    assert_eq!(v, Verb::Status { personal: true });
    let (_, v) =
        parse(&words(&["mode", "gateway", "--gateway-machine", "vm_abcdefghij0123456789"]), &env)
            .unwrap();
    assert_eq!(
        v,
        Verb::Mode {
            personal: false,
            mode: "gateway".into(),
            machine: Some(Some("vm_abcdefghij0123456789".into()))
        }
    );
    let (_, v) =
        parse(&words(&["mode", "off", "--no-gateway-machine", "--personal"]), &env).unwrap();
    assert_eq!(v, Verb::Mode { personal: true, mode: "off".into(), machine: Some(None) });
    let (_, v) = parse(
        &words(&["route", "--machine", "vm_abcdefghij0123456789", "--agent", "claude"]),
        &env,
    )
    .unwrap();
    assert_eq!(
        v,
        Verb::Route { machine: "vm_abcdefghij0123456789".into(), agent: "claude".into() }
    );
    assert!(parse(&words(&["mode"]), &env).is_err());
    assert!(parse(&words(&["mode", "on"]), &env).is_err());
    // `joined`, with a joined machine as the gateway machine (cmux-platform's JOINED_MACHINE) or a Cloud one.
    let joined = "machine_0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b";
    let (_, v) = parse(&words(&["mode", "joined", "--gateway-machine", joined]), &env).unwrap();
    assert_eq!(
        v,
        Verb::Mode { personal: false, mode: "joined".into(), machine: Some(Some(joined.into())) }
    );
    let (_, v) = parse(&words(&["mode", "joined"]), &env).unwrap();
    assert_eq!(v, Verb::Mode { personal: false, mode: "joined".into(), machine: None });
    for bad in [
        "machine_0F1E2D3C-4B5A-6978-8A9B-0C1D2E3F4A5B",
        "machine_0f1e2d3c4b5a69788a9b0c1d2e3f4a5b",
        "machine_0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5",
        "machine_0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5g",
        "cmm_0f1e2d3c",
    ] {
        assert!(!joined_machine(bad), "{bad}");
        assert!(
            parse(&words(&["mode", "joined", "--gateway-machine", bad]), &env).is_err(),
            "{bad}"
        );
    }
    assert!(parse(&words(&["mode", "joined", "off"]), &env).is_err());
    assert!(parse(&words(&["route", "--machine", "nope"]), &env).is_err());
    assert!(
        parse(
            &words(&["route", "--machine", "vm_abcdefghij0123456789", "--agent", "gemini"]),
            &env
        )
        .is_err()
    );
    assert!(parse(&words(&["status", "--machine", "vm_abcdefghij0123456789"]), &env).is_err());
}

#[test]
fn scopes_the_status_and_keeps_api_error_codes() {
    let ok = json!({"ok": true, "gateway": {"mode": "gateway", "online": true}});
    assert_eq!(
        status_answer(true, &ok),
        json!({"ok": true, "scope": "personal", "gateway": {"mode": "gateway", "online": true},
               "serves": ["claude", "codex"]})
    );
    // Only a gateway in mode `gateway` that is online serves (hq#15762's start gate reads `serves`).
    for gateway in [
        json!({"mode": "gateway", "online": false}),
        json!({"mode": "off", "online": true}),
        // `joined` takes only hub-joined machines' calls: a Cloud chat is not served.
        json!({"mode": "joined", "online": true}),
        json!({}),
    ] {
        let answer = status_answer(false, &json!({"ok": true, "gateway": gateway}));
        assert_eq!(answer["serves"], json!([]), "{answer}");
        assert_eq!(answer["scope"], "team");
    }
    let refused = json!({"ok": false, "error": {"code": "auth.forbidden", "message": "no"}});
    assert_eq!(status_answer(false, &refused), error_json("auth.forbidden", "no"));
    assert_eq!(route_path(true), "/v1/cloud/inference-gateway/personal");
}

#[test]
fn reads_the_machine_probe() {
    let body = r#"{"ok":true,"route":"owner_gateway","agent":"claude"}"#;
    assert_eq!(probe_answer("vm_x", "claude", &format!("{body}\n200"))["route"], "owner_gateway");
    assert_eq!(probe_answer("vm_x", "codex", "not found\n404")["route"], "shared_coderouter");
    assert_eq!(probe_answer("vm_x", "codex", "\n000")["error"]["code"], "machine.edge_unreachable");
    let err = r#"{"error":{"code":"inference.keys_unreachable","message":"retry"}}"#;
    assert_eq!(
        probe_answer("vm_x", "codex", &format!("{err}\n503"))["error"]["code"],
        "inference.keys_unreachable"
    );
    assert!(probe_command("claude").ends_with("/v1/cmux/route?agent=claude'"));
    assert!(!probe_command("claude").contains("x-cmux-inference-authorization"));
}

/// The app runs `inference gateway status` with its own environment, which names no API (hq#15762): with the app's
/// token the verb asks the API that issued it; any other token still needs `--api`.
#[test]
fn status_with_no_api_asks_the_api_that_issued_the_apps_token() {
    let none = |_: &str| None;
    let (c, v) = parse(&words(&["status"]), &none).unwrap();
    assert_eq!((c.api, c.token, v), (None, TokenSource::App, Verb::Status { personal: false }));
    let token_env = |k: &str| (k == "CMUX_CLOUD_ACCESS_TOKEN").then(|| "tok".to_owned());
    assert!(parse(&words(&["status"]), &token_env).unwrap_err().contains("--api"));
    assert!(
        parse(&words(&["status", "--token-file", "/tmp/t"]), &none).unwrap_err().contains("--api")
    );

    assert_eq!(
        api_origin(None, Some("https://cloud-api.cmux.test")).unwrap(),
        "https://cloud-api.cmux.test"
    );
    assert_eq!(
        api_origin(Some("https://api.cmux.test"), Some("https://cloud-api.cmux.test")).unwrap(),
        "https://api.cmux.test",
    );
    assert!(api_origin(None, Some("http://cloud-api.cmux.test")).is_err());
    assert!(api_origin(None, None).unwrap_err().contains("named none"));
}

#[test]
fn a_token_answer_gives_its_token_and_the_api_that_issued_it() {
    use super::super::inference_gateway::credential_answer;
    assert_eq!(credential_answer(" tok \n"), ("tok".to_owned(), None));
    assert_eq!(
        credential_answer(
            r#"{"access_token":"tok","api_origin":"https://cloud-api.cmux.test","team":"t"}"#
        ),
        ("tok".to_owned(), Some("https://cloud-api.cmux.test".to_owned())),
    );
    assert_eq!(
        credential_answer(r#"{"access_token":"tok","api_origin":""}"#),
        ("tok".to_owned(), None)
    );
}

/// The cmux API the person names with `--api` passes the egress gate in enforce mode; a
/// host nobody named is still refused.
#[test]
fn the_named_api_passes_the_gate() {
    cmux_egress::set_mode(cmux_egress::Mode::Enforce);
    let host = "api-gateway-admin-test.org";
    assert!(cmux_egress::check(host, "test").is_err());
    let api = format!("https://{host}");
    assert!(parse(&words(&["status", "--personal", "--api", &api]), &env).is_ok());
    assert!(cmux_egress::check(host, "test").is_ok());
    assert!(cmux_egress::check("unrelated-api-gateway-admin-test.org", "test").is_err());
}
