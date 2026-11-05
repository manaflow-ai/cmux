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

/// The one call reads the harness and both probes' output itself (cmux#32416), and hands back the
/// guest probe to run, so no other op's failure can stand in for its answer.
#[test]
fn the_one_call_reads_the_harness_and_the_probes() {
    let (code, body) = call(
        c"cloud_harness_login",
        &json!({"dogfood": true, "harness": "", "signedIn": true, "callerOwns": true,
                "guestStdout": "motd\nvm-kind:team\n",
                "machineProbe": {"exitCode": 0, "stdout": "rejected\n"}, "cached": true}),
    );
    assert_eq!(code, OK);
    assert_eq!(body["step"], "install");
    assert_eq!(body["gate"], true);
    assert_eq!(body["provider"], "claude");
    assert_eq!(body["guestKind"], "team");
    assert_eq!(body["machineLogin"], "rejected");
    assert!(body["guestKindProbe"].as_str().unwrap().contains("/etc/cmux/vm-kind"));
    let (_, pi) = call(
        c"cloud_harness_login",
        &json!({"dogfood": true, "setting": false, "harness": "pi", "signedIn": true}),
    );
    assert_eq!(pi["reason"], "build-gate-off");
    assert_eq!(pi["gate"], false);
    assert_eq!(pi["provider"], Value::Null);
}

/// A Release start: the remote switch and the person's consent ride the same one call.
#[test]
fn a_release_start_reads_the_switch_and_the_consent() {
    let start = json!({"dogfood": false, "remoteSwitch": true, "harness": "", "signedIn": true,
                       "callerOwns": true, "guestStdout": "vm-kind:owner\n",
                       "machineProbe": {"exitCode": 0, "stdout": "none\n"}, "cached": true});
    let (code, body) = call(c"cloud_harness_login", &start);
    assert_eq!(code, OK);
    assert_eq!(
        (body["step"].as_str(), body["reason"].as_str()),
        (Some("ask-consent"), Some("consent-first"))
    );
    let mut given = start.clone();
    given["consent"] = json!(true);
    assert_eq!(call(c"cloud_harness_login", &given).1["step"], "install");
    let mut off = given.clone();
    off["remoteSwitch"] = json!(false);
    let (_, body) = call(c"cloud_harness_login", &off);
    assert_eq!(
        (body["step"].as_str(), body["reason"].as_str()),
        (Some("skip"), Some("remote-switch-off"))
    );
    // Sent pre-resolved (no `dogfood`), the switch still holds it.
    let (_, body) = call(
        c"cloud_harness_login",
        &json!({"release": true, "gate": true, "provider": "claude", "signedIn": true, "callerOwns": true,
                "guestKind": "owner", "machineLogin": "none", "cached": true, "consent": true}),
    );
    assert_eq!(body["reason"], "remote-switch-off");
    let mut team = given;
    team["guestStdout"] = json!("vm-kind:team\n");
    assert_eq!(call(c"cloud_harness_login", &team).1["reason"], "guest-not-owner");
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
fn the_vm_kind_and_fingerprint_ops_answer() {
    assert_eq!(
        call(c"cloud_vm_kind", &json!({"vmKind": "owner"})).1,
        json!({"ownsVm": true, "teammate": false, "linkArguments": ["--vm-kind", "owner"]})
    );
    assert_eq!(
        call(c"cloud_vm_kind", &json!({})).1,
        json!({"ownsVm": false, "teammate": false, "linkArguments": []})
    );
    assert_eq!(call(c"cloud_vm_kind", &json!({"vmKind": "team"})).1["teammate"], true);
    assert_eq!(
        call(c"cloud_login_fingerprint", &json!({"token": [97, 98, 99]})).1,
        json!({"fingerprint": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"})
    );
    assert_eq!(call(c"cloud_start_check_account", &json!({"asked": []})).0, ERR_INVALID);
}
