//! `auto_archive_plan` through the C ABI: auto-archive's coordinator sends
//! its candidates, the groups' rules, the policy and the clock once per pass,
//! sweep or review list, and archives (or suggests) the indices it gets back.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn call(request: &[u8]) -> (i32, Value) {
    let mut output = vec![0u8; 1 << 14];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"auto_archive_plan".as_ptr(),
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
fn auto_archive_plan_answers_due_indices_and_the_next_check() {
    let now = 1_800_000_000.0_f64;
    let day = 86_400.0_f64;
    let request = json!({
        "candidates": [
            {"last_active": now - day, "groups": []},
            {"last_active": now - 4.0 * day, "groups": ["g_ci"]},
            {"last_active": now - 9.0 * day},
            {"last_active": now - 9.0 * day, "pinned": true},
            {},
        ],
        "rules": {"g_ci": 24},
        "policy": {"style": "quiet", "idle_days": 3.0},
        "trigger": "background",
        "now": now,
    });
    let (code, body) = call(&serde_json::to_vec(&request).unwrap());
    assert_eq!(code, OK);
    assert_eq!(
        body,
        json!({"due": [2, 1], "next_check": now + 2.0 * day, "first_sight": [4], "snoozed": false})
    );
}

#[test]
fn auto_archive_plan_refuses_a_malformed_request() {
    assert_eq!(call(b"{\"policy\":{\"style\":\"soon\"}}").0, ERR_INVALID);
    assert_eq!(call(b"not json").0, ERR_INVALID);
}
