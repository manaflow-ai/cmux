//! `sidebar_change_failure`: the app's one source for the text of a refused or
//! failed sidebar document change (the reducer's code, or a failure kind).

use cmux_layout_reducer::sidebar_doc::{CHANGE_FAILURES, Refusal};
use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn answer(code: &str) -> Value {
    let bytes = serde_json::to_vec(&json!({ "code": code })).unwrap();
    let op = std::ffi::CString::new("sidebar_change_failure").unwrap();
    let mut output = vec![0u8; 4096];
    let mut len = 0;
    let status = unsafe {
        cmux_layout_reducer_json(
            bytes.as_ptr(),
            bytes.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    assert_eq!(status, OK, "{code}");
    serde_json::from_slice(&output[..len]).unwrap()
}

#[test]
fn each_refusal_code_answers_its_own_text() {
    for refusal in Refusal::ALL {
        let reply = answer(refusal.as_str());
        assert_eq!(reply["text"], refusal.text(), "{refusal}");
        assert_eq!(reply["refusal"], true, "{refusal}");
    }
}

#[test]
fn a_failure_kind_answers_its_text_and_is_no_refusal() {
    for failure in CHANGE_FAILURES {
        let reply = answer(failure);
        assert_eq!(reply["refusal"], false, "{failure}");
        assert!(!reply["text"].as_str().unwrap().is_empty());
    }
    assert_eq!(answer("something_new")["text"], answer("failed")["text"]);
}
