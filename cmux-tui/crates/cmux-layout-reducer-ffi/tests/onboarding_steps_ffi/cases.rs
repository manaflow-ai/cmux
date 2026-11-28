//! `onboarding_steps_*` through the C ABI: the app sends Foundation's and
//! the helper's facts and acts on the answer (cmux-window-rules holds the
//! rules and their cases).

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
fn an_allow_opens_its_pane_and_the_drag_panel() {
    let state = json!({"source": true, "helper": true, "received": true,
        "grants": {"accessibility": false, "screenRecording": false}});
    let outcome = ok(
        c"onboarding_steps_computer_use",
        json!({"state": state, "event": {"kind": "allow", "pane": "accessibility"}}),
    );
    assert_eq!(outcome["openSettings"], json!("accessibility"));
    assert_eq!(outcome["enable"], json!(false));
    assert_eq!(outcome["state"]["helping"], json!("accessibility"));
    assert_eq!(outcome["state"]["allowedHere"], json!(["accessibility"]));
    assert_eq!(outcome["view"]["nextPane"], json!("accessibility"));
}

#[test]
fn every_grant_on_after_an_allow_here_schedules_the_done_view() {
    let state = json!({"source": true, "helper": true, "received": true,
        "allowedHere": ["screenRecording"], "helping": "screenRecording",
        "grants": {"accessibility": true}});
    let outcome = ok(
        c"onboarding_steps_computer_use",
        json!({"state": state, "event": {"kind": "grants",
            "grants": {"accessibility": true, "screenRecording": true}}}),
    );
    assert_eq!(outcome["timer"], json!("schedule"));
    assert_eq!(outcome["view"]["finished"], json!(true));
    assert_eq!(outcome["view"]["confirmsCapture"], json!(true));
    let stopped = ok(
        c"onboarding_steps_computer_use",
        json!({"state": outcome["state"], "event": {"kind": "stop"}}),
    );
    assert_eq!(stopped["timer"], json!("cancel"));
}

#[test]
fn the_agents_step_lists_installed_agents_and_offers_installs() {
    let view = ok(
        c"onboarding_steps_agents",
        json!({"agents": [
            {"id": "claude", "auth": "signedIn", "installed": true},
            {"id": "codex", "auth": "unknown", "installed": false},
            {"id": "other", "installed": false},
        ]}),
    );
    assert_eq!(view["listed"], json!([0]));
    assert_eq!(view["installable"], json!([1]));
    assert_eq!(view["marks"][0]["countsAsSignedIn"], json!(true));
    assert_eq!(view["marks"][1]["canInstall"], json!(true));
    let table = ok(c"onboarding_steps_agents_table", json!({}));
    assert_eq!(
        table["installPages"]["claude"],
        json!("https://docs.anthropic.com/en/docs/claude-code/setup")
    );
    assert_eq!(table["noAgentsService"], json!("cmux could not reach its agents service"));
}

#[test]
fn a_link_routes_by_foundations_parts() {
    let ssh = ok(
        c"onboarding_steps_external_open",
        json!({"link": {"absolute": "ssh://leo@[::1]:2222", "scheme": "ssh", "host": "::1",
            "user": "leo", "port": 2222}, "linkScheme": "cmux-dev"}),
    );
    assert_eq!(ssh, json!({"kind": "ssh", "target": {"user": "leo", "host": "::1", "port": 2222}}));
    let strings = ok(c"onboarding_steps_ssh_target", ssh["target"].clone());
    assert_eq!(strings["display"], json!("leo@[::1]:2222"));
    assert_eq!(strings["command"], json!("ssh -p 2222 -- 'leo@[::1]'"));
    assert_eq!(strings["trustKey"], json!("::1"));
    let crafted = ok(
        c"onboarding_steps_external_open",
        json!({"link": {"absolute": "ssh://-oProxyCommand=evil", "scheme": "ssh",
            "host": "-oProxyCommand=evil"}}),
    );
    assert_eq!(crafted, json!({"kind": "unsupported"}));
    let script = ok(
        c"onboarding_steps_external_open",
        json!({"link": {"absolute": "file:///Users/me/run.sh", "scheme": "file"},
            "file": {"path": "/Users/me/run.sh", "folder": "/Users/me", "ext": "sh"}}),
    );
    assert_eq!(
        script,
        json!({"kind": "terminal", "cwd": "/Users/me", "command": "sh '/Users/me/run.sh'"})
    );
    let tab = ok(
        c"onboarding_steps_external_open",
        json!({"link": {"scheme": "https", "host": "example.com", "path": "/docs"},
            "mode": "continuing"}),
    );
    assert_eq!(tab, json!({"kind": "browserTab"}));
}

#[test]
fn the_sign_in_callback_and_trust_key_answer() {
    assert_eq!(
        ok(c"onboarding_steps_sign_in_callback", json!({"host": "Auth-Callback"})),
        json!({"callback": true})
    );
    assert_eq!(
        ok(c"onboarding_steps_sign_in_callback", json!({"host": null, "path": "/tab"})),
        json!({"callback": false})
    );
    assert_eq!(ok(c"onboarding_steps_trust_key", json!("[FE80::1%en0]")), json!("fe80::1%en0"));
}

#[test]
fn an_unknown_op_or_a_bad_request_is_refused() {
    assert_eq!(call(c"onboarding_steps_nope", &json!({})).0, ERR_INVALID);
    assert_eq!(
        call(c"onboarding_steps_computer_use", &json!({"event": {"kind": "fly"}})).0,
        ERR_INVALID
    );
    assert_eq!(call(c"onboarding_steps_external_open", &json!([1])).0, ERR_INVALID);
}
