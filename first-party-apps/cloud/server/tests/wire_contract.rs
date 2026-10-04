//! The vectors against the backend's declared error lists (backend answer
//! a1c6283b256 (b) and (c)), and `cloud.machine.connect_info` as contract
//! section 1.7 shapes it.
//!
//! (b) A backend op answers only the error codes its catalog row declares.
//! Every error case of `backend/catalog/cloud-vectors.json` uses a declared
//! code, and the client turns an undeclared code into the typed
//! `cmux.cloud.protocol_error` instead of guessing a meaning.
//! (c) `mutation.indeterminate` is retryable (with the same key).

mod wire_common;

use cmux_cloud::{CloudError, Request, Server};
use serde_json::{Value, json};
use wire_common::{WireFake, host, vm};

fn errors_of(case: &Value) -> Vec<Value> {
    case["responses"]
        .as_array()
        .expect("responses")
        .iter()
        .filter_map(|r| {
            let body = &r["body"];
            if r["http"]["status"] != 200 {
                Some(json!({ "code": body["code"], "retryable": body["retryable"] }))
            } else if body["ok"] == false {
                Some(body["error"].clone())
            } else {
                None
            }
        })
        .collect()
}

fn err_json(out: Result<Value, CloudError>) -> Value {
    match out {
        Ok(v) => json!({ "unexpected_ok": v }),
        Err(e) => serde_json::to_value(&e).expect("error"),
    }
}

#[test]
fn every_vector_error_is_declared_by_its_op() {
    let doc = wire_common::vectors();
    let mut undeclared = Vec::new();
    for case in doc["cases"].as_array().expect("cases") {
        let op = case["op"].as_str().expect("op");
        let declared = cmux_cloud::ops::declared_errors(op);
        for error in errors_of(case) {
            let code = error["code"].as_str().expect("code").to_owned();
            if !declared.is_some_and(|d| d.contains(&code.as_str())) {
                undeclared.push(format!("{} ({op}): {code}", case["name"]));
            }
        }
    }
    assert!(undeclared.is_empty(), "codes the op does not declare: {undeclared:#?}");
}

#[test]
fn mutation_indeterminate_is_retryable_in_the_vectors() {
    let doc = wire_common::vectors();
    let mut seen = 0;
    for case in doc["cases"].as_array().expect("cases") {
        for error in errors_of(case) {
            if error["code"] == "mutation.indeterminate" {
                seen += 1;
                assert_eq!(error["retryable"], true, "{}", case["name"]);
            }
        }
    }
    assert!(seen >= 2, "the vectors keep their cut-off cases");
}

#[test]
fn an_undeclared_backend_code_is_a_protocol_error() {
    let mut s = Server::new(WireFake::load());
    s.control_plane_mut().answer(
        "cloud.machine.get",
        json!({ "machine": vm(1) }),
        None,
        json!({ "error": { "code": "cloud.machine.paused", "message": "paused", "retryable": false } }),
    );
    let out = err_json(s.handle(&Request::new("cloud.machine.get", json!({ "machine": vm(1) }))));
    assert_eq!(out["code"], "cmux.cloud.protocol_error", "{out}");
    assert_eq!(out["upstream_code"], "cloud.machine.paused");
    assert_eq!(out["retryable"], false);
}

#[test]
fn connect_info_follows_section_1_7() {
    let mut s = Server::new(WireFake::load());
    let info = s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(1) })));
    assert!(info.is_ok(), "{info:?}");
    let info = info.unwrap();
    for field in
        ["machine", "host", "epoch", "state", "peer", "gateway", "services", "daemon", "revision"]
    {
        assert!(info.get(field).is_some(), "{field} in {info}");
    }
    assert_eq!(info["host"], host(1));
    assert_eq!(info["services"], json!(["daemon", "ssh"]));
    assert!(info.get("link_token").is_none(), "the link token stays with cmux link: {info}");

    let by_host = s.handle(&Request::new("cloud.machine.connect_info", json!({ "host": host(1) })));
    assert_eq!(by_host.map(|v| v["machine"].clone()), Ok(json!(vm(1))));

    // A paused machine is not an error: the state says paused.
    let paused = s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(2) })));
    assert_eq!(paused.map(|v| v["state"].clone()), Ok(json!("paused")));

    let unbound = err_json(
        s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(4) }))),
    );
    assert_eq!(unbound["code"], "cmux.cloud.not_bound", "{unbound}");

    let calls = s.control_plane().calls.len();
    for bad in [json!({}), json!({ "machine": vm(1), "host": host(1) })] {
        let out = err_json(s.handle(&Request::new("cloud.machine.connect_info", bad.clone())));
        assert_eq!(out["code"], "cmux.cloud.invalid_args", "{bad}");
    }
    assert_eq!(s.control_plane().calls.len(), calls, "refused before any call");
}

/// Read ops never mint credentials: the dial token comes only from the
/// mutation `cloud.machine.link_token`, which only `cmux link` calls.
#[test]
fn no_read_vector_carries_a_link_token() {
    let doc = wire_common::vectors();
    for case in doc["cases"].as_array().expect("cases") {
        if case["class"] != "read" {
            continue;
        }
        for response in case["responses"].as_array().expect("responses") {
            let text = response["body"]["value"].to_string();
            assert!(!text.contains("link_token"), "{}: {text}", case["name"]);
        }
    }
}

#[test]
fn a_connect_info_answer_with_a_link_token_is_a_bad_response() {
    let mut s = Server::new(WireFake::load());
    let doc = wire_common::vectors();
    let mut value = doc["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .find(|c| c["name"] == "machine.connect_info")
        .expect("case")["responses"][0]["body"]["value"]
        .clone();
    value["link_token"] = json!({ "token": "lt_leak", "expires_at": 1 });
    s.control_plane_mut().answer(
        "cloud.machine.connect_info",
        json!({ "machine": vm(1) }),
        None,
        value,
    );
    let out = err_json(
        s.handle(&Request::new("cloud.machine.connect_info", json!({ "machine": vm(1) }))),
    );
    assert_eq!(out["code"], "cmux.cloud.bad_response", "{out}");
    assert!(!out.to_string().contains("lt_leak"), "the token is never echoed: {out}");
}

/// `cloud.machine.link_token` has no idempotency key: each call mints a
/// fresh token and nothing replays (LINK-TOKEN-OP).
#[test]
fn link_token_vectors_mint_a_fresh_token_per_call() {
    let doc = wire_common::vectors();
    let cases: Vec<&Value> = doc["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .filter(|c| c["op"] == "cloud.machine.link_token")
        .collect();
    assert!(!cases.is_empty());
    for case in cases {
        assert_eq!(case["class"], "mutation", "{}", case["name"]);
        assert!(case.get("idempotency_key").is_none(), "{}: no key", case["name"]);
        let tokens: Vec<&Value> = case["responses"]
            .as_array()
            .expect("responses")
            .iter()
            .filter_map(|r| r["body"]["value"].get("token"))
            .collect();
        let unique: std::collections::BTreeSet<String> =
            tokens.iter().map(|t| t.to_string()).collect();
        assert_eq!(unique.len(), tokens.len(), "{}: a fresh token each call", case["name"]);
        for r in case["responses"].as_array().expect("responses") {
            assert_ne!(r["body"]["replayed"], true, "{}: nothing replays", case["name"]);
        }
    }
}
