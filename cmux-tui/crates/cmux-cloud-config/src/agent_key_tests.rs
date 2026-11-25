use serde_json::{Map, Value, json};

use super::*;

fn params(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => unreachable!("an object"),
    }
}

#[test]
fn the_body_asks_only_for_vm_scopes_whatever_was_sent() {
    let body = body(&params(json!({"scopes": ["team:admin"], "name": "ci"}))).expect("body");
    assert_eq!(body, json!({"name": "ci", "scopes": ["vm:read", "vm:write", "vm:exec"]}));
}

#[test]
fn a_blank_or_long_name_is_defaulted_or_cut() {
    assert_eq!(body(&params(json!({}))).expect("body")["name"], DEFAULT_NAME);
    assert_eq!(body(&params(json!({"name": ""}))).expect("body")["name"], DEFAULT_NAME);
    let long = "x".repeat(250);
    assert_eq!(
        body(&params(json!({"name": long}))).expect("body")["name"].as_str().map(str::len),
        Some(200)
    );
}

#[test]
fn limits_in_range_are_kept_and_others_refused_never_dropped() {
    let body = body(&params(json!({"ttlSeconds": 60.0, "maxVms": 20, "maxUsdPerHour": 50})))
        .expect("body");
    assert_eq!(
        (body["ttlSeconds"].clone(), body["maxVms"].clone(), body["maxUsdPerHour"].clone()),
        (json!(60), json!(20), json!(50.0))
    );
    for (name, value) in [
        ("ttlSeconds", json!(59)),
        ("ttlSeconds", json!(86_401)),
        ("ttlSeconds", json!(90.5)),
        ("ttlSeconds", json!("60")),
        ("maxVms", json!(0)),
        ("maxVms", json!(21)),
        ("maxVms", json!(-1)),
        ("maxUsdPerHour", json!(0)),
        ("maxUsdPerHour", json!(50.01)),
        ("maxUsdPerHour", json!(null)),
    ] {
        let mut sent = Map::new();
        sent.insert(name.to_owned(), value.clone());
        let refusal = super::body(&sent).expect_err(&format!("{name}={value}"));
        assert_eq!(refusal.code, "invalid_params");
        assert_eq!(refusal.message, format!("{name} is out of range"));
    }
}

#[test]
fn the_request_goes_only_to_this_builds_vm_api() {
    let production = request(&Backend::Production, &Map::new()).expect("request");
    assert_eq!(production.url, "https://vm.cmux.dev/v1/agent-keys");
    assert_eq!(production.base_url, "https://vm.cmux.dev");
    for backend in [
        Backend::Development("https://cmux-staging.vercel.app".into()),
        Backend::LocalOnly("http://localhost:3777".into()),
    ] {
        assert_eq!(
            request(&backend, &Map::new()).expect("request").url,
            "https://vm-staging.cmux.dev/v1/agent-keys"
        );
    }
}

#[test]
fn a_minted_key_comes_back_with_where_it_works() {
    let created = br#"{"key":"vmk_secret","id":"vmk_1","expiresAt":"2026-11-05T00:00:00Z"}"#;
    let answer = answer(201, created, "https://vm-staging.cmux.dev", "team_1").expect("minted");
    assert_eq!(answer["id"], "vmk_1");
    assert_eq!(answer["baseUrl"], "https://vm-staging.cmux.dev");
    assert_eq!(answer["teamId"], "team_1");
}

#[test]
fn a_refusal_names_its_code_and_never_the_key() {
    let read = |status: u16, body: &str| {
        answer(status, body.as_bytes(), "https://vm.cmux.dev", "t").expect_err("refused")
    };
    let no_key = read(200, r#"{"id":"vmk_1"}"#);
    assert_eq!((no_key.code.as_str(), no_key.status), ("unavailable", Some(200)));
    let signed_out = read(401, r#"{"message":"expired"}"#);
    assert_eq!(
        (signed_out.code.as_str(), signed_out.app_text.as_deref()),
        ("not_signed_in", Some("notSignedIn"))
    );
    assert_eq!(
        read(402, r#"{"message":"upgrade"}"#),
        Refusal::new("plan_required", "upgrade", None)
    );
    assert_eq!(read(403, r#"{"message":"no"}"#).code, "forbidden");
    assert_eq!(read(400, r#"{"message":"bad"}"#).code, "invalid_params");
    assert_eq!(read(429, r#"{"message":"slow"}"#).code, "rate_limited");
    let down = read(503, "<html>");
    assert_eq!(
        (down.code.as_str(), down.message.as_str(), down.status),
        ("unavailable", "HTTP 503", Some(503))
    );
    let long = read(500, &format!(r#"{{"message":"{}"}}"#, "m".repeat(400)));
    assert_eq!(long.message.len(), 300);
    let none = read(0, "");
    assert_eq!(
        (none.code.as_str(), none.status, none.app_text.as_deref()),
        ("unavailable", Some(0), Some("unreachable"))
    );
    let leaked = read(500, r#"{"key":"vmk_secret","message":"half"}"#);
    assert!(!format!("{leaked:?}").contains("vmk_secret"));
}

#[test]
fn an_app_refusal_reads_as_the_clis_outcome() {
    assert_eq!(outcome("no_team", None), Outcome::Network);
    assert_eq!(outcome("not_signed_in", None), Outcome::Unauthenticated);
    assert_eq!(outcome("plan_required", None), Outcome::PaymentRequired);
    assert_eq!(outcome("forbidden", None), Outcome::Forbidden);
    assert_eq!(outcome("rate_limited", None), Outcome::QuotaExceeded);
    assert_eq!(outcome("invalid_params", None), Outcome::Usage);
    assert_eq!(outcome("method_not_found", None), Outcome::MethodNotFound);
    assert_eq!(outcome("unavailable", None), Outcome::Network);
    assert_eq!(outcome("unavailable", Some(0)), Outcome::Network);
    assert_eq!(outcome("unavailable", Some(502)), Outcome::ServiceUnavailable);
    assert_eq!(outcome("unavailable", Some(404)), Outcome::Status(404));
    assert_eq!(outcome("anything", None), Outcome::Unexpected);
}

#[test]
fn a_refusal_never_carries_a_key_the_service_put_in_its_text() {
    let read = |status: u16, body: &str| {
        answer(status, body.as_bytes(), "https://vm.cmux.dev", "t").expect_err("refused")
    };
    let echoed = read(500, r#"{"key":"vmk_secret","message":"could not store vmk_secret"}"#);
    assert_eq!(echoed.message, "could not store <redacted>");
    let shaped = read(400, r#"{"message":"bad cmuxvm_sk_abcDEF012_-xyz, and cmuxvm_sk_second."}"#);
    assert_eq!(shaped.message, "bad cmuxvm_sk_<redacted>, and cmuxvm_sk_<redacted>.");
    assert_eq!(read(403, r#"{"message":"cmuxvm_sk_"}"#).message, "cmuxvm_sk_<redacted>");
}
