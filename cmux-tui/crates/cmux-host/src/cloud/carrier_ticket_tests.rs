use serde_json::json;

use super::*;

const SLOT: &str = "AAAAAAAAAAAAAAAAAAAAAA";

fn platform(value: Value) -> Answer {
    Answer::Http { status: 200, body: json!({"ok": true, "value": value}) }
}

#[test]
fn the_ask_takes_no_fields_and_names_the_machines_route() {
    assert_eq!(REQUEST_KEY, "carrier_ticket");
    assert_eq!(check_ask(&json!({})), Ok(()));
    assert_eq!(check_ask(&Value::Null), Ok(()));
    assert!(check_ask(&json!({"machine": "vm_other"})).is_err());
    assert_eq!(
        path("vm_0123456789abcdefghij"),
        "/v1/cloud/machines/vm_0123456789abcdefghij/carrier"
    );
}

#[test]
fn a_platform_ticket_is_relayed_and_printed_alone() {
    let reply = reply_for(&platform(json!({
        "relay": "relay+do://relay.cmux.dev",
        "slot": SLOT,
        "ticket": "v1.abc.def",
        "expires_at": 1_800_000_060u64,
        "extra": "dropped",
    })));
    assert_eq!(
        reply,
        json!({
            "ok": true,
            "relay": "relay+do://relay.cmux.dev",
            "slot": SLOT,
            "ticket": "v1.abc.def",
            "expires_at": 1_800_000_060u64,
        })
    );
    assert_eq!(ticket_of(&reply), Ok("v1.abc.def".to_owned()));
}

#[test]
fn a_bad_or_failed_answer_is_a_refusal_with_no_ticket() {
    let good = json!({
        "relay": "relay+do://relay.cmux.dev",
        "slot": SLOT,
        "ticket": "v1.abc",
        "expires_at": 1,
    });
    let mut cases = vec![
        Answer::Transport,
        Answer::Http { status: 403, body: json!({}) },
        Answer::Http { status: 404, body: json!({}) },
        Answer::Http { status: 429, body: json!({}) },
        Answer::Http { status: 503, body: json!({}) },
        Answer::Http { status: 200, body: json!({"ok": false, "value": good}) },
    ];
    for (field, bad) in [
        ("relay", json!("relay+wss://relay.cmux.dev")),
        ("slot", json!("short")),
        ("ticket", json!("has space")),
        ("ticket", json!("")),
        ("expires_at", json!("soon")),
    ] {
        let mut value = good.clone();
        value[field] = bad;
        cases.push(platform(value));
    }
    for answer in cases {
        let reply = reply_for(&answer);
        assert_eq!(reply["ok"], false, "{answer:?}");
        assert!(reply.get("ticket").is_none());
        assert!(ticket_of(&reply).is_err());
    }
}

#[test]
fn a_refusal_prints_its_code_and_message() {
    let refused = refusal("vm.unbound", "this machine is not bound to cmux Cloud yet");
    assert_eq!(
        ticket_of(&refused),
        Err("vm.unbound: this machine is not bound to cmux Cloud yet".to_owned())
    );
}

#[test]
fn every_refusal_leads_with_a_dotted_code() {
    let mut replies: Vec<Value> = [
        Answer::Transport,
        Answer::Http { status: 401, body: json!({}) },
        Answer::Http { status: 404, body: json!({}) },
        Answer::Http { status: 429, body: json!({}) },
        Answer::Http { status: 503, body: json!({}) },
        platform(json!({})),
    ]
    .iter()
    .map(reply_for)
    .collect();
    replies.push(refusal("busy", "too many asks are waiting; retry"));
    replies.push(refusal("vm.agent_stopping", "the Cloud agent is stopping; retry"));
    replies.push(json!({"ok": false}));
    replies.push(refusal("Not A Code!", "odd"));
    let mut printed = Vec::new();
    for reply in &replies {
        let why = ticket_of(reply).unwrap_err();
        let (code, _) = why.split_once(": ").unwrap();
        assert!(
            code.contains('.')
                && code.split('.').all(|part| {
                    !part.is_empty()
                        && part.bytes().all(|byte| byte.is_ascii_lowercase() || byte == b'_')
                }),
            "{why}"
        );
        printed.push(code.to_owned());
    }
    assert_eq!(
        printed,
        [
            "carrier.unreachable",
            "auth.refused",
            "carrier.unavailable",
            "carrier.rate_limited",
            "carrier.unavailable",
            "carrier.bad_answer",
            "carrier.busy",
            "vm.agent_stopping",
            "carrier.bad_answer",
            "carrier.bad_answer",
        ]
    );
}
