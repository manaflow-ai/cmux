//! `sidebar_nav` through the C ABI: the app's `sidebar.nav` setting comes back as the rows the
//! sidebar draws, with a problem for each entry Rust drops.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_nav".as_ptr(),
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
fn rows_come_back_with_their_overrides_and_bad_entries_as_problems() {
    let request = json!({"nav": ["palette.newAgentChat | New chat | square.and.pencil", "no.such.action", "home.show"]});
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    let body = body.expect("reply");
    assert_eq!(
        body["rows"],
        json!([
            {"action": "palette.newAgentChat", "title": "New chat", "symbol": "square.and.pencil"},
            {"action": "home.show"}
        ])
    );
    assert_eq!(body["problems"][0]["path"], json!("sidebar.nav[1]"));
}

#[test]
fn no_setting_draws_no_rows() {
    let (code, body) = call(b"{}");
    assert_eq!(code, OK);
    assert_eq!(body.expect("reply"), json!({"rows": [], "problems": []}));
}

#[test]
fn a_malformed_request_is_refused() {
    let (code, _) = call(b"not json");
    assert_eq!(code, ERR_INVALID);
}
