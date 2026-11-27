use std::time::Duration;

use serde_json::{Value, json};

use super::*;

fn consent(signed_in: &str, answered: bool) -> Value {
    let mut consent = json!({"screen": "none", "control": "none", "signedInMachines": signed_in});
    if answered {
        consent["signedInMachinesAnsweredAt"] = json!("1");
        consent["signedInMachinesUser"] = json!("user-1");
    }
    json!({"consentRequired": true, "consent": consent})
}

#[test]
fn machine_call_needs_the_signed_in_machines_grant() {
    // Nothing answered: refused, and it is the machine's one ask.
    let (refusal, ask) = decide(&consent("none", false), Some("user-1")).unwrap_err();
    assert_eq!(refusal.reason, CONSENT_REQUIRED);
    assert!(refusal.message.contains("allow control"), "{refusal}");
    assert!(ask);
    // Not now: refused, no new ask.
    let (refusal, ask) = decide(&consent("none", true), Some("user-1")).unwrap_err();
    assert_eq!(refusal.reason, CONSENT_DECLINED);
    assert!(!ask);
    // Control from elsewhere alone admits nothing.
    let control = json!({"consentRequired": true, "consent": {"control": "granted"}});
    assert!(decide(&control, Some("user-1")).is_err());
    // The grant admits, for the account it was given for only.
    assert!(decide(&consent("granted", true), Some("user-1")).is_ok());
    assert!(decide(&consent("granted", true), Some("user-2")).is_err());
    assert!(decide(&consent("granted", true), None).is_err());
}

#[test]
fn machine_key_names_one_listed_machine_or_none() {
    let machines = vec![
        ("key-a".to_owned(), "studio".to_owned()),
        ("key-b".to_owned(), "laptop".to_owned()),
        ("key-c".to_owned(), "laptop".to_owned()),
    ];
    assert_eq!(machine_key(&machines, "studio").as_deref(), Some("key-a"));
    assert_eq!(machine_key(&machines, "key-b").as_deref(), Some("key-b"));
    // Two machines with one host name: neither is picked for the other.
    assert_eq!(machine_key(&machines, "laptop"), None);
    assert_eq!(machine_key(&machines, "elsewhere"), None);
}

async fn fake(method: String, params: Value) -> Result<Value, RpcError> {
    match method.as_str() {
        COMPUTER_USE_STATE => Ok(json!({"state": "on"})),
        _ if params["name"] == "boom" => {
            Err(RpcError::invalid_params("denied").with_data(json!({"code": "policy_denied"})))
        }
        _ => Ok(json!({"result": {"echo": params}})),
    }
}

#[tokio::test]
async fn machine_call_answers_each_request_and_keeps_the_far_error() {
    let (near, far) = tokio::io::duplex(1024);
    tokio::spawn(serve(far, fake));
    let state = ask(near, COMPUTER_USE_STATE, json!({}), Duration::from_secs(5)).await.unwrap();
    assert_eq!(state, json!({"state": "on"}));

    let (near, far) = tokio::io::duplex(1024);
    tokio::spawn(serve(far, fake));
    let error = ask(near, COMPUTER_USE_CALL, json!({"name": "boom"}), Duration::from_secs(5))
        .await
        .unwrap_err()
        .expect("the far end's error");
    assert_eq!(error.data, Some(json!({"code": "policy_denied"})));
}

#[tokio::test]
async fn machine_call_carries_an_answer_larger_than_the_pipe() {
    let (near, far) = tokio::io::duplex(1024);
    tokio::spawn(serve(far, fake));
    let big = "x".repeat(300_000);
    let answer =
        ask(near, COMPUTER_USE_CALL, json!({"name": "shot", "data": big}), Duration::from_secs(5))
            .await
            .unwrap();
    assert_eq!(answer["result"]["echo"]["data"].as_str().map(str::len), Some(300_000));
}

#[tokio::test]
async fn machine_call_refuses_a_method_it_does_not_list_and_ends_on_a_bad_line() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let (near, far) = tokio::io::duplex(1024);
    tokio::spawn(serve(far, fake));
    let error = ask(near, "exec", json!({"argv": ["sh"]}), Duration::from_secs(5))
        .await
        .unwrap_err()
        .expect("a refusal");
    assert_eq!(error.code, -32601);

    let (mut near, far) = tokio::io::duplex(1024);
    tokio::spawn(serve(far, fake));
    near.write_all(b"not json\n").await.unwrap();
    let mut rest = Vec::new();
    near.read_to_end(&mut rest).await.unwrap();
    assert!(rest.is_empty(), "a bad line gets no answer and ends the circuit");
}

#[tokio::test]
async fn machine_call_with_no_answer_in_time_is_none() {
    let (near, _far) = tokio::io::duplex(1024);
    let silent = ask(near, COMPUTER_USE_STATE, json!({}), Duration::from_millis(50)).await;
    assert!(matches!(silent, Err(None)));
}

#[tokio::test]
async fn machine_call_lists_ports_and_still_refuses_unlisted_port_verbs() {
    async fn ports(method: String, _params: Value) -> Result<Value, RpcError> {
        assert_eq!(method, PORTS_LIST);
        crate::listening_ports::answer(Some(vec![5173]))
    }
    let (near, far) = tokio::io::duplex(1024);
    tokio::spawn(serve(far, ports));
    let listed = ask(near, PORTS_LIST, json!({}), Duration::from_secs(5)).await.unwrap();
    assert_eq!(listed, json!({"ports": [{"port": 5173}]}));
    // Read-only: no forward, open or kill verb rides along.
    for method in ["ports_forward", "ports_open", "ports_kill"] {
        assert!(!METHODS.contains(&method));
        let (near, far) = tokio::io::duplex(1024);
        tokio::spawn(serve(far, ports));
        let error = ask(near, method, json!({}), Duration::from_secs(5))
            .await
            .unwrap_err()
            .expect("a refusal");
        assert_eq!(error.code, -32601);
    }
}
