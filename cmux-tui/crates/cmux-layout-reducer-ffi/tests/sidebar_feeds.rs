//! `sidebar_feeds` through the C ABI: a rule answers the same through the JSON op, and a request
//! with no known rule is refused.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Option<Value>) {
    let mut output = vec![0u8; 1 << 16];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_feeds".as_ptr(),
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
fn priority_entries_answer_through_the_c_abi() {
    let now = 1_760_000_000.0;
    let request = json!({
        "rule": "entries",
        "now": now,
        "lanes": [
            {"id": "idle", "title": "Idle", "state": "idle", "since": now - 120.0},
            {"id": "asks", "title": "Asks", "state": "input", "since": now - 600.0, "peer": "mini"},
            {"id": "old", "title": "Old", "state": "idle", "since": now - 200_000.0}
        ]
    });
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    let body = body.unwrap();
    let ids: Vec<&str> =
        body["entries"].as_array().unwrap().iter().map(|e| e["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["asks", "idle"]);
    assert_eq!(body["entries"][0]["machine"], json!("mini"));
    assert_eq!(body["entries"][0]["state"], json!("needsYou"));
}

#[test]
fn chief_and_tree_answer_through_the_c_abi() {
    let request = json!({
        "rule": "chief",
        "lanes": [
            {"id": "t", "name": "optchat-6b68ac4a-9", "state": "working"},
            {"id": "s", "name": "optchat-sub-6b68ac4a-a2", "title": "a2 · Fix", "state": "input"}
        ]
    });
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    let body = body.unwrap();
    assert_eq!(body["status"], json!({"activity": "working", "badge": 1}));
    assert_eq!(body["subagents"][0]["title"], json!("Fix"));

    let request = json!({"rule": "holding", "parents": {"a": "b"}, "saved": {"b": "a"}});
    let (code, body) = call(request.to_string().as_bytes());
    assert_eq!(code, OK);
    assert_eq!(body.unwrap(), json!({"parents": {"b": "a"}}));
}

#[test]
fn unknown_rules_and_bad_json_are_refused() {
    assert_eq!(call(br#"{"rule":"nope"}"#).0, ERR_INVALID);
    assert_eq!(call(b"not json").0, ERR_INVALID);
}
