//! The `mobile_host` op through the C ABI: the app sends a credentials event with its saved
//! state and gets the requests to send and the next state (cmux-mobile-host-core holds the cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"mobile_host".as_ptr(),
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
fn a_connection_lists_the_records_first() {
    let request = json!({"op": "credentials", "ids": 10, "event": {"kind": "update", "paired": ["P1"], "listed": ["P1"]}});
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    let request = json!({"op": "credentials", "state": body["state"], "ids": body["ids"], "event": {"kind": "connected"}});
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(
        body["requests"],
        json!([{"id": 11, "kind": "list", "method": "_acpmux/pair_list", "params": {}}])
    );
    assert_eq!(body["needsConnection"], json!(true));
}

#[test]
fn the_record_name_and_a_bad_request() {
    assert_eq!(call(br#"{"op":"record_name","id":"P1"}"#), (OK, json!({"name": "phone-p1"})));
    assert_eq!(call(br#"{"op":"nope"}"#).0, ERR_INVALID);
}
