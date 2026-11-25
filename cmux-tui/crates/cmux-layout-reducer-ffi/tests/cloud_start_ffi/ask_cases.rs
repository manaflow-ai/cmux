//! `cloud_ask_*` through the C ABI: who may answer an agent's Cloud start ask
//! (cmux-cloud-start-core `ask` holds the rules and their cases).

use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 12];
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

#[test]
fn ask_an_agent_is_refused_start_without_delegation() {
    let (code, body) = call(
        c"cloud_ask_answer",
        &json!({"origin": "cli", "agentSession": "sess-1", "delegated": false, "selection": "start"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"caller": "agent", "choice": "start", "verdict": "person-required"}));
}

#[test]
fn ask_the_persons_terminal_may_start() {
    let (_, body) = call(
        c"cloud_ask_answer",
        &json!({"origin": "cli", "delegated": false, "selection": "Start"}),
    );
    assert_eq!(body, json!({"caller": "person", "choice": "start", "verdict": "allowed"}));
}

#[test]
fn ask_a_delegated_agent_may_start_and_anyone_may_decline() {
    let (_, body) = call(
        c"cloud_ask_answer",
        &json!({"origin": "mcp", "delegated": true, "selection": "allow"}),
    );
    assert_eq!(body["verdict"], "allowed");
    let (_, body) = call(c"cloud_ask_answer", &json!({"delegated": false, "selection": "Not now"}));
    assert_eq!(body, json!({"caller": "agent", "choice": "notNow", "verdict": "allowed"}));
}

#[test]
fn ask_an_unknown_selection_is_no_choice() {
    let (_, body) = call(
        c"cloud_ask_answer",
        &json!({"origin": "cli", "delegated": true, "selection": "always"}),
    );
    assert_eq!(body["choice"], Value::Null);
    assert_eq!(body["verdict"], Value::Null);
}

#[test]
fn ask_first_unless_delegated() {
    assert_eq!(call(c"cloud_ask_first", &json!({"delegated": false})).1, json!({"asks": true}));
    assert_eq!(call(c"cloud_ask_first", &json!({"delegated": true})).1, json!({"asks": false}));
}
