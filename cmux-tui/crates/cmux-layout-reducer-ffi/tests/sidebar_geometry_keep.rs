//! `sidebar_geometry_*` keeps at most `KEEP` drag geometries: the oldest is
//! dropped and answers `gone`. Its own test binary, so the churn never drops a
//! geometry another test is asking.

use cmux_layout_reducer_ffi::SIDEBAR_GEOMETRY_KEEP as KEEP;
use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(operation: &str, request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
    let operation = CString::new(operation).unwrap();
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
    assert_eq!(code, OK);
    serde_json::from_slice(&output[..len]).unwrap()
}

fn new() -> u64 {
    let slot = json!({"key": "a", "item": "a", "section": "s", "kind": "row",
                      "frame": {"x": 0.0, "y": 0.0, "width": 200.0, "height": 20.0}});
    call("sidebar_geometry_new", &json!({"slots": [slot]}))["id"].as_u64().unwrap()
}

#[test]
fn the_oldest_geometry_past_keep_is_gone() {
    let first = new();
    let mut last = first;
    for _ in 0..KEEP {
        last = new();
    }
    let point = |id: u64| json!({"id": id, "x": 10.0, "y": 5.0});
    assert_eq!(call("sidebar_geometry_hit", &point(first)), json!({"gone": true}));
    assert_eq!(
        call("sidebar_geometry_hit", &point(last))["hit"]["target"],
        json!({"section": "s", "before": "a"})
    );
}
