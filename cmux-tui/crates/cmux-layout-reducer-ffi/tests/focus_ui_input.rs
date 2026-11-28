//! The focus UI's input holds (cmux-focus-core `ui::{type_ahead_tail,
//! creation_claims, decided_keys}`), replayed against
//! schemas/focus-ui-input/vectors.json.
//!
//! The vectors were written from line-by-line transliterations of the Swift
//! `TypeAheadTail`, `CreationKeyboardClaims` (its window identity and logging
//! as inputs and outputs) and `DecidedKeyEvents` (its signatures) before the
//! Mac app moved to the Rust rules: random sequences of each state's calls
//! (other surfaces, other windows and tickets, the asking input's timestamp,
//! Escape, more keys than the limit), each checked for every field of its
//! answer but the state.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/focus-ui-input/vectors.json");

fn call(operation: &str, request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
    let operation = CString::new(operation).unwrap();
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
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
        if code == ERR_BUFFER && len > capacity {
            capacity = len;
            continue;
        }
        assert_eq!(code, OK, "refused {}", String::from_utf8_lossy(&request));
        return serde_json::from_slice(&output[..len]).unwrap();
    }
}

#[test]
fn the_input_holds_answer_what_the_swift_rules_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 300);
    let mut asked = 0;
    for (number, case) in cases.iter().enumerate() {
        let operation = case["op"].as_str().unwrap();
        let state = case["state"].as_str();
        let mut held = Value::Null;
        for (step_number, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let mut request = step["request"].clone();
            if let Some(state) = state.filter(|_| !held.is_null()) {
                request[state] = held.clone();
            }
            let mut answer = call(operation, &request);
            if let Some(state) = state {
                held = answer.as_object_mut().unwrap().remove(state).unwrap();
            }
            assert_eq!(
                answer, step["expect"],
                "case {number} ({operation}) step {step_number}: {}",
                step["request"]
            );
            asked += 1;
        }
    }
    assert!(asked >= 5000, "only {asked} steps");
}

#[test]
fn a_bad_request_is_refused() {
    let request = br#"{"op":{"kind":"nope"}}"#;
    let mut output = vec![0u8; 256];
    let mut len = 0usize;
    for operation in
        [c"focus_ui_type_ahead_tail", c"focus_ui_creation_claims", c"focus_ui_decided_keys"]
    {
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
        assert_ne!(code, OK);
    }
}

#[test]
fn a_claim_that_kept_keys_says_so_when_escape_ends_it() {
    let op = "focus_ui_creation_claims";
    let made = call(op, &json!({"op": {"kind": "claim", "window": 7, "ticket": 1, "intents": 0}}));
    let kept = call(
        op,
        &json!({"claims": made["claims"], "op": {"kind": "keeps", "window": 7, "keyCode": 0}}),
    );
    assert_eq!(kept["reply"]["keeps"], true);
    let escape = call(
        op,
        &json!({"claims": kept["claims"], "op": {"kind": "keeps", "window": 7, "keyCode": 53}}),
    );
    assert_eq!(escape["reply"]["keeps"], Value::Null);
    assert_eq!(escape["ended"], json!([{"window": 7, "kept": 1}]));
    assert_eq!(escape["isEmpty"], true);
}

#[test]
fn return_runs_once_after_its_text_was_taken() {
    let op = "focus_ui_type_ahead_tail";
    let held =
        call(op, &json!({"op": {"kind": "hold", "key": 9, "surface": "p", "delivering": false}}));
    let taken =
        call(op, &json!({"tail": held["tail"], "op": {"kind": "textWasTaken", "surface": "p"}}));
    let run = call(op, &json!({"tail": taken["tail"], "op": {"kind": "settle", "surface": "p"}}));
    assert_eq!(run["reply"], json!([9]));
    let again = call(op, &json!({"tail": run["tail"], "op": {"kind": "settle", "surface": "p"}}));
    assert_eq!(again["reply"], json!([]));
}
