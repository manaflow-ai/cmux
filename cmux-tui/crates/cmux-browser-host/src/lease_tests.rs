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
        "allow" => LeaseOp::Allow { actor: step["actor"].as_str().expect("actor").into() },
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
        implicit_session: step["implicit_session"].as_bool().unwrap_or(false),
        engine: text("engine"),
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

fn agent(session: &str, actor: &str, on_behalf_of: Option<&str>) -> LeaseCaller {
    LeaseCaller::new(session, actor, on_behalf_of.map(str::to_owned), "mcp", "task", "headless")
}

fn user() -> LeaseCaller {
    LeaseCaller { origin: "user".into(), ..LeaseCaller::default() }
}

fn act(target: &str) -> LeaseOp {
    LeaseOp::Act { target: target.into() }
}

#[test]
fn a_stopped_actor_cannot_dodge_the_stop_with_a_new_session_name() {
    let mut table = LeaseTable::default();
    table.apply(&act("t1"), &agent("s1", "agent:a", None), 1).unwrap();
    table.apply(&LeaseOp::Stop { target: "t1".into() }, &user(), 2).unwrap();
    assert_eq!(table.apply(&act("t2"), &agent("s-new", "agent:a", None), 3), Err(LeaseError::StoppedByUser));
    assert!(table.apply(&act("t2"), &agent("s2", "agent:b", None), 3).is_ok(), "other actors keep working");
}

#[test]
fn a_stop_applies_to_the_principal_an_agent_acts_for() {
    let mut table = LeaseTable::default();
    table.apply(&act("t1"), &agent("s1", "agent:sub-1", Some("agent:chief")), 1).unwrap();
    table.apply(&LeaseOp::Stop { target: "t1".into() }, &user(), 2).unwrap();
    for caller in [agent("s2", "agent:sub-2", Some("agent:chief")), agent("s3", "agent:chief", None)] {
        assert_eq!(table.apply(&act("t2"), &caller, 3), Err(LeaseError::StoppedByUser), "{caller:?}");
    }
    table.apply(&LeaseOp::Allow { actor: "agent:chief".into() }, &user(), 4).unwrap();
    assert!(table.apply(&act("t2"), &agent("s2", "agent:sub-2", Some("agent:chief")), 5).is_ok());
}

#[test]
fn only_the_person_allows_a_stopped_principal_again() {
    let mut table = LeaseTable::default();
    table.apply(&act("t1"), &agent("s1", "agent:a", None), 1).unwrap();
    table.apply(&LeaseOp::Stop { target: "t1".into() }, &user(), 2).unwrap();
    let allow = LeaseOp::Allow { actor: "agent:a".into() };
    assert_eq!(table.apply(&allow, &agent("s1", "agent:a", None), 3), Err(LeaseError::UserOriginRequired));
    assert_eq!(table.apply(&act("t1"), &agent("s1", "agent:a", None), 4), Err(LeaseError::StoppedByUser));
}

#[test]
fn only_provider_engines_refuse_the_implicit_session() {
    for (engine, refused) in [("cef", true), ("webkit", true), ("headless", false), ("desktop", false)] {
        let mut table = LeaseTable::default();
        let mut caller = agent("default", "agent:a", None);
        caller.engine = engine.into();
        caller.implicit_session = true;
        for op in [LeaseOp::Acquire { target: "t".into() }, act("t")] {
            let outcome = table.apply(&op, &caller, 1);
            if refused {
                assert_eq!(outcome, Err(LeaseError::SessionRequired), "{engine} {op:?}");
                assert_eq!(LeaseError::SessionRequired.code(), "session_required");
            } else {
                assert!(outcome.is_ok(), "{engine} {op:?}: {outcome:?}");
            }
        }
        caller.implicit_session = false;
        assert!(table.apply(&act("t"), &caller, 2).is_ok(), "{engine}: a named session works");
    }
}

#[test]
fn a_gone_target_drops_its_lease_with_a_null_frame_and_no_origin_check() {
    let mut table = LeaseTable::default();
    table.apply(&act("t1"), &agent("s1", "agent:a", None), 1).unwrap();
    let frames = table
        .apply(&LeaseOp::TargetGone { target: "t1".into() }, &LeaseCaller::default(), 2)
        .unwrap();
    assert_eq!(frames, vec![LeaseFrame { target: "t1".into(), lease: None }]);
    assert!(table.get("t1").is_none());
    assert_eq!(table.apply(&LeaseOp::TargetGone { target: "t1".into() }, &LeaseCaller::default(), 3), Ok(vec![]));
}
