//! The window rules moved out of CmuxNextWindowRules' Swift (close's known program, the launch's
//! front window, Open in Editor's scheme, a Toggle Terminal and Chat swap's reads), through the
//! C ABI, replayed against schemas/window-rules-swift-out/vectors.json. The vectors were written
//! from a line-by-line transliteration of the Swift before the move, on random cases.

use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::Value;
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/window-rules-swift-out/vectors.json");

fn call(operation: &str, request: &Value) -> (i32, Value) {
    let operation = CString::new(operation).unwrap();
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

#[test]
fn the_moved_rules_answer_as_the_swift_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let cases = vectors["cases"].as_array().unwrap();
    let mut ops = std::collections::BTreeSet::new();
    for case in cases {
        let op = case["op"].as_str().unwrap();
        ops.insert(op);
        let (code, reply) = call(op, &case["request"]);
        assert_eq!(code, OK, "{op} {}", case["request"]);
        assert_eq!(reply, case["reply"], "{op} {}", case["request"]);
    }
    assert!(cases.len() > 2000, "the vectors ask {} times", cases.len());
    assert_eq!(ops.len(), 5);
}

#[test]
fn the_swap_scroll_and_show_answer_over_the_channel() {
    let screen = "> fix the login bug\n\n⏺ In auth.rs.\n\n> now add a test\n\n⏺ Added.\n\n> ";
    let prompts = ["fix the login bug", "now add a test"];
    let (code, reply) = call(
        "window_tabs_terminal_scroll",
        &serde_json::json!({"prompts": prompts, "at": 1, "screen": screen, "base": 0, "columns": 80, "top": 4, "atBottom": true}),
    );
    assert_eq!((code, reply), (OK, serde_json::json!({"scroll": "row", "row": 4})));
    let (code, reply) = call(
        "window_tabs_chat_show",
        &serde_json::json!({"prompts": prompts, "screen": screen, "base": 0, "columns": 80, "top": 2, "atBottom": false, "at": null}),
    );
    assert_eq!((code, reply), (OK, serde_json::json!({"show": "turn", "index": 0})));
}
