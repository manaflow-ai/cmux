//! The focus UI's key rules (cmux-focus-core `ui::{typing_park, given_back,
//! held_key, page_first_key, awaited_content, browser_chords}`), replayed
//! against schemas/focus-ui-keys/vectors.json.
//!
//! The vectors were written from line-by-line transliterations of the Swift
//! `TypingPark`, `GivenBackInput`, `HeldKeyInput`, `PageFirstKeyOffer`,
//! `AwaitedContent` and `BrowserChordTable` before the Mac app moved to the
//! Rust rules: random sequences of each state's calls (pages that go away, the
//! clock across each limit, closed creations, copies of offered keys) and
//! random keys, each checked for every field of its answer but the state.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/focus-ui-keys/vectors.json");

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
fn the_key_rules_answer_what_the_swift_rules_did() {
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
    assert!(asked >= 4000, "only {asked} steps");
}

#[test]
fn a_bad_request_is_refused() {
    let request = br#"{"op":{"kind":"nope"}}"#;
    let mut output = vec![0u8; 256];
    let mut len = 0usize;
    for operation in [c"focus_ui_typing_park", c"focus_ui_given_back", c"focus_ui_page_first_key"] {
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
fn a_parked_text_is_taken_once_and_counted_when_it_lands() {
    let op = "focus_ui_typing_park";
    let park =
        call(op, &json!({"op": {"kind": "park", "text": "x", "page": 1, "nowNs": 0}}))["park"]
            .clone();
    let taken = call(op, &json!({"park": park, "op": {"kind": "take", "page": 1, "nowNs": 300}}));
    assert_eq!(taken["reply"], "x");
    let again =
        call(op, &json!({"park": taken["park"], "op": {"kind": "take", "page": 1, "nowNs": 301}}));
    assert_eq!(again.get("reply"), None, "a text on its way was taken twice");
    let landed = call(
        op,
        &json!({"park": again["park"], "op": {"kind": "landed", "page": 1, "typed": true}}),
    );
    assert_eq!(landed["counts"]["typed"], 1);
    assert_eq!(landed["isEmpty"], true);
}
