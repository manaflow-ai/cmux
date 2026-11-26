//! `cloud_move_host_*` and `cloud_handler_resize_call` through the C ABI: the shapes the app's
//! Swift decodes (cmux-cloud-start-core `moves/host.rs` and cmux-cloud-handlers `calls.rs` hold
//! the rules and their cases).

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CStr;

fn call(operation: &CStr, request: &Value) -> (i32, Value) {
    let request = serde_json::to_vec(request).unwrap();
    let mut output = vec![0u8; 1 << 14];
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

fn ok(operation: &CStr, request: Value) -> Value {
    let (code, body) = call(operation, &request);
    assert_eq!(code, OK, "{operation:?}");
    body
}

fn moved() -> String {
    json!({
        "registry:a\ns1": { "machineID": "m1", "host": "registry:a", "session": "s1", "localRoot": "/r",
                             "localChat": "c", "remoteFolder": "/f", "remoteChat": "rc" },
        "registry:a\ns2": { "machineID": "m1", "host": "registry:a", "session": "s2", "localRoot": "/r",
                             "localChat": "c", "remoteFolder": "/f", "remoteChat": "rc",
                             "broughtBack": { "session": "home", "key": "k" } },
    })
    .to_string()
}

#[test]
fn eligible() {
    let on = ok(
        c"cloud_move_host_eligible",
        json!({ "moved": moved(), "host": "registry:a", "session": "s1" }),
    );
    assert_eq!(on, json!({ "eligible": true }));
    let chief = ok(
        c"cloud_move_host_eligible",
        json!({ "host": "chief:x", "session": "s", "local": true }),
    );
    assert_eq!(chief, json!({ "eligible": false }));
}

#[test]
fn chats() {
    let answer = ok(
        c"cloud_move_host_chats",
        json!({ "moved": moved(), "tabs": [
            { "id": "1", "host": "registry:a", "session": "s1", "title": "A", "turnRunning": true,
              "turnStartedAtMs": 5.0, "queued": 2 },
            { "id": "2", "host": "registry:a", "session": "s1", "title": "dup" },
            { "id": "3", "host": "local", "title": "no session", "local": true },
        ]}),
    );
    assert_eq!(
        answer,
        json!({ "chats": [{ "id": "1", "session": "s1", "title": "A", "onCloud": true, "turnRunning": true,
                            "turnStartedAtMs": 5.0, "moving": false, "queued": 2 }] })
    );
}

#[test]
fn sessions() {
    assert_eq!(
        ok(c"cloud_move_host_sessions", json!({ "moved": moved() })),
        json!({ "sessions": ["s1"] })
    );
    assert_eq!(ok(c"cloud_move_host_sessions", json!({})), json!({ "sessions": [] }));
}

#[test]
fn own_facts() {
    let answer = ok(
        c"cloud_move_host_own_facts",
        json!({ "moved": moved(), "session": "home", "lastMachine": "old",
                "machines": [{ "id": "m1", "status": "running" }, { "id": "m9", "status": "destroyed" }] }),
    );
    assert_eq!(
        answer,
        json!({ "before": "m1", "machines": [
            { "id": "m1", "sessions": ["s1"], "gone": false },
            { "id": "m9", "sessions": [], "gone": true },
        ]})
    );
    let none = ok(c"cloud_move_host_own_facts", json!({ "session": "x" }));
    assert_eq!(none, json!({ "machines": [] }));
}

#[test]
fn cargo() {
    let answer = ok(
        c"cloud_move_host_cargo",
        json!({ "turnRunning": true, "branch": "main", "queued": 0, "claims": { "queued": 3 } }),
    );
    assert_eq!(answer["turnRunning"], json!(true));
    assert_eq!(answer["continuesTurn"], json!(true));
    assert_eq!(answer["queued"], json!(3));
    assert_eq!(answer["hasDraft"], json!(false));
    assert_eq!(answer["branch"], json!("main"));
}

#[test]
fn run_refusal() {
    let refused =
        ok(c"cloud_move_host_run_refusal", json!({ "refusal": " No folder ", "failed": "f" }));
    assert_eq!(refused, json!({ "refusal": "No folder" }));
    let started = ok(c"cloud_move_host_run_refusal", json!({ "started": true }));
    assert_eq!(started, json!({ "refusal": null }));
}

#[test]
fn resize_call() {
    let disk = ok(c"cloud_handler_resize_call", json!({ "machine": "m", "args": { "disk": 100 } }));
    assert_eq!(
        disk,
        json!({ "value": { "args": { "machine": "m", "size": { "disk_mb": 102400 } }, "fields": { "disk_gib": 100 } } })
    );
    let refused = ok(c"cloud_handler_resize_call", json!({ "machine": "m", "args": {} }));
    assert_eq!(refused["refusal"]["key"], json!("resizeNeedsSizeOrDisk"));
}

#[test]
fn unknown_and_malformed() {
    assert_eq!(call(c"cloud_move_host_nope", &json!({})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_move_host_eligible", &json!({ "host": 1 })).0, ERR_INVALID);
    assert_eq!(call(c"cloud_handler_resize_call", &json!({})).0, ERR_INVALID);
}
