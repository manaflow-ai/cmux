//! `new_placement` through the C ABI: the app's request answers the op and how the item is made,
//! and a request naming no known kind is refused.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1024];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"new_placement".as_ptr(),
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
fn a_browser_on_the_left_is_made_then_moved_into_a_left_split() {
    let (code, body) = call(br#"{"kind":"browser","placement":"left","tabSplit":true}"#);
    assert_eq!(code, OK);
    assert_eq!(body, Some(json!({"op": "split", "edge": "left", "make": "made_then_moved"})));
}

#[test]
fn a_terminal_in_a_new_row_is_made_in_place() {
    let (code, body) = call(br#"{"kind":"terminal","placement":"row"}"#);
    assert_eq!(code, OK);
    assert_eq!(body, Some(json!({"op": "row", "make": "in_place"})));
}

#[test]
fn an_unknown_kind_is_refused() {
    let (code, body) = call(br#"{"kind":"spreadsheet","placement":"tab"}"#);
    assert_eq!(code, ERR_INVALID);
    assert_eq!(body, None);
}
