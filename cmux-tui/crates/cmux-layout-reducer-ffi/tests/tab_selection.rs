//! The tab strip's multi-selection (`tab_selection*`, cmux-window-rules
//! `tabs::selection`), replayed against schemas/tab-selection/vectors.json.
//!
//! The vectors were written from a transliteration of the Swift
//! `TabMultiSelection` and `TabSelectionMove` before the Mac app moved to the
//! Rust rules: random strips with clicks of each kind, closes, opens and
//! activations, multi-tab moves with pinned tabs, and drops walked one tab at
//! a time. Each selection step feeds the returned selection into the next.
//! CmuxNextAppTests' `TabSelectionVectorTests` replays the same file through
//! the Swift types.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/tab-selection/vectors.json");

fn call(operation: &std::ffi::CStr, request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
    let mut capacity = 256;
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

#[test]
fn every_click_close_and_activation_selects_what_the_swift_rule_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let strips = vectors["clicks"].as_array().unwrap();
    assert!(strips.len() >= 50);
    let mut steps = 0;
    for (number, strip) in strips.iter().enumerate() {
        let mut selection = json!({});
        for step in strip.as_array().unwrap() {
            let change = match step["op"].as_str().unwrap() {
                "click" => json!({"click": {
                    "id": step["id"], "click": step["click"], "order": step["order"], "active": step["active"],
                }}),
                "follow" => json!({"follow": {"order": step["order"]}}),
                "activated" => json!({"activated": {"id": step["id"]}}),
                other => panic!("unknown step {other}"),
            };
            let answer = call(c"tab_selection", &json!({"selection": selection, "change": change}));
            assert_eq!(answer["selection"], step["want"]["selection"], "strip {number}: {step}");
            if step["op"] == "click" {
                assert_eq!(answer["active"], step["want"]["active"], "strip {number}: {step}");
            }
            selection = answer["selection"].clone();
            steps += 1;
        }
    }
    assert!(steps > 400);
}

#[test]
fn every_move_and_drop_step_matches_the_swift_rule() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    for case in vectors["moves"].as_array().unwrap() {
        let answer = call(
            c"tab_selection_move",
            &json!({"order": case["order"], "pinned": case["pinned"], "selection": case["selection"], "index": case["index"]}),
        );
        assert_eq!(answer["order"], case["want"], "{case}");
    }
    let mut walked = 0;
    for case in vectors["steps"].as_array().unwrap() {
        for step in case["walk"].as_array().unwrap() {
            let answer = call(
                c"tab_selection_next_step",
                &json!({"current": step["current"], "target": case["target"]}),
            );
            let want = match &step["want"] {
                Value::Null => Value::Null,
                pair => json!({"id": pair[0], "index": pair[1]}),
            };
            assert_eq!(answer["step"], want, "{step} toward {}", case["target"]);
            walked += 1;
        }
    }
    assert!(walked > 300);
}

#[test]
fn an_unknown_click_is_refused() {
    let request = br#"{"change": {"click": {"id": "a", "click": "double", "order": ["a"]}}}"#;
    let mut output = [0u8; 64];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"tab_selection".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    assert_ne!(code, OK);
}
