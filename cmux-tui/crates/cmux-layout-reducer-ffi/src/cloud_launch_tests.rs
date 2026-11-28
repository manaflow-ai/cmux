use super::*;

fn call(op: &str, body: serde_json::Value) -> serde_json::Value {
    serde_json::from_slice(&respond(op.as_bytes(), body.to_string().as_bytes()).expect(op)).unwrap()
}

#[test]
fn ops_answer() {
    assert!(handles(b"cloud_launch_gate"));
    assert!(!handles(b"cloud_start_x"));
    assert_eq!(call("cloud_launch_gate", json!({}))["gate"], "allowed");
    assert_eq!(call("cloud_launch_backoff", json!({"attempt": 0}))["ms"], 250);
    assert_eq!(call("cloud_launch_restart_phase", json!({"hasSession": true}))["phase"], "created");
    assert_eq!(call("cloud_launch_run_key", json!({"name": "n"}))["machine"], "name:n");
    assert_eq!(
        call(
            "cloud_launch_grow_step",
            json!({"sizes": {"floor": 1, "needed": 1, "maxDisk": 1u64 << 40}})
        )["do"],
        "resize"
    );
    let run = call("cloud_launch_session_request", json!({"agent": "claude", "name": "box"}));
    assert_eq!(run["command"], "cmux cloud start-session --name 'box' --agent claude");
    assert_eq!(
        call("cloud_launch_session_request", json!({"agent": "X"}))["invalid"],
        "agent_invalid"
    );
    let begun =
        call("cloud_launch_asks", json!({"change": {"do": "begin", "tab": "t", "token": "A"}}));
    assert_eq!(begun["answer"]["dialog"], "cloud-start-a");
    assert_eq!(begun["waiting"][0][0], "t");
    assert!(call("cloud_launch_facts", json!({}))["planRequiredCode"].is_string());
    assert_eq!(
        call("cloud_launch_session_command", json!({"machineId": "m", "agent": "codex"}))["command"],
        "cmux cloud start-session --target machine:'m' --agent codex"
    );
    assert_eq!(respond(b"cloud_launch_nope", b"{}"), Err(ERR_INVALID));
    assert_eq!(respond(b"cloud_launch_gate", b"nope"), Err(ERR_INVALID));
}
