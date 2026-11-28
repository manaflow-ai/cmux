//! `drop_*` through the C ABI: the app sends its facts and acts on the
//! answer (cmux-layout-reducer `drop_rules` holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 12];
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
        if code == OK { serde_json::from_slice(&output[..len]).unwrap() } else { Value::Null };
    (code, body)
}

#[test]
fn a_tab_lands_by_its_nearest_edge_and_its_group() {
    let (code, body) = call(
        c"drop_tab_insertion",
        &json!({"draggedMinX": 51.0, "groupStart": 0.0, "otherWidths": [100.0, 100.0]}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"index": 1}));
    let entries = json!([
        {"width": 30.0, "group": "g", "isGroupChip": true},
        {"width": 100.0, "group": "g"},
        {"width": 100.0}
    ]);
    let (_, body) = call(
        c"drop_tab_over_groups",
        &json!({"entries": entries, "draggedMinX": 135.0, "currentGroup": "g", "hysteresis": 10.0}),
    );
    assert_eq!(body, json!({"index": 1, "group": "g"}));
    let (_, body) =
        call(c"drop_group_over_groups", &json!({"entries": entries, "draggedMinX": 999.0}));
    assert_eq!(body, json!({"unitIndex": 2, "tabIndex": 2}));
}

#[test]
fn a_workspace_drag_link_and_file_drop() {
    let (code, body) = call(
        c"drop_workspace_outcome",
        &json!({"window": "w1", "sourceWindow": "w1", "sidebarHit": "position"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body, json!({"outcome": "window", "id": "w1", "target": {"kind": "position"}}));
    let (_, body) = call(c"drop_workspace_outcome", &json!({"draggingAllOfSource": true}));
    assert_eq!(body, json!({"outcome": "moveWindow"}));
    let (_, body) =
        call(c"drop_link_plan", &json!({"target": {"paneEdge": "left"}, "takesTabs": false}));
    assert_eq!(body, json!({"plan": "split", "edge": "left"}));
    let (_, body) = call(
        c"drop_transfer_mode",
        &json!({"sources": [1, 1], "destination": 2, "option": false, "command": false}),
    );
    assert_eq!(body, json!({"mode": "copy"}));
    let (code, _) = call(c"drop_nothing", &json!({}));
    assert_eq!(code, ERR_INVALID);
}
