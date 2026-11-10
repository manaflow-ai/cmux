//! The Cloud start's decision ops through the C ABI: the app sends what its
//! `cloud.startChat` start knows and acts on the answer that comes back
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
fn the_start_checks_answer() {
    assert_eq!(
        call(c"cloud_start_refusal", &json!({"cloudDisabled": false, "signedIn": false})).1,
        json!({"refusal": "not_signed_in"})
    );
    assert_eq!(
        call(c"cloud_start_refusal", &json!({"cloudDisabled": false, "signedIn": true})).1,
        json!({"refusal": null})
    );
    // A send that switched team starts only in that team (cmux#39928 F3).
    let switched = |active: &str| {
        call(
            c"cloud_start_refusal",
            &json!({"cloudDisabled": false, "signedIn": true, "requestedTeam": "team-a", "activeTeam": active}),
        )
        .1
    };
    assert_eq!(switched("team-b"), json!({"refusal": "cloud_team_switching"}));
    assert_eq!(switched("team-a"), json!({"refusal": null}));
    assert_eq!(
        call(c"cloud_start_account_text", &json!({"account": ["user-leo", null]})).1,
        json!({"text": "user-leo/"})
    );
    let check = |asked: Value, now: Value, current: bool| {
        call(
            c"cloud_start_check_account",
            &json!({"asked": asked, "now": now, "listCurrent": current}),
        )
        .1
    };
    assert_eq!(check(json!(["u", "a"]), json!(["u", "a"]), true), json!({"check": null}));
    assert_eq!(
        check(json!(["u", "a"]), json!(["u", "b"]), true),
        json!({"check": "account-changed"})
    );
    assert_eq!(check(json!(["u", "a"]), json!(["u", "a"]), false), json!({"check": "list-unread"}));
    assert_eq!(
        call(c"cloud_folder_too_broad", &json!({"root": "/Users/me", "home": "/Users/me"})).1,
        json!({"tooBroad": true})
    );
    assert_eq!(
        call(
            c"cloud_start_uploads",
            &json!({"cwdGiven": true, "uploadRoot": "/w/paint", "root": "/w/paint", "subpath": ""})
        )
        .1,
        json!({"uploads": "yes"})
    );
    assert_eq!(
        call(
            c"cloud_start_uploads",
            &json!({"cwdGiven": false, "root": "/Users", "subpath": "", "paths": ["/Users"], "homes": ["/Users/me"]})
        )
        .1,
        json!({"uploads": "no"})
    );
}

#[test]
fn the_vm_kind_op_answers() {
    assert_eq!(
        call(c"cloud_vm_kind", &json!({"vmKind": "owner"})).1,
        json!({"ownsVm": true, "teammate": false, "linkArguments": ["--vm-kind", "owner"]})
    );
    assert_eq!(
        call(c"cloud_vm_kind", &json!({})).1,
        json!({"ownsVm": false, "teammate": false, "linkArguments": []})
    );
    assert_eq!(call(c"cloud_vm_kind", &json!({"vmKind": "team"})).1["teammate"], true);
    assert_eq!(call(c"cloud_start_check_account", &json!({"asked": []})).0, ERR_INVALID);
}

/// A Cloud machine's agents reach models through its coderouter edge; the Mac never copies a provider
/// login there. So the ops that decided and fingerprinted that copy are gone: an app that still asks
/// gets the unknown-op answer, never an install step.
#[test]
fn the_login_copy_ops_are_gone() {
    let start = json!({"dogfood": true, "harness": "claude", "signedIn": true, "callerOwns": true,
        "guestStdout": "vm-kind:owner\n", "machineProbe": {"exitCode": 0, "stdout": "none\n"}, "cached": true});
    for (op, request) in [
        (c"cloud_harness_login", start),
        (c"cloud_harness_login_provider", json!({"harness": "claude"})),
        (c"cloud_login_fingerprint", json!({"token": [97, 98, 99]})),
        (c"cloud_guest_kind", json!({"stdout": "vm-kind:owner\n"})),
        (c"cloud_guest_kind_probe", json!({})),
        (c"cloud_recovery_refreshes", json!({"probe": {"exitCode": 0, "stdout": "cached\n"}})),
    ] {
        assert_eq!(call(op, &request).0, ERR_INVALID, "{op:?} still answers");
    }
}
