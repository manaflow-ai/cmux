//! `cloud_capability_*` through the C ABI: the app holds a mint's answer and asks what each relayed
//! call sends (cmux-cloud-start-core `capability` holds the rules and their cases).

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

const TOKEN: &str = "cc1.eyJ2IjoxfQ.c2lnbmF0dXJl";

#[test]
fn a_held_mint_is_sent_by_a_call_of_its_team_and_not_by_another() {
    let body = json!({"ok": true, "value": {"capability": TOKEN, "team": "team_a", "issued_at": 0,
                      "expires_at": 300_000, "refresh_at": 240_000}});
    let (code, minted) = call(
        c"cloud_capability_mint",
        &json!({"status": 200, "body": body, "team": "team_a", "now": 10}),
    );
    assert_eq!(code, OK);
    assert_eq!(minted["held"]["token"], TOKEN);
    assert_eq!(minted["held"]["expiresAt"], 300_010);
    let held = minted["held"].clone();

    let (code, own) = call(
        c"cloud_capability_plan",
        &json!({"state": {"held": held, "team": "team_a", "now": 20}, "reason": "call"}),
    );
    assert_eq!(code, OK);
    assert_eq!(own, json!({"send": TOKEN, "fetch": false, "wakeIn": 239_990}));

    let (_, other) = call(
        c"cloud_capability_plan",
        &json!({"state": {"held": held, "team": "team_b", "now": 20}, "reason": "call"}),
    );
    assert_eq!(other["send"], Value::Null);
    assert_eq!(other["fetch"], true);
}

#[test]
fn a_refused_mint_holds_nothing_and_a_bad_request_is_invalid() {
    let (code, refused) = call(
        c"cloud_capability_mint",
        &json!({"status": 403, "body": {"ok": false}, "team": "team_a", "now": 0}),
    );
    assert_eq!(code, OK);
    assert_eq!(refused, json!({"held": null}));
    assert_eq!(call(c"cloud_capability_plan", &json!({"reason": "sometimes"})).0, ERR_INVALID);
}
