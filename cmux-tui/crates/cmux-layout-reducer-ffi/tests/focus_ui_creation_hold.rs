//! `focus_ui_creation_hold` (cmux-focus-core `ui::creation_hold`), replayed against
//! schemas/focus-ui-creation-hold/vectors.json.
//!
//! The vectors were written from a line-by-line transliteration of the Swift
//! `CreationInputBuffer` (with its `NewTerminalKeys`, reply bound and tab keys)
//! before the Mac app moved to the Rust hold: random sequences of every call of
//! the hold (creations, closes, workspaces, made terminals and their store
//! listing, held keys with chords and tab kinds, the clock across the reply
//! bound), each checked for its answer, the hold's reads after it and the keys
//! it dropped.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/focus-ui-creation-hold/vectors.json");

fn call(request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                c"focus_ui_creation_hold".as_ptr(),
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
fn the_creation_hold_answers_what_the_swift_hold_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 50);
    let mut asked = 0;
    for (number, case) in cases.iter().enumerate() {
        let mut hold =
            call(&json!({"live": {"nowNs": case["beganNs"]}, "op": {"kind": "read"}}))["hold"]
                .clone();
        for (step_number, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let answer = call(&json!({"hold": hold, "live": step["live"], "op": step["op"]}));
            let at = format!("case {number} step {step_number}: {}", step["op"]);
            assert_eq!(answer["reply"], step["reply"], "{at}");
            assert_eq!(answer["facts"], step["facts"], "{at}");
            let dropped = answer.get("dropped").cloned().unwrap_or(json!([]));
            assert_eq!(dropped, step["dropped"], "{at}");
            hold = answer["hold"].clone();
            asked += 1;
        }
    }
    assert!(asked >= 1000, "only {asked} steps");
}

#[test]
fn a_request_with_no_hold_begins_one_at_its_clock() {
    let answer =
        call(&json!({"live": {"nowNs": 5}, "op": {"kind": "open", "generation": 2, "tab": "t"}}));
    assert_eq!(
        answer["reply"],
        json!({"ticket": 1, "arm": {"opened": 1, "boundNs": 10_000_000_000i64}})
    );
    assert_eq!(answer["hold"]["beganNs"], 5);
    assert_eq!(answer["facts"]["hasPendingCreation"], true);
}
