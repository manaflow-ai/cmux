//! `sidebar_launch_order` through the C ABI: while the hold is on, a pass in another order keeps
//! the order drawn at launch; ending it answers the live order and only the rows that move.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_launch_order".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

#[test]
fn a_held_pass_keeps_the_launch_order_and_inserts_new_rows_in_place() {
    let request = json!({"hold": true, "lists": [
        {"key": "s", "reference": ["a", "b", "c"], "next": ["c", "x", "b", "a"]}
    ]});
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    let list = &body.expect("reply")["lists"][0];
    assert_eq!(list["order"], json!(["a", "b", "c", "x"]));
    assert_eq!(list["moved"], json!([]));
}

#[test]
fn ending_the_hold_answers_the_live_order_and_its_moves() {
    let (code, body) =
        call(br#"{"lists":[{"key":"s","reference":["a","b","c"],"next":["b","c","a"]}]}"#);
    assert_eq!(code, OK);
    let list = &body.expect("reply")["lists"][0];
    assert_eq!(list["order"], json!(["b", "c", "a"]));
    assert_eq!(list["moved"], json!(["a"]));
}

#[test]
fn a_malformed_request_is_refused() {
    let (code, _) = call(br#"{"hold":true}"#);
    assert_eq!(code, ERR_INVALID);
}
