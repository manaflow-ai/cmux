//! `optimistic` through the C ABI: the store's golden vectors (cmux-layout-reducer
//! `tests/data/optimistic_vectors.json`) answer the same view over `cmux_layout_reducer_json`,
//! and a malformed request is refused with nothing written.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"optimistic".as_ptr(),
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
fn optimistic_vectors_answer_over_the_c_abi() {
    let cases: Vec<Value> = serde_json::from_str(include_str!(
        "../../cmux-layout-reducer/tests/data/optimistic_vectors.json"
    ))
    .expect("vectors");
    for case in cases {
        let request = serde_json::to_vec(&case["request"]).expect("request");
        let (code, body) = call(&request);
        assert_eq!(code, OK, "{}", case["name"]);
        assert_eq!(body.as_ref(), Some(&case["response"]), "{}", case["name"]);
    }
}

#[test]
fn optimistic_refuses_a_malformed_request() {
    assert_eq!(call(br#"{"op":"split"}"#).0, ERR_INVALID);
    assert_eq!(call(b"not json").0, ERR_INVALID);
}
