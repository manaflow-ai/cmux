//! Parity with the Swift it replaced (`CmuxRemoteService+Capture`, `+ComputerUse`, `.open`,
//! `RemoteDeviceChannel.result`).

use serde_json::{Value, json};

use crate::ui::call;

fn ok(op: &str, args: Value) -> Value {
    let reply = call(json!({"op": op, "args": args}).to_string().as_bytes());
    assert!(reply.get("err").is_none(), "{op}: {reply}");
    reply["ok"].clone()
}

fn err(op: &str, args: Value) -> String {
    let reply = call(json!({"op": op, "args": args}).to_string().as_bytes());
    reply["err"].as_str().unwrap_or_else(|| panic!("{op}: {reply}")).to_owned()
}

fn cleaned(overrides: Value) -> Value {
    let mut raw = json!({
        "ok": true, "code": "remote_cleaned", "worker_started": true, "lease_bound": true,
        "verified_absent": true, "worker_quiescent": true, "worker_pid_exited": true,
        "descendants_exited": true, "identity_removed": 2, "relays_removed": 1,
    });
    for (key, value) in overrides.as_object().unwrap() {
        raw[key] = value.clone();
    }
    raw
}

#[test]
fn capture_rejects_unknown_phases_and_reports_failures() {
    let answer = ok("service.capture", json!({"phase": "launch", "raw": cleaned(json!({}))}));
    assert_eq!(answer["code"], "invalid_request");
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["identity_removed"], 0);
    let answer =
        ok("service.capture", json!({"phase": "cleanup", "failure": "remote_unavailable"}));
    assert_eq!(answer["code"], "remote_unavailable");
    assert_eq!(answer.as_object().unwrap().len(), 10);
}

#[test]
fn capture_cleanup_accepts_only_a_terminal_cleaned_result() {
    let answer = ok("service.capture", json!({"phase": "cleanup", "raw": cleaned(json!({}))}));
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["code"], "ok");
    assert_eq!(answer["identity_removed"].as_f64(), Some(2.0));
    assert_eq!(answer["relays_removed"].as_f64(), Some(1.0));
    // Not terminal: the worker's pid did not exit.
    let answer = ok(
        "service.capture",
        json!({"phase": "cleanup", "raw": cleaned(json!({"worker_pid_exited": false}))}),
    );
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["code"], "remote_cleaned");
    // Pristine cleanup says nothing started.
    let pristine =
        cleaned(json!({"worker_started": false, "identity_removed": 0, "relays_removed": 0}));
    let answer = ok("service.capture", json!({"phase": "cleanup", "raw": pristine}));
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["code"], "no_remote_started");
    // Not started but something removed: neither pristine nor started.
    let odd = cleaned(json!({"worker_started": false}));
    assert_eq!(ok("service.capture", json!({"phase": "cleanup", "raw": odd}))["ok"], false);
}

#[test]
fn capture_prepare_needs_a_pristine_no_remote_started() {
    let pristine = cleaned(json!({"code": "no_remote_started", "worker_started": false,
        "identity_removed": 0, "relays_removed": 0}));
    let answer = ok("service.capture", json!({"phase": "prepare", "raw": pristine}));
    assert_eq!(
        (answer["ok"].clone(), answer["code"].clone()),
        (json!(true), json!("no_remote_started"))
    );
    let answer = ok("service.capture", json!({"phase": "prepare", "raw": cleaned(json!({}))}));
    assert_eq!(
        (answer["ok"].clone(), answer["code"].clone()),
        (json!(false), json!("remote_cleaned"))
    );
}

#[test]
fn capture_refuses_malformed_results() {
    for overrides in [
        json!({"identity_removed": 1.5}),
        json!({"relays_removed": -1}),
        json!({"identity_removed": "2"}),
        json!({"ok": 1}),
        json!({"code": 3}),
        json!({"descendants_exited": null}),
    ] {
        let raw = cleaned(overrides.clone());
        let answer = ok("service.capture", json!({"phase": "cleanup", "raw": raw}));
        assert_eq!(answer["code"], "remote_invalid_result", "{overrides}");
    }
    let answer = ok("service.capture", json!({"phase": "cleanup", "raw": "nope"}));
    assert_eq!(answer["code"], "remote_invalid_result");
    // A whole number written as a float is a count.
    let raw = cleaned(json!({"identity_removed": 2.0}));
    assert_eq!(ok("service.capture", json!({"phase": "cleanup", "raw": raw}))["ok"], true);
}

#[test]
fn capture_resume_needs_exactly_the_three_fields() {
    let good = json!({"ok": true, "code": "remote_capture_resumed", "lease_bound": true});
    assert_eq!(ok("service.capture", json!({"phase": "resume", "raw": good})), good);
    let unverified = json!({"ok": false, "code": "remote_resume_unverified", "lease_bound": false});
    for raw in [
        json!({"ok": true, "code": "remote_capture_resumed", "lease_bound": true, "extra": 1}),
        json!({"ok": true, "code": "remote_capture_resumed", "lease_bound": false}),
        json!({"ok": 1, "code": "remote_capture_resumed", "lease_bound": true}),
        json!([]),
        Value::Null,
    ] {
        assert_eq!(ok("service.capture", json!({"phase": "resume", "raw": raw})), unverified);
    }
}

