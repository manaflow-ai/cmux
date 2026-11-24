//! The Auto mode conformance vectors (`fixtures/conformance.json`), replayed against
//! [`FakeAutoCloud`]. The Cloud API's own test
//! (`backend/apps/api/test/auto-sessions-conformance.test.ts`) replays the same file against the
//! real routes, so a rule that changes in one store and not in the other fails one of the two.
//!
//! Run it with the fake compiled in:
//! `cargo test -p cmux-auto-session --features test-support --test conformance`.

mod call;
mod matcher;
mod vectors;

use cmux_auto_session::fake::FakeAutoCloud;
use serde_json::{Value, json};

use vectors::{Case, Step, Vectors};

/// Every route of the `AutoCloud` trait. Each has at least one step in the vectors.
const OPS: [&str; 23] = [
    "machine",
    "set_machine",
    "put",
    "create",
    "list",
    "get",
    "wait",
    "lease",
    "release",
    "append_events",
    "events",
    "put_chunk",
    "chunk",
    "post_snapshot",
    "snapshot",
    "post_inbox",
    "inbox",
    "ack_inbox",
    "keep",
    "move",
    "give",
    "assignments",
    "ack_assignment",
];

fn vectors() -> Vectors {
    serde_json::from_str(include_str!("../../fixtures/conformance.json"))
        .expect("fixtures/conformance.json reads as the vectors")
}

/// The handle a step calls through: the owner's, or the VM install's of `machine:<id>`.
fn caller(store: &FakeAutoCloud, by: &str) -> Result<FakeAutoCloud, String> {
    if by == "owner" {
        return Ok(store.as_owner());
    }
    match by.strip_prefix("machine:") {
        Some(machine) if !machine.is_empty() => Ok(store.as_machine(machine)),
        Some(_) | None => {
            Err(format!("the vectors name a caller the replayer does not know: {by}"))
        }
    }
}

/// One step on the store: what differs from what the vectors expect, if anything.
fn replay_step(store: &FakeAutoCloud, created: &mut String, step: &Step) -> Result<(), String> {
    if step.advance_ms > 0 {
        store.advance(step.advance_ms);
    }
    let cloud = caller(store, &step.by)?;
    let id = match step.id.as_deref() {
        Some("$created") => created.clone(),
        Some(id) => id.to_owned(),
        None => String::new(),
    };
    let got = call::call(&cloud, step, &id)?;
    if step.op == "create"
        && let Ok(answer) = &got
        && let Some(made) = answer.pointer("/session/id").and_then(|id| id.as_str())
    {
        made.clone_into(created);
    }
    matcher::check(step, &got)
}

/// Every step of a case on a new store. A step that differs does not stop the case, so one run
/// shows every difference.
fn replay(case: &Case) -> Vec<String> {
    let store = FakeAutoCloud::new();
    let mut created = String::new();
    let mut differences = Vec::new();
    for (n, step) in case.steps.iter().enumerate() {
        if let Err(why) = replay_step(&store, &mut created, step) {
            let disputed = step
                .disputed
                .as_deref()
                .map_or(String::new(), |why| format!(" (disputed in the real store: {why})"));
            differences.push(format!(
                "{:?}, step {} of {} ({} {}){disputed}: {why}",
                case.name,
                n.saturating_add(1),
                case.steps.len(),
                step.by,
                step.op,
            ));
        }
    }
    differences
}

#[test]
fn the_fake_store_answers_every_vector_as_the_real_store_does() {
    let differences: Vec<String> = vectors().cases.iter().flat_map(replay).collect();
    assert!(
        differences.is_empty(),
        "{} steps differ:\n{}",
        differences.len(),
        differences.join("\n")
    );
}

#[test]
fn the_replayer_reports_an_answer_or_a_refusal_that_differs() {
    let open = json!({
        "by": "owner", "op": "put", "id": "chat",
        "body": {"auto": true, "title": "Fix it", "harness": "claude", "device": "mac1"},
    });
    let with = |more: Value| {
        let mut step = open.clone();
        if let (Value::Object(step), Value::Object(more)) = (&mut step, more) {
            step.extend(more);
        }
        step
    };
    let wrong = json!([
        {"name": "another epoch", "steps": [with(json!({"expect": {"session": {"epoch": 2}}}))]},
        {"name": "another code", "steps": [open.clone(), {
            "by": "owner", "op": "snapshot", "id": "chat",
            "refuse": {"status": 404, "code": "not_found"},
        }]},
        {"name": "no refusal", "steps": [
            with(json!({"refuse": {"status": 409, "code": "auto.closed"}})),
        ]},
        {"name": "a refusal", "steps": [{
            "by": "owner", "op": "get", "id": "chat", "expect": {"session": {"epoch": 1}},
        }]},
    ]);
    let wrong: Vec<Case> = serde_json::from_value(wrong).expect("the cases read");
    for case in &wrong {
        assert_eq!(replay(case).len(), 1, "{:?} has one step that differs", case.name);
    }
}

#[test]
fn the_vectors_name_every_case_once_and_use_every_route() {
    let vectors = vectors();
    assert!(!vectors.cases.is_empty());
    for (n, case) in vectors.cases.iter().enumerate() {
        let earlier = vectors.cases.iter().take(n).any(|other| other.name == case.name);
        assert!(!earlier, "two cases are named {:?}", case.name);
        assert!(!case.steps.is_empty(), "{:?} has no step", case.name);
    }
    let steps = || vectors.cases.iter().flat_map(|case| &case.steps);
    for op in OPS {
        assert!(steps().any(|step| step.op == op), "no vector calls {op}");
    }
    for step in steps() {
        assert!(OPS.contains(&step.op.as_str()), "the vectors call {}, which is no route", step.op);
    }
}
