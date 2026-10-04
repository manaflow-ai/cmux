//! Replays the shared automation lease vectors (the same file the CUA host
//! replays): every case from an empty table, checking the result, the
//! target's lease snapshot and the lease frames after every step.

use super::*;
use serde_json::{Value, json};

const VECTORS: &str = include_str!("../../../../schemas/automation-lease/vectors.json");

fn op_of(step: &Value) -> LeaseOp {
    let target = || step["target"].as_str().expect("target").to_owned();
    match step["op"].as_str().expect("op") {
        "acquire" => LeaseOp::Acquire { target: target() },
        "act" => LeaseOp::Act { target: target() },
        "observe" => LeaseOp::Observe { target: target() },
        "release" => LeaseOp::Release { target: target() },
        "session_end" => LeaseOp::SessionEnd,
        "user_input" => LeaseOp::UserInput { target: target() },
        "take_over" => LeaseOp::TakeOver { target: target() },
        "hand_back" => LeaseOp::HandBack { target: target() },
        "stop" => LeaseOp::Stop { target: target() },
        "allow" => LeaseOp::Allow { session: step["session"].as_str().expect("session").into() },
        other => panic!("unknown op {other}"),
    }
}

fn caller_of(step: &Value) -> LeaseCaller {
    let text = |key: &str| step[key].as_str().unwrap_or("").to_owned();
    LeaseCaller {
        session: text("session"),
        actor: text("actor"),
        on_behalf_of: step["on_behalf_of"].as_str().map(str::to_owned),
        origin: text("origin"),
        label: text("label"),
    }
}

fn lease_json(lease: &Lease) -> Value {
    serde_json::to_value(lease).expect("lease serializes")
}

#[test]
fn the_host_replays_every_shared_lease_vector() {
    let vectors: Value = serde_json::from_str(VECTORS).expect("vectors parse");
    let cases = vectors["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for case in cases {
        let name = case["name"].as_str().unwrap_or("?");
        let mut table = LeaseTable::default();
        for (index, entry) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let (step, expect) = (&entry["step"], &entry["expect"]);
            let at = format!("{name}, step {index} ({})", step["op"]);
            let outcome =
                table.apply(&op_of(step), &caller_of(step), step["now_ms"].as_u64().unwrap_or(0));
            let (result, frames) = match outcome {
                Ok(frames) => (json!({"ok": true}), frames),
                Err(error) => (json!({"error": error.code()}), Vec::new()),
            };
            assert_eq!(result, expect["result"], "{at}: result");
            let frames: Vec<Value> = frames
                .iter()
                .map(|f| json!({"target": f.target, "lease": f.lease.as_ref().map(lease_json)}))
                .collect();
            assert_eq!(Value::Array(frames), expect["frames"], "{at}: frames");
            if let Some(target) = step["target"].as_str() {
                let snapshot = table.get(target).map(|record| {
                    let mut lease = lease_json(&record.lease);
                    lease["needs_fresh_observe"] = json!(record.needs_fresh_observe);
                    lease
                });
                assert_eq!(snapshot.unwrap_or(Value::Null), expect["lease"], "{at}: lease");
            }
        }
    }
}
