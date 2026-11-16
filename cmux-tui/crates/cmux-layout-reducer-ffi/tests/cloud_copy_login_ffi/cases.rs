//! `cloud_copy_login_*` through the C ABI: the app sends the copy's state, one event, its clock and
//! its scope, and runs the effects the answer lists (cmux-cloud-start-core `copy_login` holds the
//! rules and the per-case tests).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 16];
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

fn step(state: &Value, event: Value, now: u64) -> Value {
    let scope = json!({"teamId": "team-1", "userId": "user-1"});
    let (code, reply) = call(
        c"cloud_copy_login_step",
        &json!({"state": state, "event": event, "now": now, "scope": scope}),
    );
    assert_eq!(code, OK);
    reply
}

fn token() -> Vec<u8> {
    b"sk-ant-oat01-abcdefghijklmnopqrstuvwxyz0123456789".to_vec()
}

#[test]
fn a_cached_claude_login_goes_from_begin_to_installed() {
    let copy = json!({
        "provider": "claude", "machineId": "vm-1", "teamId": "team-1", "userId": "user-1",
        "confirmed": true, "stagingId": "7C0F6B2E-1F4B-4E8E-9A54-2A8C3D1E5F60",
    });
    let begun = step(&Value::Null, json!({"on": "begin", "copy": copy}), 100);
    assert_eq!(begun["effects"], json!([{"do": "callerOwns"}]));
    let owned = step(&begun["state"], json!({"on": "owns", "owns": true}), 200);
    assert_eq!(owned["effects"][0]["do"], "exec");
    assert_eq!(owned["effects"][0]["timeoutMs"], 20_000);
    assert_eq!(owned["effects"][0]["cutoffMs"], 90_000);
    let guest = step(&owned["state"], json!({"on": "exec", "exit": 0}), 300);
    assert_eq!(
        guest["effects"],
        json!([{"do": "mark", "name": "transfer.guest"}, {"do": "load", "provider": "claude", "timeoutMs": 30_000}])
    );
    let loaded = step(&guest["state"], json!({"on": "loaded", "credential": token()}), 400);
    assert_eq!(loaded["effects"][1], json!({"do": "callerOwns"}));
    let owns = step(&loaded["state"], json!({"on": "owns", "owns": true}), 500);
    assert_eq!(owns["effects"], json!([{"do": "stillAllowed"}]));
    let allowed = step(&owns["state"], json!({"on": "allowed", "allowed": true}), 600);
    assert_eq!(
        allowed["effects"][1],
        json!({"do": "write", "path": "/home/cmux/.cmux/credential-transfer/7C0F6B2E-1F4B-4E8E-9A54-2A8C3D1E5F60.json", "mode": 420})
    );
    assert!(!allowed["state"].to_string().contains("sk-ant"));
    let written = step(&allowed["state"], json!({"on": "written"}), 700);
    assert!(written["effects"][1]["command"].as_str().unwrap().contains("CMUX_CREDENTIAL_INSTALL"));
    let installed = step(&written["state"], json!({"on": "exec", "exit": 0}), 800);
    assert_eq!(
        installed["effects"],
        json!([{"do": "mark", "name": "transfer.install"}, {"do": "finish", "end": "installed", "outcome": "installed"}])
    );
}

#[test]
fn an_unconfirmed_copy_fails_with_the_apps_words() {
    let copy = json!({"provider": "codex", "machineId": "vm-1", "userId": "user-1", "confirmed": false, "stagingId": "x"});
    let begun = step(&Value::Null, json!({"on": "begin", "copy": copy}), 1);
    assert_eq!(
        begun["effects"],
        json!([{"do": "finish", "end": "failed", "failure": "consent_required",
                "outcome": "failed: Confirm this machine and provider before transferring credentials."}])
    );
}

#[test]
fn the_rules_answer_over_the_channel() {
    let (code, valid) =
        call(c"cloud_copy_login_validate", &json!({"provider": "claude", "data": token()}));
    assert_eq!((code, valid), (OK, json!({"valid": true})));
    let (_, found) = call(
        c"cloud_copy_login_claude_token",
        &json!({"data": b"x sk-ant-oat01-abcdefghijklmnopqrstu y".to_vec()}),
    );
    assert_eq!(found["token"], json!(b"sk-ant-oat01-abcdefghijklmnopqrstu".to_vec()));
    let (_, env) = call(
        c"cloud_copy_login_envelope",
        &json!({"data": b"{\"created\":1,\"credential\":\"aGk=\"}\n".to_vec()}),
    );
    assert_eq!(env["credential"], json!([104, 105]));
    let (_, name) =
        call(c"cloud_copy_login_keychain_name", &json!({"provider": "claude", "userId": "u"}));
    assert!(name["name"].as_str().unwrap().starts_with("CLAUDE_TRANSFER_"));
    let (_, scopes) = call(
        c"cloud_copy_login_scopes",
        &json!({"provider": "claude", "teamId": "a", "otherTeams": ["b", "a", null]}),
    );
    assert_eq!(scopes["scopes"], json!(["a", "b", null]));
    let (_, pick) = call(
        c"cloud_copy_login_pick",
        &json!({"reads": [{"read": "failed", "failure": "store_failed"}, {"read": "found", "index": 1}]}),
    );
    assert_eq!(pick, json!({"pick": {"read": "found", "index": 1}, "cached": "cached"}));
    let (_, gate) = call(c"cloud_copy_login_gate", &json!({"remoteSwitch": true, "claude": true}));
    assert_eq!(gate, json!({"stillAllowed": false, "copy": "ask", "recovery": "ask"}));
    let (_, check) =
        call(c"cloud_copy_login_restart_guest_check", &json!({"creatorTeamGuest": true}));
    assert!(check["check"].as_str().unwrap().contains("owner|team"));
    assert_eq!(call(c"cloud_copy_login_validate", &json!({"data": []})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_copy_login_nope", &json!({})).0, ERR_INVALID);
}
