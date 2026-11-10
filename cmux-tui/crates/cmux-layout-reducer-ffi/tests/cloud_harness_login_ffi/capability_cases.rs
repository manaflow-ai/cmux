//! `cloud_capability_step` through the C ABI: the app's capability holder keeps an opaque state,
//! sends one event at a time and runs the effects (cmux-cloud-start-core `capability::holder` holds
//! the flows and their cases).

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

fn step(state: &Value, event: Value, now: i64) -> Value {
    let (code, reply) =
        call(c"cloud_capability_step", &json!({"state": state, "event": event, "now": now}));
    assert_eq!(code, OK, "{event}");
    reply
}

#[test]
fn intent_mints_and_a_call_of_its_team_sends_it_and_not_another() {
    let used = step(&Value::Null, json!({"on": "use"}), 0);
    assert_eq!(used["generation"], 0);
    let intent =
        step(&used["state"], json!({"on": "intent", "team": "team_a", "generation": 0}), 0);
    assert_eq!(intent["effects"], json!([{"do": "mint", "team": "team_a", "generation": 0}]));
    assert_eq!(intent["minting"], true);

    let body = json!({"ok": true, "value": {"capability": TOKEN, "team": "team_a", "issued_at": 0,
                      "expires_at": 300_000, "refresh_at": 240_000}})
    .to_string();
    let minted = step(
        &intent["state"],
        json!({"on": "minted", "team": "team_a", "generation": 0, "status": 200, "body": body}),
        10,
    );
    assert_eq!(minted["holds"], true);
    assert_eq!(minted["minting"], false);
    assert_eq!(minted["effects"], json!([{"do": "schedule", "afterMs": 240_000, "generation": 0}]));

    let own = step(&minted["state"], json!({"on": "call", "team": "team_a"}), 20);
    assert_eq!(own["send"], TOKEN);
    assert_eq!(own["effects"], json!([]));
    let other = step(&minted["state"], json!({"on": "call", "team": "team_b"}), 20);
    assert_eq!(other["send"], Value::Null);
    assert_eq!(other["effects"], json!([{"do": "mint", "team": "team_b", "generation": 0}]));

    let cleared = step(&own["state"], json!({"on": "clear"}), 30);
    assert_eq!(cleared["holds"], false);
    assert_eq!(cleared["generation"], 1);
    assert_eq!(cleared["effects"], json!([{"do": "cancelMint"}, {"do": "cancelTimer"}]));
}

#[test]
fn a_refused_mint_holds_nothing_and_a_bad_request_is_invalid() {
    let call_ = step(&Value::Null, json!({"on": "call", "team": "team_a"}), 0);
    let refused = step(
        &call_["state"],
        json!({"on": "minted", "team": "team_a", "generation": 0, "status": 403, "body": "{\"ok\":false}"}),
        1,
    );
    assert_eq!(refused["holds"], false);
    assert_eq!(refused["effects"], json!([{"do": "cancelTimer"}]));
    assert_eq!(
        call(c"cloud_capability_step", &json!({"event": {"on": "sometimes"}, "now": 0})).0,
        ERR_INVALID
    );
    assert_eq!(
        call(
            c"cloud_capability_step",
            &json!({"state": "not json", "event": {"on": "use"}, "now": 0})
        )
        .0,
        ERR_INVALID
    );
}
