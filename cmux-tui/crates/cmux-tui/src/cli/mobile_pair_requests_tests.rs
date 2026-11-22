use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn list_allow_and_deny_parse_to_the_services_args() {
    assert_eq!(parse(&words("list --mac Studio")).unwrap(), Request::List { mac: "Studio".into() });
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
    assert!(parse(&words("list")).unwrap_err().contains("--mac"));
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
        let (full, text) = explain(code, "why", "Studio");
        assert_eq!(full, format!("pair_requests.{code}"));
        assert!(text.contains(next), "{code}: {text}");
    }
}

#[test]
fn the_list_shows_each_request_and_the_command_that_answers_it() {
    let request = Request::List { mac: "Studio".into() };
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
