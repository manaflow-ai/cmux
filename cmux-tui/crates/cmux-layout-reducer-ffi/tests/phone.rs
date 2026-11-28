//! `phone` through the C ABI: the app passes a phone tool's output (or an
//! input) with the rule it wants in `op` and applies the answer
//! (`cmux-phone-core`).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(request: &[u8]) -> (i32, Value) {
    let op = CString::new("phone").unwrap();
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    // SAFETY: every pointer is live for the call, with its length.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
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
fn phone_answers_a_rule_by_its_op() {
    let request = json!({"op": "adb_devices", "output": "List of devices attached\nR58M123 device usb:1-1 model:Pixel_7\n"});
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["devices"][0]["serial"], "R58M123");
    let (code, body) = call(br#"{"op":"tap","screen":[400,800],"point":[500,10]}"#);
    assert_eq!(code, OK);
    assert_eq!(body, json!({"error": "outside_screen"}));
}

#[test]
fn phone_refuses_an_unknown_op() {
    assert_eq!(call(br#"{"op":"nope"}"#).0, ERR_INVALID);
    assert_eq!(call(b"junk").0, ERR_INVALID);
}
