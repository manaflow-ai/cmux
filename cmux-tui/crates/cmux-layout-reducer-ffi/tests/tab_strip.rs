//! The tab strip's commands (`tab_strip_*`, cmux-window-rules `tabs::strip`),
//! replayed against schemas/tab-strip-commands/vectors.json.
//!
//! The vectors were written from a transliteration of the Swift
//! `TabStripModel+PinnedClose.swift` before the Mac app moved to the Rust
//! rules: random strips in display order (pinned tabs, tabs that cannot close,
//! groups, collapsed groups), each command from every tab and one not in the
//! strip. CmuxNextAppTests' `TabStripCommandVectorTests` replays the same file
//! through `TabStripModel`.

use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/tab-strip-commands/vectors.json");

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
fn every_command_answers_what_the_swift_rule_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 100);
    let mut asked = 0;
    for (number, case) in cases.iter().enumerate() {
        let strip = |extra: Value| {
            let mut request = json!({"tabs": case["tabs"], "collapsed": case["collapsed"]});
            request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
            request
        };
        for probe in case["keyboardClose"].as_array().unwrap() {
            let answer = call(c"tab_strip_keyboard_close", &strip(json!({"id": probe[0]})));
            assert_eq!(answer, probe[1], "strip {number}: Cmd-W {}", probe[0]);
            asked += 1;
        }
        for probe in case["closedBy"].as_array().unwrap() {
            let answer = call(c"tab_strip_closed_by", &strip(json!({"id": probe[0]})));
            let want = json!({"others": probe[1], "left": probe[2], "right": probe[3]});
            assert_eq!(answer, want, "strip {number}: close from {}", probe[0]);
            asked += 1;
        }
        for probe in case["selectionKeeping"].as_array().unwrap() {
            let request = json!({"id": probe[0], "kept": probe[1], "selected": case["selected"]});
            let answer = call(c"tab_strip_selection_keeping", &strip(request));
            assert_eq!(answer["tab"], probe[2], "strip {number}: keeping {}", probe[0]);
            asked += 1;
        }
        for probe in case["moveIndex"].as_array().unwrap() {
            let answer =
                call(c"tab_strip_move_index", &strip(json!({"id": probe[0], "offset": probe[1]})));
            assert_eq!(answer["index"], probe[2], "strip {number}: move {} {}", probe[0], probe[1]);
            asked += 1;
        }
        for probe in case["adjacent"].as_array().unwrap() {
            let answer =
                call(c"tab_strip_adjacent", &strip(json!({"id": probe[0], "offset": probe[1]})));
            assert_eq!(answer["tab"], probe[2], "strip {number}: step {} {}", probe[0], probe[1]);
            asked += 1;
        }
    }
    assert!(asked > 5000, "the vectors ask {asked} times");
}

#[test]
fn a_command_without_its_tab_is_refused() {
    let request = br#"{"tabs": [], "collapsed": []}"#;
    let mut output = [0u8; 64];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"tab_strip_keyboard_close".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    assert_ne!(code, OK);
}
