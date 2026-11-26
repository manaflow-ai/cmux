//! `cloud_handoff_*` through the C ABI: the app sends its facts and acts on the answer
//! (cmux-cloud-config `handoff` holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 13];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

const DEV: &str = "com.cmuxterm.app.debug.feature1";

fn request_facts(bundle_id: &str, project: &str) -> Value {
    json!({
        "peerUidMatches": true,
        "signer": {"identifier": DEV, "teamId": null, "path": "/Users/me/cmux DEV feature1.app"},
        "params": {"bundleId": bundle_id, "tag": "feature1", "stackProjectId": project,
                   "apiOrigin": "https://dev.invalid"},
        "nightly": {"stackProjectId": "prod", "apiOrigin": "https://cloud-api.cmux.dev", "signedIn": true,
                    "accountEmail": "person@example.com"},
        "consentPending": false
    })
}

#[test]
fn a_signed_out_production_build_asks_and_waits_150_seconds() {
    let (code, body) = call(
        c"cloud_handoff_client_asks",
        &json!({"bundleId": DEV, "isProductionAuth": true, "signedIn": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"asks": true, "method": "auth.session.request", "timeoutSeconds": 150})
    );
    let (_, nightly) = call(
        c"cloud_handoff_client_asks",
        &json!({"bundleId": "com.cmuxterm.app.nightly", "isProductionAuth": true}),
    );
    assert_eq!(nightly["asks"], false);
}

#[test]
fn nightly_asks_consent_or_refuses() {
    let (code, asked) = call(c"cloud_handoff_request_answer", &request_facts(DEV, "prod"));
    assert_eq!(code, OK);
    assert_eq!(asked["kind"], "askConsent");
    assert_eq!(asked["title"], "Sign in cmux DEV feature1?");
    assert_eq!(asked["allow"], "Sign In");
    assert_eq!(asked["deny"], "Don't Allow");
    assert_eq!(asked["timeoutSeconds"], 120);
    assert_eq!(asked["declined"], json!({"code": "forbidden", "message": "declined"}));
    assert_eq!(asked["recipient"], json!({"bundleId": DEV, "tag": "feature1"}));

    let (_, other) = call(
        c"cloud_handoff_request_answer",
        &request_facts("com.cmuxterm.app.debug.other", "prod"),
    );
    assert_eq!(other["kind"], "refuse");
    assert_eq!(other["code"], "forbidden");

    let (_, backend) = call(c"cloud_handoff_request_answer", &request_facts(DEV, "dev"));
    assert_eq!(backend["code"], "backend_mismatch");
    let message = backend["message"].as_str().unwrap();
    assert!(message.contains("cloud-api.cmux.dev") && message.contains("dev.invalid"), "{message}");
}

#[test]
fn the_mint_request_and_answer_answer_here() {
    let (code, request) = call(
        c"cloud_handoff_mint_request",
        &json!({"authWebOrigin": "https://cmux.com", "bundleId": DEV, "tag": null}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        request,
        json!({"url": "https://cmux.com/api/auth/session-handoff", "method": "POST",
               "body": {"recipient": {"bundleId": DEV, "tag": null}}})
    );
    let (_, minted) = call(
        c"cloud_handoff_mint_answer",
        &json!({"status": 200, "body": r#"{"accessToken":"a","refreshToken":"r","expiresAt":"2026-11-26T00:00:00Z"}"#}),
    );
    assert_eq!(
        minted,
        json!({"result": {"access_token": "a", "refresh_token": "r", "expires_at": "2026-11-26T00:00:00Z"}})
    );
    let (_, refused) =
        call(c"cloud_handoff_mint_answer", &json!({"status": 401, "body": "r-secret"}));
    assert_eq!(refused["refusal"]["code"], "unauthorized");
    assert!(!refused.to_string().contains("r-secret"));
}

#[test]
fn malformed_requests_are_invalid() {
    assert_eq!(call(c"cloud_handoff_request_answer", &json!([1])).0, ERR_INVALID);
    assert_eq!(call(c"cloud_handoff_unknown", &json!({})).0, ERR_INVALID);
}
