//! `sidebar_section_customization` and `sidebar_projection_edit` through the
//! C ABI: the shapes the native sidebar sends and decodes.

use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Option<Value>) {
    let request = request.to_string();
    let mut output = vec![0u8; 16_384];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
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
fn the_outline_request_plans_hides_moves_and_restores() {
    let (code, body) = call(
        c"sidebar_section_customization",
        &json!({
            "sections": {"hidden": ["recents"], "order": ["projects"]},
            "workspaces": {"ws-7": {"hidden": true}, "ws-9": {"group": "Work", "order": 1}},
            "selected": "ws-0",
            "outline": [
                {"id": "sec_m_local", "keys": ["projects"], "region": "middle", "groups": [{"id": "grp", "name": "Work"}]},
                {"id": "recents", "keys": ["recents"], "region": "bottom", "groups": []}
            ],
            "locations": {"ws-0": {"section": "sec_m_local"}, "ws-7": {"section": "sec_m_local"}, "ws-9": {"section": "sec_m_local"}}
        }),
    );
    assert_eq!(code, OK);
    let body = body.expect("reply");
    assert_eq!(body["hidden_sections"], json!(["recents"]));
    assert_eq!(body["hidden_workspaces"], json!(["ws-7"]));
    assert_eq!(body["workspace_groups"], json!({"ws-9": "grp"}));
    assert_eq!(body["workspace_orders"], json!({"ws-9": 1}));
    assert_eq!(body["selection_overrides_hide"], json!(false));
    assert_eq!(body["complete"], json!(true));
    assert_eq!(
        body["restorable"],
        json!([
            {"kind": "section", "id": "recents", "key": "recents"},
            {"kind": "workspace", "id": "ws-7", "key": "ws-7"}
        ])
    );
    assert!(body["revision"].as_u64().is_some());
}

#[test]
fn show_all_through_the_abi_returns_the_values_to_write() {
    let (code, body) = call(
        c"sidebar_projection_edit",
        &json!({
            "sections": {"hidden": ["recents"], "order": ["projects"]},
            "workspaces": {"ws-7": {"hidden": true}},
            "edit": {"op": "show_all"}
        }),
    );
    assert_eq!(code, OK);
    let body = body.expect("reply");
    assert_eq!(body["sections"], json!({"order": ["projects"]}));
    assert_eq!(body["workspaces"], Value::Null);
    assert_eq!(body["changed"], json!(true));
}
