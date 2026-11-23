//! The app must receive the idle decision through the shipped JSON ABI, not only in Rust unit tests.
use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(request: &[u8], operation: &CStr) -> (i32, Vec<u8>) {
    let mut output = [0_u8; 1024];
    let mut written = 0_usize;
    // SAFETY: request and output remain live for the call; each pointer has its stated length,
    // the operation is NUL-terminated, and written is a valid exclusive output pointer.
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            operation.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut written,
        )
    };
    (code, output[..written].to_vec())
}

fn decide(facts: Value) -> Value {
    let request = serde_json::to_vec(&facts).unwrap();
    let (code, output) = call(&request, c"window_update_idle_install");
    assert_eq!(code, OK);
    serde_json::from_slice(&output).unwrap()
}

#[test]
fn automatic_update_idle_operation_requires_complete_idle_facts() {
    let mut facts = json!({"enabled": true, "idleMinutes": 15,
        "inputIdleSeconds": 900, "unsentDrafts": 0});
    assert_eq!(
        decide(facts.clone()),
        json!({"install": true, "hold": null, "away": {"kind": "idle", "seconds": 900.0}})
    );
    for (field, value, reason) in [
        ("enabled", json!(false), "off"),
        ("unsentDrafts", json!(1), "unsentDraft"),
        ("unsentDrafts", Value::Null, "unknown"),
    ] {
        let mut held = facts.clone();
        held[field] = value;
        assert_eq!(decide(held), json!({"install": false, "hold": {"reason": reason}}));
    }
    // A running agent turn never holds it (an old app still sends the count; it is ignored).
    let mut working = facts.clone();
    working["runningTurns"] = json!(4);
    assert_eq!(decide(working)["install"], json!(true));
    facts["inputIdleSeconds"] = json!(899);
    assert_eq!(
        decide(facts),
        json!({"install": false,
        "hold": {"reason": "notIdle", "secondsLeft": 1.0}})
    );
}

#[test]
fn missing_idle_interval_keeps_the_fifteen_minute_default() {
    let facts = json!({"enabled": true, "inputIdleSeconds": 60,
        "unsentDrafts": 0});
    assert_eq!(
        decide(facts),
        json!({"install": false,
        "hold": {"reason": "notIdle", "secondsLeft": 840.0}})
    );
}

#[test]
fn invalid_requests_and_unknown_operations_never_authorize_installation() {
    for request in [b"{".as_slice(), br#"{"unsentDrafts":-1}"#, br#"{"unsentDrafts":0.5}"#] {
        assert_eq!(call(request, c"window_update_idle_install").0, ERR_INVALID);
    }
    assert_eq!(call(b"{}", c"window_update_not_an_operation").0, ERR_INVALID);
    assert_eq!(
        decide(json!({"enabled":true, "unsentDrafts":0})),
        json!({"install":false,"hold":{"reason":"unknown"}})
    );
}

/// host_presence parity: a locked screen is away at once; a declined install backs off.
#[test]
fn a_locked_screen_installs_and_a_declined_install_backs_off() {
    let locked = json!({"enabled": true, "idleMinutes": 15, "inputIdleSeconds": 5,
        "screenLocked": true, "unsentDrafts": 0});
    assert_eq!(
        decide(locked.clone()),
        json!({"install": true, "hold": null, "away": {"kind": "screenLocked"}})
    );
    let mut declined = locked;
    declined["declinedInstalls"] = json!(1);
    declined["secondsSinceDecline"] = json!(20);
    assert_eq!(
        decide(declined),
        json!({"install": false, "hold": {"reason": "backoff", "secondsLeft": 40.0}})
    );
}

#[test]
fn the_next_check_answers_seconds_from_now() {
    let next = |facts: Value| {
        let (code, output) =
            call(&serde_json::to_vec(&facts).unwrap(), c"window_update_next_check");
        assert_eq!(code, OK);
        serde_json::from_slice::<Value>(&output).unwrap()
    };
    assert_eq!(
        next(json!({"secondsSinceLastCheck": 600, "intervalSeconds": 3600})),
        json!({"inSeconds": 3000.0})
    );
    assert_eq!(
        next(json!({"secondsSinceLastCheck": null, "intervalSeconds": 3600})),
        json!({"inSeconds": 0.0})
    );
    assert_eq!(
        next(json!({"secondsSinceLastCheck": 10, "intervalSeconds": 0})),
        json!({"inSeconds": null})
    );
    assert_eq!(call(b"{}", c"window_update_next_check").0, ERR_INVALID);
}
