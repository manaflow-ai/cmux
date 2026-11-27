use serde_json::{Value, json};

use super::*;

fn call(operation: &str, request: Value) -> Value {
    let bytes = respond(operation.as_bytes(), request.to_string().as_bytes()).expect("answers");
    serde_json::from_slice(&bytes).unwrap()
}

#[test]
fn only_screen_ops_are_its_own() {
    assert!(handles(b"screen_demand_report"));
    assert!(!handles(b"window_close"));
    assert_eq!(respond(b"screen_nope", b"{}"), Err(ERR_INVALID));
    assert_eq!(respond(b"screen_demand_report", b"not json"), Err(ERR_INVALID));
    assert_eq!(respond(b"screen_\xff", b"{}"), Err(ERR_INVALID));
}

// The op cases themselves run in cmux-rd-screen's json_tests.rs; this proves the C ABI passes them through.
#[test]
fn the_c_abi_answers_what_the_dispatcher_answers() {
    let request = json!({"t": "caps", "s": "telepointers,cursor-shape"});
    assert_eq!(
        call("screen_cursor_caps", request.clone()),
        cmux_rd_screen::json::respond("screen_cursor_caps", request.to_string().as_bytes())
            .unwrap()
    );
}
