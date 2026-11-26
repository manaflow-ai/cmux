//! The layout geometry rules through the C ABI (`cmux_layout_reducer_json`, ops `layout_geometry_*`):
//! every case of the reducer's vectors (`cmux-layout-reducer/tests/data/layout_geometry_vectors.json`
//! and `layout_geometry_split_vectors.json`, answered by a transliteration of the Swift) answers the
//! same through the C call, and an unknown op or a bad request is refused.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::Value;
use std::ffi::CString;

const VECTORS: [&str; 3] = [
    include_str!("../../cmux-layout-reducer/tests/data/layout_geometry_vectors.json"),
    include_str!("../../cmux-layout-reducer/tests/data/layout_geometry_split_vectors.json"),
    include_str!("../../cmux-layout-reducer/tests/data/layout_geometry_strip_vectors.json"),
];

fn call(op: &str, request: &[u8]) -> Result<Value, i32> {
    let op = CString::new(op).expect("op");
    let mut buffer = vec![0u8; 64];
    loop {
        let mut len = 0usize;
        let status = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                op.as_ptr(),
                buffer.as_mut_ptr(),
                buffer.len(),
                &mut len,
            )
        };
        match status {
            OK => return Ok(serde_json::from_slice(&buffer[..len]).expect("reply")),
            ERR_BUFFER => buffer.resize(len, 0),
            status => return Err(status),
        }
    }
}

fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.as_f64().expect("f64"), y.as_f64().expect("f64"));
            x == y || (x - y).abs() <= 1e-9 * x.abs().max(y.abs()).max(1.)
        }
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

#[test]
fn layout_geometry_vectors_answer_through_the_c_call() {
    for vectors in VECTORS {
        let cases: Vec<Value> = serde_json::from_str(vectors).expect("vectors");
        assert!(cases.len() >= 1000, "the vectors lost cases: {}", cases.len());
        for (index, case) in cases.iter().enumerate() {
            let op = case["op"].as_str().expect("op");
            let request = serde_json::to_vec(&case["request"]).expect("request");
            let answer = call(op, &request).unwrap_or_else(|e| panic!("{index} {op}: status {e}"));
            assert!(
                same(&answer, &case["response"]),
                "{index} {op}: {answer} != {}",
                case["response"]
            );
        }
    }
}

#[test]
fn layout_geometry_refuses_unknown_ops_and_bad_requests() {
    assert_eq!(call("layout_geometry_nope", b"{}"), Err(ERR_INVALID));
    assert_eq!(call("layout_geometry_drop_zone", b"{}"), Err(ERR_INVALID));
    assert_eq!(call("layout_geometry_drop_zone", b"not json"), Err(ERR_INVALID));
}