#[test]
fn host_status_reads_the_computer_use_worker() {
    let host = json!({"pid": 7, "workers": {"computer-use": {"state": "unavailable",
        "reason": "no grant", "pid": 9.0, "activity": [{"session": "a"}]}}});
    let status = ok("service.hostStatus", json!({"host": host}));
    assert_eq!(status["hostPid"], 7);
    assert_eq!(status["failed"], true);
    assert_eq!(status["failure"], "no grant");
    assert_eq!(status["workerState"], "unavailable");
    assert_eq!(status["workerPid"], 9);
    assert_eq!(status["takeActivity"], true);
    assert_eq!(status["activity"], json!([{"session": "a"}]));
    // A reason without the failure is not shown.
    let host = json!({"workers": {"computer-use": {"state": "ready", "reason": "x"}}});
    let status = ok("service.hostStatus", json!({"host": host}));
    assert_eq!((status["failed"].clone(), status["failure"].clone()), (json!(false), Value::Null));
    assert_eq!(status["hostPid"], Value::Null);
    assert_eq!(status["activity"], Value::Null);
    // A reply without the worker's fields changes no session; no host clears them.
    assert_eq!(ok("service.hostStatus", json!({"host": {"pid": 7}}))["takeActivity"], false);
    assert_eq!(ok("service.hostStatus", json!({}))["takeActivity"], true);
    assert_eq!(ok("service.hostStatus", json!({"host": null}))["takeActivity"], true);
    // Pids Swift's `as? Int` refuses (or `pid_t` cannot hold) are none.
    let status = ok("service.hostStatus", json!({"host": {"pid": 7.5}}));
    assert_eq!(status["hostPid"], Value::Null);
    let status = ok("service.hostStatus", json!({"host": {"pid": 9_000_000_000_i64}}));
    assert_eq!(status["hostPid"], Value::Null);
}

#[test]
fn approvals_sort_by_app_id() {
    let answer = json!({"saved": {"always": ["com.b", {"app_id": "com.a"}, 3],
        "never": [{"id": "com.c"}, {"app_id": null, "id": "com.z"}]}});
    assert_eq!(
        ok("service.approvals", json!({"answer": answer})),
        json!([{"appId": "com.a", "decision": "always"}, {"appId": "com.b", "decision": "always"},
            {"appId": "com.c", "decision": "never"}])
    );
    // The saved object itself, and nothing.
    assert_eq!(
        ok("service.approvals", json!({"answer": {"never": ["x"]}})),
        json!([{"appId": "x", "decision": "never"}])
    );
    assert_eq!(ok("service.approvals", json!({})), json!([]));
}

#[test]
fn worker_labels() {
    for (state, label) in [
        ("ready", "running"),
        ("starting", "starting"),
        ("unavailable", "failed"),
        ("off", "stopped"),
    ] {
        assert_eq!(ok("service.workerLabel", json!({"state": state})), label);
    }
    assert_eq!(ok("service.workerLabel", json!({})), "stopped");
}

#[test]
fn channel_open_writes_hello_then_request() {
    let text = ok(
        "service.channelOpen",
        json!({"channel": "devices", "secret": "s", "extra": {"subscribe": "hub"}}),
    );
    let lines: Vec<Value> =
        text.as_str().unwrap().lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert!(text.as_str().unwrap().ends_with('\n'));
    assert_eq!(lines[0], json!({"type": "hello", "secret": "s"}));
    assert_eq!(lines[1], json!({"id": 1, "channel": "devices", "subscribe": "hub"}));
}

#[test]
fn channel_answer_names_the_pid_or_the_refusal() {
    let line = r#"{"ok":true,"result":{"pid":42}}"#;
    assert_eq!(
        ok("service.channelAnswer", json!({"line": line, "hostPid": 5})),
        json!({"pid": 42})
    );
    let line = r#"{"ok":true}"#;
    assert_eq!(ok("service.channelAnswer", json!({"line": line, "hostPid": 5})), json!({"pid": 5}));
    let line = r#"{"ok":false,"error":{"message":"bad secret"}}"#;
    assert_eq!(err("service.channelAnswer", json!({"line": line, "hostPid": 5})), "bad secret");
    let line = r#"{"ok":false}"#;
    assert_eq!(err("service.channelAnswer", json!({"line": line, "hostPid": 5})), "refused");
    for line in [json!(null), json!("not json"), json!("[1]")] {
        assert_eq!(
            err("service.channelAnswer", json!({"line": line, "hostPid": 5})),
            "cmux Remote closed the channel"
        );
    }
}

#[test]
fn answer_result_reads_a_channel_answer() {
    let answer =
        ok("service.answerResult", json!({"line": r#"{"id":3,"ok":true,"result":{"a":1}}"#}));
    assert_eq!(answer, json!({"result": {"a": 1}}));
    let answer = ok("service.answerResult", json!({"line": r#"{"id":3,"ok":true,"result":2}"#}));
    assert_eq!(answer, json!({"result": {}}));
    let answer =
        ok("service.answerResult", json!({"line": r#"{"ok":false,"error":{"message":"no"}}"#}));
    assert_eq!(answer, json!({"error": "identity", "message": "no"}));
    let answer = ok("service.answerResult", json!({"line": "{"}));
    assert_eq!(
        answer,
        json!({"error": "transport", "message": "cmux Remote's answer is not JSON"})
    );
    let answer = ok("service.answerResult", json!({}));
    assert_eq!(answer["error"], "transport");
}
