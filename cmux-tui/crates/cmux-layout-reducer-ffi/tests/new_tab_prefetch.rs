//! The split New Tab planner is reachable through the generated JSON dispatch used by Swift.
use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

#[test]
fn new_tab_prefetch_dispatches_through_the_ffi_channel() {
    let request = serde_json::to_vec(&json!({
        "parked": {"width": 999.5, "height": 700.0},
        "splits": [
            {"width": 331.5, "height": 700.0},
            {"width": 999.5, "height": 332.5}
        ],
        "cached": [{"width": 999.5, "height": 700.0}]
    }))
    .unwrap();
    let operation = CString::new("new_tab_prefetch").unwrap();
    let mut output = vec![0; 1024];
    let mut length = 0;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut length,
        )
    };
    assert_eq!(code, OK);
    let answer: Value = serde_json::from_slice(&output[..length]).unwrap();
    assert_eq!(
        answer,
        json!([
            {"width": 331.5, "height": 700.0},
            {"width": 999.5, "height": 332.5},
            {"width": 999.5, "height": 700.0}
        ])
    );
}
