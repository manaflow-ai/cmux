//! `cloud_sequence_*` through the C ABI: the app sends the sequence's state, one event and its
//! clock, and runs the effects the answer lists (cmux-cloud-start-core `sequence` holds the rules).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 14];
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

fn step(state: &Value, event: Value, now: u64) -> Value {
    let (code, reply) =
        call(c"cloud_sequence_step", &json!({"state": state, "event": event, "now": now}));
    assert_eq!(code, OK);
    reply
}

#[test]
fn a_session_start_runs_its_steps_in_the_sequencers_order() {
    let begun = step(&Value::Null, json!({"on": "begin", "path": "session"}), 100);
    assert_eq!(begun["effects"], json!([{"do": "run", "step": "connect"}]));
    let linked = step(&begun["state"], json!({"on": "done", "step": "connect"}), 1_100);
    assert_eq!(
        linked["effects"],
        json!([
            {"do": "log", "line": "cloud start step: connect 1000 ms"},
            {"do": "run", "step": "login"},
            {"do": "run", "step": "daemon-status"},
        ])
    );
    let busy = step(
        &linked["state"],
        json!({"on": "done", "step": "daemon-status", "idle": false}),
        1_200,
    );
    assert_eq!(
        busy["effects"],
        json!([{"do": "log", "line": "cloud start step: approvals.status 100 ms"}, {"do": "log", "line": "cloud start step: approvals 100 ms"}])
    );
    let logged_in = step(&busy["state"], json!({"on": "done", "step": "login"}), 2_000);
    assert_eq!(
        logged_in["effects"],
        json!([{"do": "log", "line": "cloud start step: login 800 ms"}, {"do": "run", "step": "anchor"}])
    );
}

#[test]
fn the_recheck_and_approvals_rules_answer() {
    assert_eq!(
        call(
            c"cloud_sequence_recheck_guest",
            &json!({"fromCache": true, "sinceGuestCheckMs": 400})
        )
        .1,
        json!({"recheck": false})
    );
    assert_eq!(
        call(
            c"cloud_sequence_recheck_guest",
            &json!({"fromCache": false, "sinceGuestCheckMs": 400})
        )
        .1,
        json!({"recheck": true})
    );
    assert_eq!(
        call(c"cloud_sequence_approvals", &json!({"holdsKey": true})).1,
        json!({"approvals": "held"})
    );
    assert_eq!(call(c"cloud_sequence_approvals", &json!({})).1, json!({"approvals": "if-idle"}));
    assert_eq!(
        call(c"cloud_sequence_approvals", &json!({"daemonSaidSafe": true})).1,
        json!({"approvals": "restart-now"})
    );
}

#[test]
fn a_request_it_cannot_read_is_refused() {
    assert_eq!(call(c"cloud_sequence_step", &json!({"event": {"on": "begin"}})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_sequence_nope", &json!({})).0, ERR_INVALID);
}
