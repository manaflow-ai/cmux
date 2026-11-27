//! `tab_groups_*` through the C ABI: the strip sends its tabs and groups and gets back the
//! display order, the chips, the selection leaving a collapsing group and the reducer's strip.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &Value) -> (i32, Value) {
    let op = CString::new(op).unwrap();
    let request = serde_json::to_vec(request).unwrap();
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

fn tabs() -> Value {
    json!([{"id": "g1", "group": "G"}, {"id": "a"}, {"id": "g2", "group": "G"}, {"id": "p", "pinned": true}])
}

#[test]
fn normalized_gathers_members_behind_the_pinned_tabs() {
    let (code, body) = call("tab_groups_normalized", &json!({"tabs": tabs(), "groups": ["G"]}));
    assert_eq!(code, OK);
    let ids: Vec<&str> =
        body.as_array().unwrap().iter().map(|tab| tab["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["p", "g1", "g2", "a"]);
}

#[test]
fn layout_puts_a_chip_before_the_group() {
    let request = json!({"tabs": [{"id": "g1", "group": "G"}, {"id": "a"}], "groups": [{"id": "G"}], "selected": "a"});
    let (code, body) = call("tab_groups_layout", &request);
    assert_eq!(code, OK);
    assert_eq!(body[0], json!({"kind": "chip", "group": "G"}));
    assert_eq!(body[2]["selected"], json!(true));
}

#[test]
fn collapsing_over_the_selection_moves_it_out() {
    let request =
        json!({"group": "G", "tabs": [{"id": "a"}, {"id": "g1", "group": "G"}], "selected": "g1"});
    assert_eq!(
        call("tab_groups_selection_after_collapsing", &request),
        (OK, json!({"selected": "a"}))
    );
    assert_eq!(
        call("tab_groups_selection_before_collapsing", &request),
        (OK, json!({"selected": "a"}))
    );
}

#[test]
fn apply_runs_the_reducer_and_asks_for_a_tab_it_needs() {
    let strip =
        json!({"tabs": [{"id": "g1", "group": "G"}], "groups": [{"id": "G"}], "selected": "g1"});
    let (code, body) = call(
        "tab_groups_apply",
        &json!({"strip": strip, "intent": {"kind": "toggleGroupCollapsed", "group": "G"}}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["needsTab"], json!(true));
    let made = json!({"strip": strip, "intent": {"kind": "toggleGroupCollapsed", "group": "G", "made": {"id": "n"}}});
    let (_, body) = call("tab_groups_apply", &made);
    assert_eq!(body["applied"], json!(true));
    assert_eq!(body["strip"]["selected"], json!("n"));
}

#[test]
fn a_bad_request_is_invalid() {
    assert_eq!(call("tab_groups_apply", &json!({"strip": {}})).0, ERR_INVALID);
    assert_eq!(call("tab_groups_nope", &json!({})).0, ERR_INVALID);
}
