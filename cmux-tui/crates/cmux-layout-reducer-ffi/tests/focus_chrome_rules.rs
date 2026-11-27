//! Browser focus mode's Esc Esc exit (`focus_escape_exit`) and the
//! work-context trail (`focus_work_context`), replayed against
//! schemas/focus-chrome-rules/vectors.json, sent as the app sends them: the
//! state each step answers goes back with the next step, as the app keeps it.
//!
//! The vectors were written from a transliteration of the Swift
//! `BrowserFocusModeEscapeExit` and `WorkContextTrail` before the rules moved
//! to `cmux-focus-core`; CmuxNextAppTests' `FocusChromeRulesVectorTests`
//! replays the same file through the app's wrappers.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/focus-chrome-rules/vectors.json");

fn call(operation: &std::ffi::CStr, request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
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
        assert_eq!(code, OK, "{operation:?} refused {}", String::from_utf8_lossy(&request));
        return serde_json::from_slice(&output[..len]).unwrap();
    }
}

fn vectors() -> Value {
    serde_json::from_str(VECTORS).unwrap()
}

#[test]
fn the_escape_exit_answers_as_the_swift_rule_did() {
    let vectors = vectors();
    let cases = vectors["escapeExit"].as_array().unwrap();
    assert!(cases.len() > 40);
    for case in cases {
        let mut gesture = json!({});
        for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let context = format!("{} step {index}", case["name"]);
            let response =
                call(c"focus_escape_exit", &json!({"gesture": gesture, "key": step["key"]}));
            assert_eq!(response["outcome"], step["outcome"], "{context}");
            assert_eq!(
                response.get("tab").unwrap_or(&Value::Null),
                step.get("tab").unwrap_or(&Value::Null),
                "{context}"
            );
            gesture = response["gesture"].clone();
            assert_eq!(
                gesture.get("armedTab").unwrap_or(&Value::Null),
                &step["armedTab"],
                "{context}"
            );
        }
    }
}

#[test]
fn the_work_context_trail_reads_as_the_swift_rule_did() {
    let vectors = vectors();
    let cases = vectors["workContext"].as_array().unwrap();
    assert!(cases.len() > 40);
    for case in cases {
        let mut trail = json!([]);
        for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let context = format!("{} step {index}", case["name"]);
            if let Some(target) = step.get("candidates") {
                let response = call(
                    c"focus_work_context",
                    &json!({"trail": trail, "op": {"candidates": {"target": target}}}),
                );
                let reads: Vec<&Value> = response["candidates"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|entry| &entry["tab"])
                    .collect();
                let want: Vec<&Value> = step["reads"].as_array().unwrap().iter().collect();
                assert_eq!(reads, want, "{context}");
                continue;
            }
            let op = match (step.get("record"), step.get("forget")) {
                (Some(entry), _) => json!({"record": {"entry": entry}}),
                (None, Some(tab)) => json!({"forget": {"tab": tab}}),
                (None, None) => panic!("{context}: no op"),
            };
            trail =
                call(c"focus_work_context", &json!({"trail": trail, "op": op}))["trail"].clone();
            let tabs: Vec<&Value> =
                trail.as_array().unwrap().iter().map(|entry| &entry["tab"]).collect();
            let want: Vec<&Value> = step["trail"].as_array().unwrap().iter().collect();
            assert_eq!(tabs, want, "{context}");
        }
    }
}

#[test]
fn a_reset_disarms_and_passes() {
    let armed = call(
        c"focus_escape_exit",
        &json!({"key": {"isPlainEscape": true, "isRepeat": false, "timestamp": 1.25, "focusModeTab": "t"}}),
    );
    assert_eq!(
        armed,
        json!({"gesture": {"armedTab": "t", "armedAt": 1.25, "lastEscapeTimestamp": 1.25}, "outcome": "forwardToPage"})
    );
    let reset = call(c"focus_escape_exit", &json!({"gesture": armed["gesture"]}));
    assert_eq!(reset, json!({"gesture": {}, "outcome": "pass"}));
}

#[test]
fn a_timestamp_comes_back_bit_for_bit() {
    // An NSEvent timestamp with every digit used: the duplicate-delivery check compares it exactly.
    let timestamp = 123_456.789_012_345_67_f64;
    let response = call(
        c"focus_escape_exit",
        &json!({"key": {"isPlainEscape": true, "isRepeat": false, "timestamp": timestamp, "focusModeTab": "t"}}),
    );
    assert_eq!(response["gesture"]["lastEscapeTimestamp"].as_f64(), Some(timestamp));
    let again = call(
        c"focus_escape_exit",
        &json!({"gesture": response["gesture"], "key": {"isPlainEscape": true, "isRepeat": false, "timestamp": timestamp, "focusModeTab": "t"}}),
    );
    assert_eq!(again["outcome"], "consume");
}
