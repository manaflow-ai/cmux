use serde_json::json;

use super::call;

fn ask(request: serde_json::Value) -> serde_json::Value {
    call(request.to_string().as_bytes())
}

#[test]
fn unknown_ops_and_bad_requests_answer_err() {
    assert!(ask(json!({"op": "nope.x"}))["err"].is_string());
    assert!(ask(json!({"args": {}}))["err"].is_string());
    assert!(call(b"{").get("err").is_some());
}

#[test]
fn c_entry_round_trips_and_frees() {
    let request = json!({"op": "nope"}).to_string();
    let mut out = std::ptr::null_mut();
    let mut len = 0usize;
    // SAFETY: valid pointers for the call.
    let code =
        unsafe { super::cmux_rd_ui_call(request.as_ptr(), request.len(), &mut out, &mut len) };
    assert_eq!(code, crate::CMUX_RD_OK);
    // SAFETY: from the call above.
    let bytes = unsafe { std::slice::from_raw_parts(out, len) }.to_vec();
    unsafe { super::cmux_rd_ui_free(out, len) };
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert!(value["err"].is_string());
    // SAFETY: NULL out pointers are refused.
    assert_eq!(
        unsafe {
            super::cmux_rd_ui_call(request.as_ptr(), request.len(), std::ptr::null_mut(), &mut len)
        },
        crate::CMUX_RD_ERR_NULL
    );
}
