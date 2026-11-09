//! `cloud_task_*` through the C ABI: the app sends the follower's state, one event and the time,
//! and runs the effects the answer lists (cmux-cloud-tasks holds the rules and their cases).

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

const NOW: f64 = 815_000_000.0;

fn record() -> Value {
    json!({"id": "r1", "task": "Fix it", "key": "key-r1", "user": "u1", "team": "t1", "started": NOW})
}

fn step(state: &Value, event: Value) -> Value {
    let (code, reply) = call(c"cloud_task_step", &json!({"source": "runs", "now": NOW, "state": state, "event": event}));
    assert_eq!(code, OK);
    reply
}

#[test]
fn a_run_followed_to_its_end_saves_answers_and_tells_once() {
    let (code, loaded) = call(c"cloud_task_load", &json!({"saved": null}));
    assert_eq!(code, OK);
    let followed = step(&loaded["state"], json!({"on": "follow", "record": record()}));
    assert_eq!(followed["effects"], json!([{"do": "save"}, {"do": "start", "id": "r1"}]));
    let poll = step(&followed["state"], json!({"on": "poll", "id": "r1", "heard": NOW}));
    assert_eq!(poll["wait"], json!({"team": "t1"}));
    let body = r#"{"run":{"status":"succeeded"},"receipt":{"status":"succeeded"}}"#;
    let ended = step(&poll["state"], json!({"on": "answer", "id": "r1", "body": body}));
    assert_eq!(ended["next"], "stop");
    assert_eq!(ended["heard"], true);
    let kinds: Vec<&str> = ended["effects"].as_array().unwrap().iter().map(|effect| effect["do"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["save", "clearPoll", "answer", "tell"]);
    assert_eq!(ended["effects"][3]["outcome"], "succeeded");
    assert_eq!(ended["effects"][3]["markTold"], true);
    assert_eq!(ended["state"]["ended"][0]["told"], false);
    let told = step(&ended["state"], json!({"on": "markTold", "id": "r1"}));
    let (code, saved) = call(c"cloud_task_saved", &json!({"state": told["state"]}));
    assert_eq!(code, OK);
    let saved: Value = serde_json::from_str(saved["saved"].as_str().unwrap()).unwrap();
    assert_eq!(saved["following"], json!([]));
    assert_eq!(saved["ended"][0]["told"], true);
    assert_eq!(saved["ended"][0]["at"], json!(NOW));
}

#[test]
fn another_accounts_follow_is_refused_and_a_404_drops_the_run() {
    let signed_in = step(&json!({}), json!({"on": "account", "user": "u2"}));
    let refused = step(&signed_in["state"], json!({"on": "follow", "record": record()}));
    assert_eq!(refused["refused"], json!({"kind": "timedOut", "path": "/api/runs/r1"}));
    let followed = step(&json!({}), json!({"on": "follow", "record": record()}));
    let gone = step(&followed["state"], json!({"on": "answer", "id": "r1", "status": 404, "failed": true}));
    assert_eq!(gone["effects"][1], json!({"do": "endPoll", "id": "r1", "error": {"kind": "timedOut", "path": "/api/runs/r1"}}));
    assert_eq!(gone["state"]["records"], json!([]));
}

#[test]
fn a_hand_offs_status_and_times() {
    let (_, done) = call(c"cloud_task_handoff", &json!({"status": "done", "turn": 2, "state": "open"}));
    assert_eq!(done, json!({"open": true, "running": false, "notice": {"key": "2:done", "outcome": "succeeded"}}));
    let (_, statuses) = call(c"cloud_task_handoff_statuses", &json!({}));
    assert_eq!(statuses["turnRuns"], json!(["starting", "running"]));
    let (_, millis) = call(c"cloud_task_millis", &json!({"time": "2026-10-20T10:00:00.000Z"}));
    assert_eq!(millis["millis"], json!(1_792_490_400_000.0));
    // A number of milliseconds is taken as sent.
    let (_, number) = call(c"cloud_task_millis", &json!({"time": 1_792_490_400_000u64}));
    assert_eq!(number["millis"], json!(1_792_490_400_000.0));
    for none in [json!("yesterday"), json!(null), json!(true)] {
        assert_eq!(call(c"cloud_task_millis", &json!({"time": none})).1["millis"], Value::Null);
    }
}

#[test]
fn a_request_that_does_not_read_is_invalid() {
    assert_eq!(call(c"cloud_task_step", &json!({"now": NOW, "event": {"on": "weird"}})).0, ERR_INVALID);
    assert_eq!(call(c"cloud_task_nope", &json!({})).0, ERR_INVALID);
}
