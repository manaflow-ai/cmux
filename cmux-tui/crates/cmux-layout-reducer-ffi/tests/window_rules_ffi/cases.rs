//! `window_*` through the C ABI: the app sends its facts and acts on the
//! answer (cmux-window-rules holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &[u8]) -> (i32, Value) {
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

fn call_json(operation: &CStr, request: &Value) -> (i32, Value) {
    call(operation, &serde_json::to_vec(request).unwrap())
}

#[test]
fn close_toast_asks_an_idle_terminal() {
    let (code, body) = call_json(
        c"window_close_toast",
        &json!({"tabs": [{"kind": "browser", "url": "about:blank"}, {"kind": "pty"}]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"decision": "askTerminals", "terminals": [1]}));
}

#[test]
fn close_reads_then_warning_names_the_working_agent() {
    let (code, body) = call_json(
        c"window_close_reads",
        &json!({"tabs": [{"kind": "pty", "agentAtWork": true, "agent": "claude"}, {"kind": "pty"}],
                "warnTab": true, "warnAgent": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": {"agents": ["Claude"], "others": [1]}}));
    let (code, body) = call_json(
        c"window_close_warning",
        &json!({"agents": ["Claude"], "answers": [{"title": "zsh", "answered": true, "program": "vim"}],
                "unansweredAsks": true, "warnTab": true, "warnAgent": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"warning": {"kind": "agent", "name": "Claude"}}));
}

#[test]
fn close_reads_nothing_with_both_warnings_off() {
    let (code, body) = call_json(c"window_close_reads", &json!({"tabs": [{"kind": "pty"}]}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"reads": null}));
}

#[test]
fn close_warning_names_a_terminal_that_gave_no_answer() {
    let (code, body) = call_json(
        c"window_close_warning",
        &json!({"answers": [{"title": "build", "answered": false}], "unansweredAsks": true, "warnTab": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"warning": {"kind": "programs", "programs": [], "unanswered": ["build"]}})
    );
}

#[test]
fn unknown_window_ops_and_bad_json_are_refused() {
    assert_eq!(call(c"window_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call(c"window_close_toast", b"not json").0, ERR_INVALID);
}
