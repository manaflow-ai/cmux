use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn list_allow_and_deny_parse_to_the_services_args() {
    assert_eq!(
        parse(&words("list --mac Studio")).unwrap(),
        Request::List { mac: Some("Studio".into()) }
    );
    let allow =
        parse(&words("allow probe-id --fingerprint ABCDEF0123456789 --mac=Studio")).unwrap();
    assert_eq!(
        allow.args(),
        json!({"action": "answer", "deviceId": "probe-id", "fingerprint": "abcdef0123456789", "allow": true})
    );
    let deny = parse(&words("deny probe-id --mac Studio --fingerprint abcdef01")).unwrap();
    assert_eq!(deny.args()["allow"], false);
    assert_eq!(parse(&words("list --mac Studio")).unwrap().args(), json!({"action": "list"}));
}

#[test]
fn an_answer_names_its_key_and_its_mac() {
    // The fingerprint is required so an answer cannot land on other keys under the same id.
    assert!(
        parse(&words("allow probe-id --mac Studio"))
            .unwrap_err()
            .contains("--fingerprint is required")
    );
    assert!(
        parse(&words("allow probe-id --fingerprint abc --mac Studio")).unwrap_err().contains("hex")
    );
    assert!(
        parse(&words("allow probe-id --fingerprint zzzzzzzz --mac Studio"))
            .unwrap_err()
            .contains("hex")
    );
    assert!(
        parse(&words("allow --fingerprint abcdef01 --mac Studio"))
            .unwrap_err()
            .contains("one device id")
    );
    assert!(parse(&words("list --mac")).unwrap_err().contains("needs a value"));
    assert!(parse(&words("approve x --mac Studio")).unwrap_err().contains("unknown verb"));
    assert!(parse(&words("list --mac Studio --force")).unwrap_err().contains("unknown option"));
}

#[test]
fn every_refusal_says_what_to_do_next() {
    for (code, next) in [
        ("unpaired", "cmux machine Studio doctor"),
        ("not_granted", "Control"),
        ("revoked", "cmux machine Studio doctor"),
        ("forbidden", "another of your paired devices"),
        ("fingerprint_mismatch", "cmux mobile pair-requests list --mac Studio"),
        ("no_waiting_request", "Start pairing on that device again"),
        ("unavailable", "Open the cmux app on Studio"),
        ("unknown_service", "pair-requests-v1"),
    ] {
        let (full, text) = explain(code, "why", "Studio", " --mac Studio");
        assert_eq!(full, format!("pair_requests.{code}"));
        assert!(text.contains(next), "{code}: {text}");
    }
}

#[test]
fn the_list_shows_each_request_and_the_command_that_answers_it() {
    let request = Request::List { mac: Some("Studio".into()) };
    let answer = json!({"requests": [{"deviceId": "probe-id", "name": "Probe iPhone", "kind": "phone",
                                      "fingerprint": "0123456789abcdef", "waitingMs": 12_500}]});
    let text = human(&request, &answer, "Studio");
    assert!(
        text.contains("probe-id") && text.contains("Probe iPhone") && text.contains("12s"),
        "{text}"
    );
    assert!(
        text.contains(
            "cmux mobile pair-requests allow probe-id --fingerprint 0123456789abcdef --mac Studio"
        ),
        "{text}"
    );
    assert_eq!(
        human(&request, &json!({"requests": []}), "Studio"),
        "no pairing request is waiting on Studio\n"
    );
}

#[test]
fn without_mac_the_command_is_for_this_mac() {
    assert_eq!(parse(&words("list")).unwrap(), Request::List { mac: None });
    let allow = parse(&words("allow probe-id --fingerprint abcdef01")).unwrap();
    assert_eq!(
        allow,
        Request::Answer {
            mac: None,
            device_id: "probe-id".into(),
            fingerprint: "abcdef01".into(),
            allow: true
        }
    );
    assert_eq!(allow.args()["fingerprint"], "abcdef01");
    // The fingerprint stays required on this Mac too.
    assert!(parse(&words("allow probe-id")).unwrap_err().contains("--fingerprint is required"));
    assert!(parse(&words("deny probe-id --fingerprint xyz")).unwrap_err().contains("hex"));
    assert!(parse(&words("list --mac=")).unwrap_err().contains("leave it out for this Mac"));
}

#[test]
fn a_mac_naming_this_one_takes_the_local_path() {
    let machines = vec![
        json!({"device_id": "D-THIS", "name": "Mini", "machine_id": "m-this-1", "this": true}),
        json!({"device_id": "D-OTHER", "name": "Studio", "machine_id": "m-other", "this": false}),
    ];
    for name in ["Mini", "MINI", "d-this", "m-this"] {
        assert!(names_this_mac(&machines, name), "{name}");
    }
    for name in ["Studio", "D-OTHER", "", "m-other"] {
        assert!(!names_this_mac(&machines, name), "{name}");
    }
    assert!(!names_this_mac(&[], "Mini"));
}

#[test]
fn this_macs_list_and_refusals_name_commands_without_mac() {
    let request = Request::List { mac: None };
    let answer = json!({"requests": [{"deviceId": "probe-id", "name": "Probe iPhone", "kind": "phone",
                                      "fingerprint": "0123456789abcdef", "waitingMs": 1_000}]});
    let text = human(&request, &answer, "this Mac");
    assert!(
        text.ends_with("cmux mobile pair-requests allow probe-id --fingerprint 0123456789abcdef\n"),
        "{text}"
    );
    let (_, text) = explain("fingerprint_mismatch", "why", "this Mac", &mac_flag(None));
    assert!(text.contains("Run `cmux mobile pair-requests list` again"), "{text}");
    // The service's own refusal on this Mac is passed on with its next step.
    let (code, text) = explain(
        "forbidden",
        "a device cannot answer its own pairing request",
        "this Mac",
        &mac_flag(None),
    );
    assert_eq!(code, "pair_requests.forbidden");
    assert!(text.contains("another of your paired devices"), "{text}");
}

#[test]
fn an_older_hostd_without_the_local_op_says_to_update() {
    let old = json!({"error": "bad_request", "message": "op is machines, open or traffic"});
    let answer = local_answer(old);
    assert_eq!(answer["error"], "local_unsupported");
    let (_, text) = explain("local_unsupported", "op is machines, open or traffic", "this Mac", "");
    assert!(text.contains("Click Allow") && text.contains("--mac"), "{text}");
    // Any other answer, a refusal of the service included, is passed on as is.
    let refusal = json!({"error": "bad_request", "message": "expected deviceId and fingerprint"});
    assert_eq!(local_answer(refusal.clone()), refusal);
    assert_eq!(local_answer(json!({"ok": true})), json!({"ok": true}));
}
