//! `sidebar_geometry_*` through the C ABI: the sidebar sends its slots and
//! acceptance table once per drag and asks the kept geometry with a point on
//! every mouse move.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(operation: &str, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let operation = CString::new(operation).unwrap();
    let mut output = vec![0u8; 1 << 14];
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

fn frame(y: f64) -> Value {
    json!({"x": 0.0, "y": y, "width": 200.0, "height": 20.0})
}

/// Section `s` 0..20; loose `w1` 20..40; group `g1` 40..60 with `m1` 60..80 and `m2` 80..100.
fn slots() -> Value {
    json!([
        {"key": "s", "section": "s", "frame": frame(0.0), "kind": "section"},
        {"key": "w1", "item": "w1", "section": "s", "frame": frame(20.0), "kind": "row"},
        {"key": "g1", "item": "g1", "section": "s", "frame": frame(40.0), "kind": "group"},
        {"key": "m1", "item": "m1", "section": "s", "parent": "g1", "frame": frame(60.0), "kind": "row"},
        {"key": "m2", "item": "m2", "section": "s", "parent": "g1", "frame": frame(80.0), "kind": "row"},
    ])
}

fn new(request: Value) -> u64 {
    let (code, body) = call("sidebar_geometry_new", &request);
    assert_eq!(code, OK);
    body["id"].as_u64().unwrap()
}

#[test]
fn a_kept_geometry_answers_hits_by_point() {
    let id = new(json!({"slots": slots()}));
    let (code, body) = call("sidebar_geometry_hit", &json!({"id": id, "x": 100.0, "y": 50.0}));
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"hit": {"slot": 2, "zone": "into", "target": {"section": "s", "parent": "g1"}, "refusal": null}})
    );
    let (_, body) = call("sidebar_geometry_hit", &json!({"id": id, "x": 100.0, "y": 5.0}));
    assert_eq!(body["hit"]["target"], json!({"section": "s", "index": 0}));
}

#[test]
fn a_dragged_group_goes_around_a_group_it_cannot_enter() {
    let refused = json!({"before": false, "into": false, "after": false, "refusal": "nesting"});
    let id = new(json!({
        "slots": slots(),
        "acceptance": {
            "s": {"into": true},
            "w1": {"before": true, "after": true},
            "g1": {"before": true, "after": true},
            "m1": refused,
            "m2": refused,
        },
    }));
    let (_, body) = call("sidebar_geometry_hit", &json!({"id": id, "x": 100.0, "y": 85.0}));
    assert_eq!(body["hit"]["target"], json!({"section": "s", "after": "g1"}));
    let (_, body) =
        call("sidebar_geometry_beside", &json!({"id": id, "key": "m1", "after": false}));
    assert_eq!(body, json!({"hit": null}));
    let (_, body) =
        call("sidebar_geometry_beside", &json!({"id": id, "key": "g1", "after": false}));
    assert_eq!(body["hit"]["target"], json!({"section": "s", "before": "g1"}));
}

#[test]
fn edge_y_holds_a_turning_back_drag_inside_the_margin() {
    let id = new(json!({"slots": slots()}));
    // The card's bottom just past m1's middle (70) while turning back from before m1: held.
    let held = json!({
        "id": id, "top": 51.0, "bottom": 71.0, "x": 100.0, "moving_up": false,
        "current": {"section": "s", "parent": "g1", "before": "m1"}, "reversing": true,
    });
    assert_eq!(call("sidebar_geometry_edge_y", &held).1, json!({"y": null}));
    let mut moving = held.clone();
    moving["reversing"] = json!(false);
    assert_eq!(call("sidebar_geometry_edge_y", &moving).1, json!({"y": 71.0}));
}

#[test]
fn the_outline_moves_a_bottom_edge_drop_out_of_its_group() {
    let id = new(json!({
        "slots": slots(),
        "outline": {"indent": {"step": 8.0}, "leading": 10.0, "width": 400.0},
    }));
    let (_, inside) = call("sidebar_geometry_hit", &json!({"id": id, "x": 16.0, "y": 98.0}));
    assert_eq!(inside["hit"]["target"], json!({"section": "s", "parent": "g1", "after": "m2"}));
    let (_, out) = call("sidebar_geometry_hit", &json!({"id": id, "x": 11.0, "y": 98.0}));
    assert_eq!(out["hit"]["target"], json!({"section": "s", "after": "g1"}));
}

#[test]
fn a_freed_geometry_is_gone() {
    let id = new(json!({"slots": slots()}));
    assert_eq!(call("sidebar_geometry_free", &json!({"id": id})).0, OK);
    let point = json!({"id": id, "x": 0.0, "y": 0.0});
    assert_eq!(call("sidebar_geometry_hit", &point).1, json!({"gone": true}));
}

#[test]
fn base_y_reads_through_the_open_gap() {
    let (code, body) =
        call("sidebar_geometry_base_y", &json!({"y": 70.0, "gap_y": 40.0, "gap_height": 20.0}));
    assert_eq!(code, OK);
    assert_eq!(body, json!({"y": 50.0}));
}

#[test]
fn malformed_requests_and_unknown_ops_are_refused() {
    assert_eq!(call("sidebar_geometry_new", &json!({"slots": "nope"})).0, ERR_INVALID);
    assert_eq!(call("sidebar_geometry_hit", &json!({"x": 1.0})).0, ERR_INVALID);
    assert_eq!(call("sidebar_geometry_nope", &json!({})).0, ERR_INVALID);
}
