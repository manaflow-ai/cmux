//! Link and port lines never wait behind a long op: a connect that waits
//! for its link's ready line settles later through the loop's inbox, and
//! the loop keeps serving ops and sending link changes meanwhile.

mod attach_common;
mod common;
mod edge_common;
mod serve_common;

use attach_common::Script;
use serde_json::{Value, json};
use serve_common::Host;
use std::sync::mpsc::channel;
use std::time::Duration;

const FIXTURES: &[&str] =
    &["vm-list", "vm-resume", "attach_endpoint_alpha", "attach_endpoint_beta"];

fn link_line(line: &Value, machine: &str, state: &str) -> bool {
    line["type"] == "event"
        && line["event"] == "cloud.link.changed"
        && line["machine"] == machine
        && line["state"] == state
}

/// A host with beta's link up and alpha's connect waiting for a ready
/// line that the test holds back.
fn host_with_a_held_connect() -> Host {
    let mut host = Host::start(FIXTURES);
    host.answer_of("1", "cloud.machine.list", json!({}));
    host.op("2", "cloud.machine.connect", json!({ "machine": "vm-beta02" }), "c-2");
    while let Some(line) = host.next() {
        if link_line(&line, "vm-beta02", "up") {
            break;
        }
    }
    let (spawned, held) = channel();
    host.spawner.log().script.push_back(Script::Hold(spawned));
    host.send(&json!({ "type": "op", "id": "3", "op": "cloud.machine.connect",
        "args": { "machine": "vm-alpha01" }, "origin": "user", "idempotency_key": "c-3" }));
    // Answer the connect's Cloud API calls until its link process runs.
    for _ in 0..100 {
        if held.try_recv().is_ok() {
            return host;
        }
        if let Some(line) = host.next_within(Duration::from_millis(50)) {
            assert_ne!(line["id"], "3", "the held connect answered early: {line}");
        }
    }
    panic!("alpha's link process never started");
}

#[test]
fn a_link_exit_is_sent_while_another_connect_waits_for_its_ready_line() {
    let mut host = host_with_a_held_connect();
    host.spawner.exit("vm-beta02", 1);
    let line = host.next();
    assert!(
        line.as_ref().is_some_and(|l| link_line(l, "vm-beta02", "down")),
        "beta's exit reaches the host while alpha's connect waits: {line:?}"
    );
    host.spawner.ready("vm-alpha01");
    let lines = host.answer("3");
    let result = lines.last().expect("result");
    assert_eq!(result["ok"], true, "{result}");
    assert_eq!(result["result"]["machine"], "vm-alpha01");
    assert_eq!(result["result"]["state"], "up");
}

#[test]
fn other_ops_run_while_a_connect_waits() {
    let mut host = host_with_a_held_connect();
    host.send(&json!({ "type": "op", "id": "4", "op": "cloud.port.list", "args": {} }));
    let mut result = None;
    while let Some(line) = host.next() {
        if line["type"] == "result" && line["id"] == "4" {
            result = Some(line);
            break;
        }
    }
    assert_eq!(
        result.as_ref().map(|r| r["ok"].clone()),
        Some(json!(true)),
        "a read answers while the connect waits: {result:?}"
    );
    host.spawner.ready("vm-alpha01");
    let result = host.answer("3").pop().expect("result");
    assert_eq!(result["ok"], true, "{result}");
}
