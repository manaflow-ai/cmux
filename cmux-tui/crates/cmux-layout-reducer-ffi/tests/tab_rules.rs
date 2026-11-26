//! `tab_rules_*` through the C ABI: every case of
//! `schemas/tab-side-rules/vectors.json` (made by a line-by-line
//! transliteration of the CmuxNextTabs rules' Swift (AgentTabKey, NewTabTypeAhead.delta,
//! TabGroupDropMath, PageDecidedCloses) with random cases answers as the Swift did.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::ffi::CString;

const VECTORS: &str = include_str!("../../../../schemas/tab-side-rules/vectors.json");

fn call(op: &str, request: &Value) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let request = serde_json::to_vec(request).unwrap();
    let mut capacity = 256;
    loop {
        let mut output = vec![0u8; capacity];
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
        if code == ERR_BUFFER {
            capacity *= 4;
            continue;
        }
        let body =
            if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
        return (code, body);
    }
}

#[test]
fn every_vector_answers_as_the_swift_did() {
    let vectors: Value = serde_json::from_str(VECTORS).unwrap();
    assert_eq!(vectors["v"], 1);
    let cases = vectors["cases"].as_array().unwrap();
    assert!(cases.len() >= 1000, "{} cases", cases.len());
    let mut ops = BTreeSet::new();
    for case in cases {
        let op = case["op"].as_str().unwrap();
        ops.insert(op);
        let (code, answer) = call(op, &case["ask"]);
        assert_eq!(code, OK, "{case}");
        assert_eq!(answer, case["answer"], "{op} {}", case["ask"]);
    }
    assert_eq!(ops.len(), 8, "{ops:?}");
}

#[test]
fn an_unknown_op_or_a_bad_ask_is_refused() {
    assert_eq!(call("tab_rules_nothing", &json!({})).0, ERR_INVALID);
    assert_eq!(call("tab_rules_group_drop_tab", &json!({"start": "left"})).0, ERR_INVALID);
    assert_eq!(call("tab_rules_page_closes_finish", &json!({})).0, ERR_INVALID);
}
