//! `tab_drag_rule_*`, `tab_moves_*` and `drop_overlay_*` through the C ABI:
//! the wire shapes the app's `+Wire.swift` adapters send and read.

use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call_with(operation: &str, request: &Value, capacity: usize) -> (i32, Value, usize) {
    let request = serde_json::to_vec(request).unwrap();
    let operation = CString::new(operation).unwrap();
    let mut output = vec![0u8; capacity];
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
    (code, body, len)
}

fn call(operation: &str, request: &Value) -> (i32, Value) {
    let (code, body, _) = call_with(operation, request, 1 << 12);
    (code, body)
}

fn ok(operation: &str, request: &Value) -> Value {
    let (code, body) = call(operation, request);
    assert_eq!(code, OK, "{operation}");
    body
}

fn context() -> Value {
    json!({
        "source_pane_id": "p1",
        "source_pane_tab_count": 3,
        "source_workspace_id": "w",
        "source_workspace_tab_count": 3,
        "dragged_tab_count": 1,
        "source_strip_id": "S",
        "source_index": 0,
    })
}

#[test]
fn a_move_resolves_its_preview_and_outcome() {
    let own = json!({"kind": "strip", "strip_id": "S", "index": 0});
    let stay = ok(
        "tab_drag_rule_resolve",
        &json!({"kind": own, "inside_window": true, "point": {"x": 0, "y": 0}, "context": context()}),
    );
    assert_eq!(stay, json!({"preview": "stay", "outcome": {"outcome": "cancel"}}));

    let split = json!({"kind": "new_split", "pane_id": "p2", "edge": "left"});
    let target = ok(
        "tab_drag_rule_resolve",
        &json!({"kind": split, "inside_window": true, "context": context()}),
    );
    assert_eq!(
        target,
        json!({"preview": "target", "outcome": {"outcome": "new_split", "pane_id": "p2", "edge": "left"}})
    );

    let refused = ok(
        "tab_drag_rule_resolve",
        &json!({"kind": split, "refused_reason": "No room", "inside_window": true, "context": context()}),
    );
    assert_eq!(refused["preview"], "refused");
    assert_eq!(refused["refusal"], json!({"code": "surface", "reason": "No room"}));

    let none = ok("tab_drag_rule_resolve", &json!({"inside_window": true, "context": context()}));
    assert_eq!(none, json!({"preview": "none", "outcome": {"outcome": "cancel"}}));

    let away = ok(
        "tab_drag_rule_resolve",
        &json!({"inside_window": false, "point": {"x": 3.0, "y": 4.0}, "context": context()}),
    );
    assert_eq!(
        away,
        json!({"preview": "new_window", "outcome": {"outcome": "tear_off", "point": {"x": 3.0, "y": 4.0}}})
    );
}

#[test]
fn verdict_winner_outcome_and_context() {
    let before = json!({"kind": "new_column", "screen_id": "s"});
    assert_eq!(
        ok("tab_drag_rule_verdict", &json!({"kind": before, "context": context()})),
        json!({"verdict": "refuse", "refusal": {"code": "column_before_first"}})
    );
    let own = json!({"kind": "strip", "strip_id": "S", "index": 0});
    assert_eq!(
        ok("tab_drag_rule_blocks", &json!({"kind": own, "context": context()})),
        json!({"blocks": true})
    );
    let split = json!({"kind": "new_split", "pane_id": "p1", "edge": "top"});
    assert_eq!(
        ok("tab_drag_rule_winner", &json!({"kinds": [null, before, split], "context": context()})),
        json!({"index": 2})
    );
    assert_eq!(
        ok("tab_drag_rule_winner", &json!({"kinds": [own, split], "context": context()})),
        json!({"index": null})
    );
    let gap = json!({"kind": "new_workspace", "index": -1});
    assert_eq!(
        ok(
            "tab_drag_rule_outcome",
            &json!({"kind": gap, "inside_window": true, "context": context()})
        ),
        json!({"outcome": "new_workspace", "group_id": null, "index": null})
    );
    let mut lone = context();
    lone["source_pane_tab_count"] = json!(1);
    assert_eq!(
        ok("tab_drag_rule_context", &json!({"context": lone, "pane": "p1"})),
        json!({"empties_source_pane": true, "empties_source_workspace": false, "splits_behind": true})
    );
}

