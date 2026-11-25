//! `feed_approve_*` through the C ABI, as the Mac's FeedApproveProofCheck asks them: the
//! keys and the context come back in the shape `feed_approve_check` takes.

use std::ffi::CString;

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(op: &str, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let op = CString::new(op).unwrap();
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn shown_sha256_of_an_empty_action() {
    let (code, body) = call("feed_approve_shown_sha256", &json!({ "action": {} }));
    assert_eq!(code, OK);
    assert_eq!(body["sha256"].as_str().unwrap().len(), 64);
}

#[test]
fn keys_context_and_check_round_trip() {
    let (code, keys) = call(
        "feed_approve_keys",
        &json!({ "value": { "keys": [{
            "install": "phone-1", "platform": "ios", "attested": true, "usable_from": 0,
            "revoked_at": null, "install_active": true,
            "jwk": { "x": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                     "y": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" },
        }] } }),
    );
    assert_eq!(code, OK);
    assert_eq!(keys["keys"]["phone-1"]["platform"], "ios");

    // header.{"iss":"https://cmux-api/production","sub":"u","inst":"m"}.sig
    let (code, context) = call(
        "feed_approve_context",
        &json!({ "token": "h.eyJpc3MiOiJodHRwczovL2NtdXgtYXBpL3Byb2R1Y3Rpb24iLCJzdWIiOiJ1IiwiaW5zdCI6Im0ifQ.s" }),
    );
    assert_eq!(code, OK);
    assert_eq!(
        context["context"],
        json!({ "environment": "production", "user": "u", "mac_install": "m" })
    );
    let (_, none) = call("feed_approve_context", &json!({ "token": "x" }));
    assert_eq!(none["context"], Value::Null);

    let check = |proof: Value, now_ms: f64| {
        call(
            "feed_approve_check",
            &json!({
                "decision": { "outcome": "allow", "scope": null, "proof": proof },
                "by": "phone-1", "item": "i", "shown_sha256": "s",
                "context": context["context"], "keys": keys["keys"], "now_ms": now_ms,
            }),
        )
    };
    assert_eq!(check(Value::Null, 0.0).1["failure"], "noProof");
    let proof = json!({ "install": "phone-1", "timestamp_ms": 1000, "signature": "AA" });
    assert_eq!(check(proof.clone(), 1_000_000.0).1["failure"], "stale");
    // (0, 0) is not a curve point.
    assert_eq!(check(proof, 1000.0).1["failure"], "badKey");
}

#[test]
fn unknown_op_and_bad_request_are_invalid() {
    assert_eq!(call("feed_approve_nope", &json!({})).0, ERR_INVALID);
    assert_eq!(call("feed_approve_check", &json!({})).0, ERR_INVALID);
}
