//! Every golden vector in `tests/cases/*.json` through the JSON ops
//! (`ops::call`) and the watch ops (`ffi::watch_call`). The vectors encode
//! what the Swift launch code and its tests did before the move.

use cmux_daemon_launch_core::ffi::watch_call;
use cmux_daemon_launch_core::ops::call;
use cmux_daemon_launch_core::watch::{Policy, Watch};
use serde_json::Value;
use std::path::Path;

pub fn cases(file: &str) -> Vec<Value> {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases").join(file);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    match serde_json::from_str(&text) {
        Ok(Value::Array(cases)) => cases,
        other => panic!("{file}: not a JSON array: {other:?}"),
    }
}

pub const OP_FILES: [&str; 6] = [
    "handoff.json",
    "ensure.json",
    "failure.json",
    "environment.json",
    "cloud_link.json",
    "install_key.json",
];

#[test]
fn every_op_vector_answers_as_the_swift_code_did() {
    let mut failures = Vec::new();
    let mut count = 0;
    for file in OP_FILES {
        for case in cases(file) {
            count += 1;
            let name = case["name"].as_str().unwrap_or("?");
            let op = case["op"].as_str().unwrap_or_default();
            match call(op, &case["request"]) {
                Ok(reply) if reply == case["expect"] => {}
                other => failures
                    .push(format!("{file} {name} ({op}): got {other:?}, want {}", case["expect"])),
            }
        }
    }
    assert!(count > 100, "only {count} vectors");
    assert!(
        failures.is_empty(),
        "{} of {count} vectors failed:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn every_watch_scenario_runs_as_the_swift_watch_did() {
    let mut failures = Vec::new();
    for scenario in cases("watch.json") {
        let name = scenario["name"].as_str().unwrap_or("?");
        let mut watch = Watch::new(Policy::STANDARD);
        for (index, step) in scenario["steps"].as_array().into_iter().flatten().enumerate() {
            let op = step["op"].as_str().unwrap_or_default();
            match watch_call(&mut watch, op, &step["request"]) {
                Ok(reply) if reply == step["expect"] => {}
                other => failures.push(format!(
                    "{name} step {index} ({op} {}): got {other:?}, want {}",
                    step["request"], step["expect"]
                )),
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

#[test]
fn an_unknown_op_and_a_bad_request_are_refused() {
    use cmux_daemon_launch_core::ops::OpError;
    assert_eq!(call("nope", &serde_json::json!({})), Err(OpError::Unknown));
    assert_eq!(call("version_decision", &serde_json::json!({"running": 3})), Err(OpError::Invalid));
}
