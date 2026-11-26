//! The creation hold log (cmux-focus-core `ui::creation_hold_log`), replayed
//! against schemas/focus-ui-hold-log/vectors.json.
//!
//! The vectors were written from a line-by-line transliteration of the Swift
//! `CreationHoldLog` before the Mac app moved to the Rust log: random calls
//! (failed creations, closed windows, keys that went with a closed terminal,
//! page holds ended at their limit), each checked for every field of its
//! answer but the log.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/focus-ui-hold-log/vectors.json");
const OP: &str = "focus_ui_creation_hold_log";

fn call(operation: &str, request: &Value) -> Result<Value, i32> {
    let request = serde_json::to_vec(request).unwrap();
    let operation = CString::new(operation).unwrap();
    let mut capacity = 1024;
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
        if code != OK {
            return Err(code);
        }
        return Ok(serde_json::from_slice(&output[..len]).unwrap());
    }
}

#[test]
fn the_hold_log_answers_what_the_swift_log_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 200);
    let mut asked = 0;
    for (number, case) in cases.iter().enumerate() {
        let operation = case["op"].as_str().unwrap();
        let state = case["state"].as_str().unwrap();
        let mut held = Value::Null;
        for (step_number, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let mut request = step["request"].clone();
            if !held.is_null() {
                request[state] = held.clone();
            }
            let mut answer = call(operation, &request).unwrap();
            held = answer.as_object_mut().unwrap().remove(state).unwrap();
            assert_eq!(
                answer, step["expect"],
                "case {number} step {step_number}: {}",
                step["request"]
            );
            asked += 1;
        }
    }
    assert!(asked >= 2000, "only {asked} steps");
}

#[test]
fn a_bad_request_is_refused() {
    assert!(call(OP, &json!({"op": {"kind": "nope"}})).is_err());
    assert!(call(OP, &json!({"op": {"kind": "end", "window": 1, "forced": "never"}})).is_err());
}

#[test]
fn a_failed_creation_ends_its_hold_as_failed_and_keys_gone_with_a_terminal_are_lost() {
    let failed = call(OP, &json!({"op": {"kind": "creationFailed", "window": 1}})).unwrap();
    let gone =
        call(OP, &json!({"log": failed["log"], "op": {"kind": "wentWithTerminal", "count": 2}}))
            .unwrap();
    let noted = call(
        OP,
        &json!({"log": gone["log"], "op": {"kind": "noteEnded", "end": "focusLanded", "window": 1, "untyped": 1}}),
    )
    .unwrap();
    assert_eq!(noted["reply"], json!({"note": "lost", "lost": 3}));
    assert_eq!(noted["lostKeys"]["1"], 3);
    let ended =
        call(OP, &json!({"log": noted["log"], "op": {"kind": "end", "window": 1}})).unwrap();
    assert_eq!(ended["reply"], "creationFailed");
    assert_eq!(ended["last"]["1"], "creationFailed");
}
