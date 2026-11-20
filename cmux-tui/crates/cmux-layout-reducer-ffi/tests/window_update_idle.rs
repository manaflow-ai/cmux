//! The app must receive the idle decision through the shipped JSON ABI, not only in Rust unit tests.
use cmux_layout_reducer_ffi::{OK, cmux_layout_reducer_json};
use serde_json::{Value, json};

fn decide(facts: Value) -> Value {
    let request = serde_json::to_vec(&facts).unwrap();
    let mut output = [0_u8; 1024];
    let mut written = 0_usize;
    // SAFETY: request and output remain live for the call; each pointer has its stated length,
    // the operation is NUL-terminated, and written is a valid exclusive output pointer.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            c"window_update_idle_install".as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut written,
        )
    };
    assert_eq!(code, OK);
    serde_json::from_slice(&output[..written]).unwrap()
}

#[test]
fn automatic_update_idle_operation_requires_complete_idle_facts() {
    let mut facts = json!({"enabled": true, "idleMinutes": 15,
        "inputIdleSeconds": 900, "runningTurns": 0, "unsentDrafts": 0});
    assert_eq!(decide(facts.clone()), json!({"install": true, "hold": null}));
    for (field, value, reason) in [
        ("enabled", json!(false), "off"),
        ("runningTurns", json!(1), "agentWorking"),
        ("unsentDrafts", json!(1), "unsentDraft"),
        ("runningTurns", Value::Null, "unknown"),
    ] {
        let mut held = facts.clone();
        held[field] = value;
        assert_eq!(decide(held), json!({"install": false, "hold": {"reason": reason}}));
    }
    facts["inputIdleSeconds"] = json!(899);
    assert_eq!(
        decide(facts),
        json!({"install": false,
        "hold": {"reason": "notIdle", "secondsLeft": 1.0}})
    );
}
