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

/// A screen split into a 200-pane chain nests deeper than serde_json's default limit (128); its
/// optimistic view still answers over the C ABI, and absurd nesting is still refused.
#[test]
fn optimistic_answers_a_deep_chain_over_the_c_abi() {
    let mut layout = String::from(r#"{"type":"leaf","pane":200}"#);
    for pane in (1..200).rev() {
        layout = format!(
            r#"{{"type":"split","dir":"right","ratio":0.5,"a":{{"type":"leaf","pane":{pane}}},"b":{layout}}}"#
        );
    }
    let request = format!(r#"{{"op":"remove_pane","pane":200,"screen":{{"layout":{layout}}}}}"#);
    // The answer nests as deep as the request, past this test's own JSON reader: check it raw.
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
    assert_eq!(code, OK);
    let answer = std::str::from_utf8(&output[..len]).expect("utf-8");
    assert!(
        answer.starts_with(r#"{"columns":[],"layout":{"a":{"pane":1,"type":"leaf"}"#),
        "{}",
        &answer[..answer.len().min(80)]
    );
    assert!(answer.contains(r#""pane":199"#) && !answer.contains(r#""pane":200"#));
    let absurd = "[".repeat(100_000);
    assert_eq!(call(absurd.as_bytes()).0, ERR_INVALID);
}