#[test]
fn the_move_rules() {
    assert_eq!(
        ok("tab_moves_split_behind", &json!({"edge": "left"})),
        json!({"edge": "right", "swaps_back": false})
    );
    assert_eq!(
        ok("tab_moves_fallback_split", &json!({"edge": "top"})),
        json!({"direction": "down", "swaps_back": true})
    );
    assert_eq!(ok("tab_moves_dock_width", &json!({"edge": "left"})), json!({"width": 0.5}));
    assert_eq!(
        ok("tab_moves_dock_width", &json!({"edge": "right"})),
        json!({"needs_beside": true})
    );
    assert_eq!(
        ok("tab_moves_dock_width", &json!({"edge": "right", "beside": 0.25, "asked_beside": true})),
        json!({"width": 0.25})
    );
    assert_eq!(
        ok(
            "tab_moves_column_anchor",
            &json!({"column_panes": ["a", "b"], "screen_panes": ["c"], "avoiding": "b"})
        ),
        json!({"pane": "a"})
    );
    assert_eq!(ok("tab_moves_column_anchor", &json!({})), json!({"pane": null}));
}

#[test]
fn the_overlay_rects() {
    let region = json!({"x": 10.0, "y": 20.0, "width": 200.0, "height": 100.0});
    assert_eq!(
        ok("drop_overlay_split_preview", &json!({"region": region, "zone": "left", "gap": 8.0})),
        json!({
            "incoming": {"x": 10.0, "y": 20.0, "width": 96.0, "height": 100.0},
            "existing": {"x": 114.0, "y": 20.0, "width": 96.0, "height": 100.0},
        })
    );
    assert_eq!(
        ok("drop_overlay_split_preview", &json!({"region": region, "zone": "center", "gap": 8.0})),
        json!({"incoming": region, "existing": null})
    );
    assert_eq!(
        ok(
            "drop_overlay_insertion_line",
            &json!({"region": region, "zone": "center", "width": 4.0, "length": 0.5})
        ),
        json!({"rect": {"x": 60.0, "y": 24.0, "width": 100.0, "height": 4.0}})
    );
    assert_eq!(ok("drop_overlay_glow_edges", &json!({"zone": "top"})), json!({"edges": ["min_y"]}));
    assert_eq!(
        ok("drop_overlay_band", &json!({"rect": region, "edge": "max_x", "depth": 30.0})),
        json!({"rect": {"x": 180.0, "y": 20.0, "width": 30.0, "height": 100.0}})
    );
    assert_eq!(
        ok(
            "drop_overlay_inset_card",
            &json!({"target": region, "fraction": 0.5, "max_width": 300.0, "height": 40.0})
        ),
        json!({"rect": {"x": 60.0, "y": 50.0, "width": 100.0, "height": 40.0}})
    );
    assert_eq!(
        ok(
            "drop_overlay_tab_pill",
            &json!({"target": region, "width": 80.0, "height": 24.0, "inset": 6.0})
        ),
        json!({"rect": {"x": 16.0, "y": 26.0, "width": 80.0, "height": 24.0}})
    );
    assert_eq!(
        ok(
            "drop_overlay_morph_start",
            &json!({"pointer": {"x": 100.0, "y": 50.0}, "width": 120.0})
        ),
        json!({"rect": {"x": 40.0, "y": 10.0, "width": 120.0, "height": 80.0}})
    );
}

#[test]
fn a_bad_request_is_invalid_and_a_small_buffer_names_its_size() {
    assert_eq!(call("tab_drag_rule_resolve", &json!({"inside_window": "yes"})).0, ERR_INVALID);
    assert_eq!(call("tab_moves_split_behind", &json!({"edge": "middle"})).0, ERR_INVALID);
    assert_eq!(call("drop_overlay_nope", &json!({})).0, ERR_INVALID);
    let (code, _, needed) = call_with("tab_moves_split_behind", &json!({"edge": "left"}), 4);
    assert_eq!(code, ERR_BUFFER);
    let (code, body, _) = call_with("tab_moves_split_behind", &json!({"edge": "left"}), needed);
    assert_eq!(code, OK);
    assert_eq!(body["edge"], "right");
}
