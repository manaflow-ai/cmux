//! `keep_awake_plan` through the C ABI: Keep Mac Awake sends the local tabs whose shell runs a
//! command and the clock, holds off idle sleep while `running` is above zero, watches the `quiet`
//! ones' output and asks again after `recheck_ms`.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"keep_awake_plan".as_ptr(),
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
fn keep_awake_plan_counts_long_printing_commands_and_names_the_next_look() {
    let now = 1_800_000_000_000_u64;
    let minute = 60_000_u64;
    let request = json!({
        "now_ms": now,
        "commands": [
            {"since_ms": now - 5 * minute, "output_ms": now - 1_000, "terminal": true},
            {"since_ms": now - 90 * minute, "output_ms": now - 30 * minute, "terminal": true},
            {"since_ms": now - 5 * minute, "output_ms": now, "terminal": true, "agent": true},
            {"since_ms": now - 30_000, "terminal": true},
        ],
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(body, json!({"running": 1, "quiet": [1], "recheck_ms": 30_000}));
}

#[test]
fn keep_awake_plan_refuses_a_malformed_request() {
    assert_eq!(call(b"{\"now_ms\":\"soon\"}").0, ERR_INVALID);
    assert_eq!(call(b"not json").0, ERR_INVALID);
}
