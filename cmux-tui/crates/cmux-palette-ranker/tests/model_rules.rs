//! The palette model's rules through the C ABI the app links: `"operation": "model.<op>"` on
//! `cmux_palette_ranker_rank`, on a handle with nothing installed.

use cmux_palette_ranker::ffi::{
    ERR_INVALID, OK, cmux_palette_ranker_free, cmux_palette_ranker_new, cmux_palette_ranker_rank,
};
use serde_json::{Value, json};

fn call(request: &Value) -> (i32, Vec<u8>) {
    let ranker = cmux_palette_ranker_new();
    let bytes = serde_json::to_vec(request).expect("request");
    let mut response: *const u8 = std::ptr::null();
    let mut response_len = 0usize;
    // SAFETY: a live handle, a valid request buffer and writable out pointers.
    let code = unsafe {
        cmux_palette_ranker_rank(
            ranker,
            bytes.as_ptr(),
            bytes.len(),
            &mut response,
            &mut response_len,
        )
    };
    // SAFETY: the response stays valid until the next call on the handle, which is freed after.
    let answer = unsafe { std::slice::from_raw_parts(response, response_len) }.to_vec();
    // SAFETY: the handle came from cmux_palette_ranker_new and is freed once.
    unsafe { cmux_palette_ranker_free(ranker) };
    (code, answer)
}

#[test]
fn a_model_op_answers_without_an_install() {
    let (code, answer) = call(
        &json!({"operation": "model.moveSelection", "count": 3, "current": 2, "delta": 1, "wrap": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(serde_json::from_slice::<Value>(&answer).unwrap(), json!(0));
}

#[test]
fn a_model_op_whose_fields_the_rank_request_also_names_still_answers() {
    // "query" and "sections" mean other things to a rank request.
    let (code, answer) = call(&json!({
        "operation": "model.querySections", "sections": ["s"], "titles": ["Tab"], "query": "tab",
    }));
    assert_eq!(code, OK, "{}", String::from_utf8_lossy(&answer));
    assert_eq!(
        serde_json::from_slice::<Value>(&answer).unwrap(),
        json!([{"section": "s", "rows": [{"index": 0, "highlights": [0, 1, 2]}]}])
    );
}

#[test]
fn a_bad_model_request_is_invalid_with_a_message() {
    let (code, answer) = call(&json!({"operation": "model.nope"}));
    assert_eq!(code, ERR_INVALID);
    assert!(String::from_utf8_lossy(&answer).contains("model.nope"));
}
