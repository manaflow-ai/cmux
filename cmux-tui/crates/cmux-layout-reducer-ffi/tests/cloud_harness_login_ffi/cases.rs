//! `cloud_harness_login*` through the C ABI: the app sends what its
//! `cloud.startChat` start knows and acts on the decision that comes back
//! (cmux-cloud-start-core holds the rules and their cases).

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
fn a_first_login_on_the_callers_own_machine_asks_once() {
    let (code, body) = call(
        c"cloud_harness_login",
        &json!({"gate": true, "provider": "claude", "signedIn": true, "callerOwns": true,
                "guestKind": "owner", "machineLogin": "none", "cached": false}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["step"], "confirm-then-install");
    assert_eq!(body["reason"], "confirm-first");
    assert_eq!(body["readsMachine"], true);
    assert_eq!(body["guestTakesLogin"], true);
    assert_eq!(body["skippedTeamMachine"], false);
    assert_eq!(
        body["summary"],
        "confirm-then-install (confirm-first): gate on, provider claude, signed in yes, caller owns yes, guest owner, machine login none, cached no"
    );
}

#[test]
fn a_start_that_asked_nothing_yet_skips_with_its_reason_and_outcome() {
    let (code, body) = call(
        c"cloud_harness_login",
        &json!({"gate": false, "provider": "claude", "signedIn": true, "outcome": "declined"}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["step"], "skip");
    assert_eq!(body["reason"], "build-gate-off");
    assert_eq!(body["readsMachine"], false);
    assert!(body["summary"].as_str().unwrap().ends_with("cached no -> declined"));
}

#[test]
fn the_provider_and_guest_kind_ops_answer() {
    assert_eq!(call(c"cloud_harness_login_provider", &json!({})).1, json!({"provider": "claude"}));
    assert_eq!(
        call(c"cloud_harness_login_provider", &json!({"harness": "codex"})).1,
        json!({"provider": "codex"})
    );
    assert_eq!(
        call(c"cloud_harness_login_provider", &json!({"harness": "opencode"})).1,
        json!({"provider": null})
    );
    assert_eq!(
        call(c"cloud_guest_kind", &json!({"stdout": "motd\nvm-kind:team\n"})).1,
        json!({"kind": "team"})
    );
    assert_eq!(call(c"cloud_guest_kind", &json!({"stdout": ""})).1, json!({"kind": null}));
    let probe = call(c"cloud_guest_kind_probe", &json!({})).1;
    assert!(probe["probe"].as_str().unwrap().contains("/etc/cmux/vm-kind"));
}

#[test]
fn a_malformed_request_is_invalid() {
    assert_eq!(call(c"cloud_harness_login", &json!({"provider": "gemini"})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_guest_kind", &json!({})).0, ERR_INVALID);
}
