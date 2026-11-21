//! `sidebar_edits` through the C ABI: the sidebar sends a skeleton of its
//! sections with a structural intent (or a step or name rule) and rebuilds
//! its rows by id from the reply.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"sidebar_edits".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

fn sections() -> Value {
    json!([{"id": {"kind": "machine", "id": "local"}, "nodes": [
        {"kind": "workspace", "workspace": {"id": "a", "machine": "local"}},
        {"kind": "group", "group": {"id": "g", "members": [
            {"kind": "workspace", "workspace": {"id": "b", "machine": "local"}}
        ]}}
    ]}])
}

#[test]
fn an_edit_answers_the_new_tree() {
    let request = json!({
        "op": "edit",
        "sections": sections(),
        "intent": {"kind": "reorder", "ids": ["b"], "position": {"section": {"kind": "machine", "id": "local"}, "index": 0}},
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["changed"], json!(true));
    assert_eq!(
        body["sections"][0]["nodes"],
        json!([
            {"kind": "workspace", "workspace": {"id": "b", "machine": "local"}},
            {"kind": "workspace", "workspace": {"id": "a", "machine": "local"}},
        ])
    );
}

#[test]
fn a_refused_edit_answers_no_tree() {
    let request = json!({"op": "edit", "sections": sections(), "intent": {"kind": "ungroup", "group": "missing"}});
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"changed": false, "sections": null}));
}

#[test]
fn step_and_name_rules_answer_plain_values() {
    let keyboard =
        json!({"op": "keyboard_target", "sections": sections(), "ids": ["a"], "direction": "down"});
    let (code, body) = call(&serde_json::to_vec(&keyboard).unwrap());
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"section": {"kind": "machine", "id": "local"}, "group": "g", "index": 0})
    );
    let (_, body) =
        call(&serde_json::to_vec(&json!({"op": "valid_group_name", "name": "grp_1"})).unwrap());
    assert_eq!(body, json!(false));
    let placement =
        json!({"op": "global_index", "local_index": 0, "local": ["b"], "global": ["a", "b"]});
    let (_, body) = call(&serde_json::to_vec(&placement).unwrap());
    assert_eq!(body, json!(1));
}

#[test]
fn a_malformed_request_is_invalid() {
    let (code, _) = call(br#"{"op": "edit"}"#);
    assert_eq!(code, ERR_INVALID);
}

#[test]
fn an_attach_and_the_tree_rows_cross_the_abi() {
    let request = json!({
        "op": "edit",
        "sections": sections(),
        "intent": {"kind": "attach", "ids": ["b"], "creator": "a"},
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["changed"], json!(true));
    // `b` leaves its group, which goes with its last row.
    assert_eq!(
        body["sections"][0]["nodes"],
        json!([
            {"kind": "workspace", "workspace": {"id": "a", "machine": "local"}},
            {"kind": "workspace", "workspace": {"id": "b", "machine": "local", "creator": "a"}},
        ])
    );
    let tree = json!({"op": "tree", "sections": body["sections"], "indent": 16});
    let (code, body) = call(&serde_json::to_vec(&tree).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body["rows"][1]["id"], json!("b"));
    assert_eq!(body["rows"][1]["depth"], json!(1));
    assert_eq!(body["rows"][1]["indent"], json!(16));
    assert_eq!(body["rows"][1]["guides"], json!(["end"]));
}
