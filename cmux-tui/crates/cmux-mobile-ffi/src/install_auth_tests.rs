//! The phone binding answers as the Mac's `cloud_identity_install_auth_step` does: the same
//! machine, the same JSON, one mint walked end to end through strings.

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use serde_json::{Value, json};

use super::*;

const NOW: f64 = 1_800_000_000_000.0;
const NONCE: &str = "nonce-0123456789abcdef";

fn call(operation: &str, request: &Value) -> Value {
    let answer = install_auth_json(operation.into(), request.to_string()).expect("answers");
    serde_json::from_str(&answer).unwrap()
}

/// What the Mac's C ABI answers for the same step (cmux-layout-reducer-ffi's
/// `cloud_identity_install_auth_step` passes the machine's output through as JSON).
fn mac(request: &Value) -> Value {
    let state: Option<State> = serde_json::from_value(request["state"].clone()).unwrap();
    let event: Event = serde_json::from_value(request["event"].clone()).unwrap();
    let (state, effect) = install_auth::step(state, event, request["now_ms"].as_f64().unwrap());
    json!({ "state": state, "effect": effect })
}

fn jwt(claims: &Value) -> String {
    format!("h.{}.s", URL_SAFE_NO_PAD.encode(serde_json::to_vec(claims).unwrap()))
}

fn start(record: Value) -> Value {
    json!({
        "event": "start", "mode": "mint", "stack_user": "stack-1", "team": null,
        "environment": null, "device_name": "Leo's iPhone",
        "profile": call("profile", &json!({ "kind": "ios" })),
        "client_version": "1.2.3", "record": record, "has_session": true,
        "fresh_ids": ["id-a", "id-b"],
    })
}

/// Sends `event`, checks the phone and the Mac answer alike, and returns the effect.
fn go(state: &mut Value, event: Value) -> Value {
    let request = json!({ "state": state.clone(), "event": event, "now_ms": NOW });
    let answer = call("step", &request);
    assert_eq!(answer, mac(&request), "the phone answers as the Mac");
    *state = answer["state"].clone();
    answer["effect"].clone()
}

#[test]
fn a_registered_install_mints_through_the_binding() {
    let mut state = Value::Null;
    let effect = go(&mut state, start(json!({ "user": "user_1", "install": "inst_1" })));
    assert_eq!(effect["effect"], "post");
    assert_eq!(effect["path"], "/v1/auth/challenge");
    assert_eq!(effect["headers"], json!({ "x-cmux-client-version": "1.2.3" }));
    assert_eq!(
        serde_json::from_str::<Value>(effect["body"].as_str().unwrap()).unwrap(),
        json!({ "user": "user_1", "install": "inst_1" })
    );

    let prefix = "cmux-auth-v1\nstaging\ninst_1\n";
    let reply = json!({ "nonce": NONCE, "message_prefix": prefix });
    let effect =
        go(&mut state, json!({ "event": "http", "status": 200, "body": reply.to_string() }));
    assert_eq!(effect, json!({ "effect": "sign", "message": format!("{prefix}{NONCE}") }));

    let signature = STANDARD.encode([7u8; 64]);
    let effect = go(&mut state, json!({ "event": "signature", "signature": signature }));
    assert_eq!(effect["path"], "/v1/auth/token");
    let body: Value = serde_json::from_str(effect["body"].as_str().unwrap()).unwrap();
    assert_eq!(body["nonce"], NONCE);
    assert_eq!(body["signature"], URL_SAFE_NO_PAD.encode([7u8; 64]));

    let token = jwt(&json!({ "iss": "https://cmux-api/staging" }));
    let reply = json!({ "access_token": token, "expires_at": NOW + 3_600_000.0 });
    let effect =
        go(&mut state, json!({ "event": "http", "status": 200, "body": reply.to_string() }));
    assert_eq!(effect["effect"], "done");
    assert_eq!(effect["token"], token.as_str());
    assert_eq!(effect["environment"], "staging");
    // Never trusted past nine minutes, whatever the owner says.
    assert_eq!(effect["expires_at_ms"], json!(NOW + 540_000.0));
}

#[test]
fn a_refusal_is_an_answer_not_an_error() {
    let mut state = Value::Null;
    go(&mut state, start(json!({ "user": "user_1", "install": "inst_1" })));
    let effect = go(
        &mut state,
        json!({ "event": "http", "status": 426, "body": json!({ "code": "client.too_old", "minimum_version": "2.0" }).to_string() }),
    );
    assert_eq!(
        effect,
        json!({ "effect": "fail", "error": "client_too_old", "minimum_version": "2.0" })
    );
}

#[test]
fn the_ios_profile_never_asks_for_execute() {
    let profile = call("profile", &json!({ "kind": "ios" }));
    assert_eq!(profile["kind"], "ios");
    assert_eq!(profile["platform"], "ios");
    assert_eq!(profile["fallback_device_name"], "iPhone");
    assert_eq!(profile["op_classes"], json!(["read", "mutate-own", "cloud-link"]));
    assert_eq!(call("profile", &json!({ "kind": "mac" }))["op_classes"][2], "mutate-shared");
}

#[test]
fn headers_carry_a_non_empty_client_version() {
    assert_eq!(
        call("headers", &json!({ "client_version": "1.2.3" })),
        json!({ "headers": { "x-cmux-client-version": "1.2.3" } })
    );
    assert_eq!(call("headers", &json!({ "client_version": "" })), json!({ "headers": {} }));
    assert_eq!(call("headers", &json!({})), json!({ "headers": {} }));
}

#[test]
fn errors_name_the_op_or_the_request() {
    assert_eq!(
        install_auth_json("mint".into(), "{}".into()),
        Err(InstallAuthJsonError::UnknownOperation { operation: "mint".into() })
    );
    for (operation, request) in [
        ("step", "not json"),
        ("step", "[]"),
        ("step", r#"{"event": {"event": "nope"}, "now_ms": 0}"#),
        ("step", r#"{"event": {"event": "rotated"}}"#),
        ("profile", r#"{"kind": "watch"}"#),
    ] {
        assert!(
            matches!(
                install_auth_json(operation.into(), request.into()),
                Err(InstallAuthJsonError::Invalid { .. })
            ),
            "{operation} {request}"
        );
    }
}
