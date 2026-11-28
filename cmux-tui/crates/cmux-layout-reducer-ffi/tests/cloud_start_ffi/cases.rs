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
    let wait = |elapsed: u64, loaded: bool| {
        call(
            c"cloud_start_list_wait",
            &json!({"elapsedMs": elapsed, "loaded": loaded, "signedIn": true}),
        )
        .1
    };
    assert_eq!(wait(0, false), json!({"next": "pause", "pauseMs": 2000, "readAfter": true}));
    assert_eq!(wait(60_000, false), json!({"next": "unread"}));
    assert_eq!(wait(0, true), json!({"next": "proceed"}));
    assert_eq!(
        call(
            c"cloud_start_pane_recovery",
            &json!({"code": "cloud.list_unread", "retryable": false, "reruns": 0, "elapsedMs": 0}),
        )
        .1,
        json!({"next": "rerun", "pauseMs": 5000, "class": "ListUnread"})
    );
    assert_eq!(
        call(
            c"cloud_start_pane_recovery",
            &json!({"code": "cloud.signed_out", "retryable": true, "reruns": 0, "elapsedMs": 0}),
        )
        .1,
        json!({"next": "surface"})
    );
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

/// The start's machine-route check through the C ABI: the command it runs on the machine, and the
/// verdict on what the machine printed (none before it ran).
#[test]
fn the_machine_route_op_names_its_command_and_judges_the_report() {
    let (code, asked) = call(c"cloud_machine_route", &json!({}));
    assert_eq!(code, OK);
    assert!(asked["command"].as_str().is_some_and(|c| c.contains("acp --json machine-auth")));
    assert_eq!(asked["verdict"], Value::Null);
    let judged = |stdout: &str| {
        call(c"cloud_machine_route", &json!({"stdout": stdout})).1["verdict"].clone()
    };
    assert_eq!(judged(""), json!("unsupported"));
    let ok =
        json!({"ok": true, "holds_credential": false, "daemon": {"running": true}, "agents": {}});
    assert_eq!(judged(&ok.to_string()), json!("ready"));
    let login = json!({"ok": false, "holds_credential": true, "agents": {}});
    assert_eq!(judged(&login.to_string()), json!("holds_credential"));
}

/// The spare's warm-home command carries the person's recent shapes from this Mac's acpmux home,
/// and only the default warm when there is no home or file.
#[test]
fn the_warm_home_op_sends_the_persons_recent_shapes() {
    let home = std::env::temp_dir().join(format!("ffi-warm-home-{}", std::process::id()));
    std::fs::create_dir_all(&home).unwrap();
    let file = json!({"spares": [{"harness": "codex", "cwd": "/w", "model": "gpt-5.5", "usedAtMs": 1000}]});
    std::fs::write(home.join("pool-spares.json"), file.to_string()).unwrap();
    let (code, got) =
        call(c"cloud_warm_home", &json!({"acpmuxHome": home.to_str().unwrap(), "nowMs": 2000.0}));
    assert_eq!(code, OK);
    let command = got["command"].as_str().unwrap();
    assert!(command.contains("acp --json warm-home --wait --shape 'codex:gpt-5.5'"), "{command}");
    assert_eq!(got["shapes"], json!([{"harness": "codex", "model": "gpt-5.5"}]));
    let bare = call(c"cloud_warm_home", &json!({})).1;
    assert!(bare["command"].as_str().unwrap().contains("warm-home --wait 2>/dev/null"));
    std::fs::remove_dir_all(&home).unwrap();
}

/// The pre-approval token's two ops round-trip the state the app keeps, numbers as Swift's `JSONValue` sends them.
#[test]
fn the_capability_ops_answer() {
    // The process holds the token: the app sends no state, and a drop forgets it.
    call(c"cloud_capability_drop", &json!({}));
    let first = call(c"cloud_capability_header", &json!({"team": "team-a", "nowMs": 1.0e12})).1;
    assert_eq!(first, json!({"header": null, "fetch": true}));
    let body = json!({"ok": true, "value": {"capability": "cc1.a.b", "team": "team-a", "issued_at": 5.0, "expires_at": 300_005.0, "refresh_at": 240_005.0}});
    let kept = call(
        c"cloud_capability_answer",
        &json!({"team": "team-a", "sentMs": 1.0e12, "nowMs": 1.0e12 + 200.0, "status": 200.0, "body": body}),
    )
    .1;
    assert_eq!(kept["outcome"], "held");
    let next =
        call(c"cloud_capability_header", &json!({"team": "team-a", "nowMs": 1.0e12 + 1000.0})).1;
    assert_eq!(next, json!({"header": "cc1.a.b", "fetch": false}));
    call(c"cloud_capability_drop", &json!({}));
    let after =
        call(c"cloud_capability_header", &json!({"team": "team-a", "nowMs": 1.0e12 + 2000.0})).1;
    assert_eq!(after, json!({"header": null, "fetch": true}));
    call(c"cloud_capability_drop", &json!({}));
}

#[test]
fn a_cloud_start_in_place_keeps_its_page() {
    let shown = |kill: Option<&str>| {
        call(
            c"cloud_one_pane",
            &json!({"inPlace": true, "pageLive": true, "cloudPageFree": true, "killSwitch": kill}),
        )
        .1
    };
    assert_eq!(shown(None), json!({"shown": "rehome"}));
    assert_eq!(shown(Some("0")), json!({"shown": "swap"}));
}
