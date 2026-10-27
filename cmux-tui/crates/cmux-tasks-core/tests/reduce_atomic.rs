//! `reduce` is all or nothing: a refused op leaves the state exactly as it
//! was (no half-applied write without a seq, ledger entry or log record),
//! and the cascades that move statuses and end sessions still commit.

use std::collections::BTreeSet;

use cmux_tasks_core::{
    Ctx, Envelope, Op, Origin, Principal, RejectCode, SessionStatus, State, invariants, reduce,
};
use serde_json::{Value, json};

const ME: &str = "usr_leo";

fn envelope(key: &str, op: Value) -> Envelope {
    Envelope {
        actor: Principal::user(ME),
        origin: Origin::User,
        key: key.to_owned(),
        grants: BTreeSet::new(),
        op: serde_json::from_value::<Op>(op).expect("test op parses"),
    }
}

fn apply(state: &mut State, key: &str, op: Value) {
    reduce(state, &envelope(key, op.clone()), Ctx { now: 10 })
        .unwrap_or_else(|reject| panic!("{op} was refused: {reject:?}"));
}

fn team_with_task(status: &str) -> State {
    let mut state = State::new("team", "CMX");
    apply(
        &mut state,
        "create",
        json!({"op": "task.create", "params": {"id": "task_a", "title": "A", "status": status}}),
    );
    state
}

#[test]
fn update_of_a_task_whose_status_is_missing_changes_nothing() {
    // A snapshot can name a status that no longer exists; the update must
    // refuse before it writes the title.
    let mut state = team_with_task("st_todo");
    state.tasks.get_mut("task_a").expect("task_a exists").status = "st_gone".to_owned();
    let before = state.clone();

    let op = json!({"op": "task.update", "params": {
        "task": "task_a", "title": "Renamed", "status": "st_done",
    }});
    let reject = reduce(&mut state, &envelope("update", op), Ctx { now: 20 })
        .expect_err("the current status has no category");

    assert_eq!(reject.code, RejectCode::NotFound, "{reject:?}");
    assert_eq!(state, before);
}

#[test]
fn update_moves_title_and_status_in_one_commit() {
    let mut state = team_with_task("st_todo");
    let op = json!({"op": "task.update", "params": {
        "task": "task_a", "title": "Renamed", "status": "st_done",
    }});
    let commit = reduce(&mut state, &envelope("update", op), Ctx { now: 20 }).expect("update");

    let task = &state.tasks["task_a"];
    assert_eq!((task.title.as_str(), task.status.as_str()), ("Renamed", "st_done"));
    assert_eq!(task.manual_status_at, Some(20));
    assert_eq!(task.completed_at, Some(20));
    let names: Vec<&str> = commit.events.iter().map(|e| e.kind.as_str()).collect();
    assert_eq!(names, ["task.updated", "task.status_changed"]);
    assert!(invariants::check(&state).is_empty(), "{:?}", invariants::check(&state));
}

#[test]
fn status_delete_moves_its_tasks_to_the_replacement() {
    let mut state = team_with_task("st_triage");
    apply(
        &mut state,
        "delete-status",
        json!({"op": "task.status.delete", "params": {"status": "st_triage", "replacement": "st_todo"}}),
    );

    assert_eq!(state.tasks["task_a"].status, "st_todo");
    assert!(!state.statuses.contains_key("st_triage"));
    assert!(invariants::check(&state).is_empty(), "{:?}", invariants::check(&state));
}

#[test]
fn delete_ends_active_sessions_and_tombstones_the_task() {
    let mut state = team_with_task("st_todo");
    apply(
        &mut state,
        "delegate",
        json!({"op": "task.delegate", "params": {
            "task": "task_a", "session": "asess_one", "harness": "claude",
        }}),
    );
    apply(
        &mut state,
        "attach",
        json!({"op": "task.session.attach", "params": {
            "session": "asess_one", "acp_session": "acp-1",
        }}),
    );
    // The agent flow moved the task to the started status.
    assert_eq!(state.tasks["task_a"].status, "st_in_progress");

    apply(&mut state, "delete", json!({"op": "task.delete", "params": {"task": "task_a"}}));

    let task = &state.tasks["task_a"];
    assert!(task.deleted);
    assert_eq!((task.delegate.as_ref(), task.attention), (None, None));
    assert_eq!(task.status, "st_in_progress");
    let session = &state.sessions["asess_one"];
    assert_eq!((session.status, session.ended_at), (SessionStatus::Canceled, Some(10)));
    assert!(invariants::check(&state).is_empty(), "{:?}", invariants::check(&state));
}
