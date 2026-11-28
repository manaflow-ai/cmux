//! `onboarding_first_run_*` through the C ABI: the app sends the scan's
//! sessions, its defaults and the daemon's replies and acts on the answer
//! (cmux-window-rules holds the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 12];
    let mut len = 0usize;
    // SAFETY: request and output stay live for the call, each pointer has its
    // stated length, the operation is NUL-terminated and len is exclusive.
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

fn ok(operation: &CStr, request: Value) -> Value {
    let (code, body) = call(operation, &request);
    assert_eq!(code, OK, "{operation:?} {request}");
    body
}

#[test]
fn sessions_group_by_folder_and_repositories_come_undated() {
    let body = ok(
        c"onboarding_first_run_projects",
        json!({
            "sessions": [
                {"path": "/Users/a/app", "modified": 10.0, "app": "codex"},
                {"path": "/Users/a/app", "modified": 20.0, "app": "claudeCode"},
            ],
            "repositories": ["/Users/a/app", "/Users/a/lib"],
        }),
    );
    assert_eq!(
        body["projects"],
        json!([
            {"path": "/Users/a/app", "sessions": 2, "lastActive": 20.0, "apps": ["claudeCode", "codex"]},
            {"path": "/Users/a/lib", "sessions": 0, "lastActive": null, "apps": []},
        ])
    );
}

#[test]
fn folders_drop_root_home_temporary_and_agent_homes() {
    let body = ok(
        c"onboarding_first_run_folders",
        json!({
            "home": "/Users/a",
            "agentHomes": ["/Users/a/.codex"],
            "paths": ["/", "/Users/a", "relative", "/tmp/x", "/Users/a/.codex/s", "/Users/a/app"],
        }),
    );
    assert_eq!(body["probe"], json!([false, false, false, false, false, true]));
}

#[test]
fn rank_puts_sessions_first_then_score() {
    let day = 86_400.0;
    let body = ok(
        c"onboarding_first_run_rank",
        json!({
            "now": 100.0 * day,
            "projects": [
                {"path": "/b", "sessions": 0, "lastActive": 100.0 * day},
                {"path": "/a", "sessions": 1, "lastActive": 50.0 * day},
                {"path": "/c", "sessions": 3, "lastActive": 100.0 * day},
            ],
        }),
    );
    let paths: Vec<&str> =
        body["projects"].as_array().unwrap().iter().map(|p| p["path"].as_str().unwrap()).collect();
    assert_eq!(paths, ["/c", "/a", "/b"]);
}

#[test]
fn recent_merges_hints_and_caps() {
    let body = ok(
        c"onboarding_first_run_recent",
        json!({
            "now": 1000.0,
            "limit": 2,
            "projects": [{"path": "/a", "sessions": 1, "lastActive": 900.0}],
            "hints": ["/h"],
            "repositories": [{"path": "/r", "modified": 1.0}],
        }),
    );
    assert_eq!(body["projects"].as_array().unwrap().len(), 2);
}

#[test]
fn complete_matches_the_typed_prefix() {
    let body = ok(
        c"onboarding_first_run_complete",
        json!({"paths": ["/Users/a/App", "/Users/a/lib"], "raw": "~/ap", "expanded": "/Users/a/ap", "limit": 5}),
    );
    assert_eq!(body["paths"], json!(["/Users/a/App"]));
}

#[test]
fn a_first_run_starts_the_card_and_a_later_launch_leaves_it_owning() {
    let first = ok(c"onboarding_first_run_card", json!({"isFirstRun": true}));
    assert_eq!(first, json!({"shows": false, "begins": true, "route": "startCard"}));
    let later = ok(c"onboarding_first_run_card", json!({"state": "pending"}));
    assert_eq!(later, json!({"shows": true, "begins": false, "route": "cardOwns"}));
    let never = ok(c"onboarding_first_run_card", json!({}));
    assert_eq!(never["route"], json!("windows"));
}

#[test]
fn a_reopened_card_survives_completion_but_not_hide() {
    let reopened = json!({"state": "reopened", "completion": true});
    assert_eq!(ok(c"onboarding_first_run_card_end", reopened)["ends"], json!(false));
    let hide = json!({"state": "reopened", "completion": false});
    assert_eq!(ok(c"onboarding_first_run_card_end", hide)["ends"], json!(true));
    let ended = json!({"state": "ended"});
    assert_eq!(ok(c"onboarding_first_run_card_end", ended)["ends"], json!(false));
}

#[test]
fn chief_asks_for_the_card_when_claude_is_signed_out() {
    let body = ok(c"onboarding_first_run_chief", json!({"loaded": true, "auth": "signedOut"}));
    assert_eq!(body, json!({"needsChiefAgent": true, "cardForm": "chief"}));
    let full = ok(
        c"onboarding_first_run_chief",
        json!({"shows": true, "loaded": true, "auth": "signedIn"}),
    );
    assert_eq!(full, json!({"needsChiefAgent": false, "cardForm": "full"}));
    let none = ok(c"onboarding_first_run_chief", json!({"loaded": true, "auth": "signedIn"}));
    assert_eq!(none["cardForm"], Value::Null);
}

#[test]
fn opacity_steps_to_hundredths_and_refuses_out_of_range() {
    let body = ok(c"onboarding_first_run_opacity", json!({"value": 0.456}));
    assert_eq!(body, json!({"stepped": 0.46, "clamped": 0.456}));
    let high = ok(c"onboarding_first_run_opacity", json!({"value": 1.5}));
    assert_eq!(high, json!({"stepped": null, "clamped": 1.0}));
}

#[test]
fn the_classic_launch_rule_takes_the_seam_then_the_environment() {
    let seam = json!({"seam": false, "environment": "1", "bundleID": "com.cmuxterm.app.next"});
    assert_eq!(ok(c"onboarding_first_run_classic_launch", seam)["runs"], json!(false));
    let env = json!({"environment": "1", "bundleID": "dev.example"});
    assert_eq!(ok(c"onboarding_first_run_classic_launch", env)["runs"], json!(true));
    let dev = json!({"bundleID": "dev.example"});
    assert_eq!(ok(c"onboarding_first_run_classic_launch", dev)["runs"], json!(false));
}

#[test]
fn the_classic_probe_answer_and_reply_name_their_step() {
    let probe = ok(
        c"onboarding_first_run_classic_probe",
        json!({"mode": "automatic", "ledgerNone": true, "firstWorkspace": false,
            "available": true, "skips": null, "error": false}),
    );
    assert_eq!(
        probe,
        json!({"firstContact": true, "action": {"kind": "baseline", "notice": true}})
    );
    let answer = ok(
        c"onboarding_first_run_classic_answer",
        json!({"mode": "automatic", "firstContact": true, "answer": "unanswered"}),
    );
    assert_eq!(answer, json!({"kind": "stop", "recordSeen": true}));
    let reply = ok(
        c"onboarding_first_run_classic_reply",
        json!({"reason": "classic_running", "firstContact": true, "sourceBundle": false}),
    );
    assert_eq!(reply, json!({"kind": "classicOpen", "recordSeen": true, "notice": false}));
}

#[test]
fn a_malformed_request_or_unknown_op_is_refused() {
    let (code, _) = call(c"onboarding_first_run_classic_probe", &json!({"mode": "sometimes"}));
    assert_eq!(code, ERR_INVALID);
    let (code, _) = call(c"onboarding_first_run_nope", &json!({}));
    assert_eq!(code, ERR_INVALID);
}
