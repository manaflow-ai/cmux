//! Store durability: reopen equals the live state; a torn tail at any byte
//! loses only the unacknowledged record; one writer at a time.

use std::fs;
use std::path::Path;

use cmux_tasks::engine::{Clock, Engine};
use cmux_tasks::protocol::Request;
use cmux_tasks::store::{OpenError, Store};
use cmux_tasks_core::ids::Principal;
use proptest::prelude::*;
use serde_json::json;

fn clock() -> Clock {
    let mut now = 1_000;
    Box::new(move || {
        now += 7;
        now
    })
}

fn create(engine: &mut Engine, i: usize) {
    let request = Request {
        id: i as u64,
        op: "task.create".to_owned(),
        params: json!({"id": format!("task_{i}"), "title": format!("Task {i}")}),
        key: Some(format!("k{i}")),
        origin: None,
        credential: None,
        epoch: None,
    };
    let caller = cmux_tasks::identity::Caller::person(Principal::user("usr_a"));
    let outcome = engine.handle(&caller, request).unwrap();
    assert!(outcome.reply.is_ok(), "{:?}", outcome.reply.err());
}

fn segment(dir: &Path) -> std::path::PathBuf {
    let mut files: Vec<_> =
        fs::read_dir(dir.join("log")).unwrap().map(|e| e.unwrap().path()).collect();
    files.sort();
    files.pop().unwrap()
}

#[test]
fn reopen_recovers_the_same_state() {
    let dir = tempfile::tempdir().unwrap();
    let live = {
        let mut engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
        for i in 0..25 {
            create(&mut engine, i);
        }
        engine.state().clone()
    };
    let engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
    assert_eq!(engine.state(), &live);
    assert_eq!(engine.events_after(20).unwrap().len(), 5, "recovery refills the event ring");
}

#[test]
fn one_writer_at_a_time() {
    let dir = tempfile::tempdir().unwrap();
    let _first = Store::open(dir.path(), "local", "CMX").unwrap();
    assert!(matches!(Store::open(dir.path(), "local", "CMX"), Err(OpenError::Locked)));
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 48, .. ProptestConfig::default() })]

    /// Cut the log at a random byte: recovery keeps every complete record,
    /// drops only the torn one, and keeps working afterwards.
    #[test]
    fn torn_tail_loses_only_the_last_record(count in 1usize..12, cut_back in 1usize..400) {
        let dir = tempfile::tempdir().unwrap();
        {
            let mut engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
            for i in 0..count {
                create(&mut engine, i);
            }
        }
        let path = segment(dir.path());
        let bytes = fs::read(&path).unwrap();
        let cut = bytes.len().saturating_sub(cut_back);
        fs::write(&path, &bytes[..cut]).unwrap();
        let complete = bytes[..cut].iter().filter(|b| **b == b'\n').count();
        let mut engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
        prop_assert_eq!(engine.state().seq as usize, complete);
        prop_assert!(cmux_tasks_core::invariants::check(engine.state()).is_empty());
        create(&mut engine, 99);
        drop(engine);
        let engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
        prop_assert_eq!(engine.state().seq as usize, complete + 1);
    }
}

/// Recovery across many snapshots and segment rotations (small limits).
#[test]
fn recovers_across_snapshots_and_rotations() {
    let dir = tempfile::tempdir().unwrap();
    let limits = cmux_tasks::store::Limits { segment_bytes: 4_096, snapshot_every: 50 };
    let live = {
        let mut engine = Engine::open_with(dir.path(), "local", "CMX", clock(), limits).unwrap();
        for i in 0..1_200 {
            create(&mut engine, i);
        }
        engine.state().clone()
    };
    let segments = fs::read_dir(dir.path().join("log")).unwrap().count();
    assert!(segments > 10, "expected rotations, found {segments} segments");
    let engine = Engine::open_with(dir.path(), "local", "CMX", clock(), limits).unwrap();
    assert_eq!(engine.state(), &live);
    // A damaged newest snapshot falls back to an older one plus the log.
    let mut snaps: Vec<_> =
        fs::read_dir(dir.path().join("snapshots")).unwrap().map(|e| e.unwrap().path()).collect();
    snaps.sort();
    fs::write(snaps.last().unwrap(), b"{broken").unwrap();
    drop(engine);
    let engine = Engine::open_with(dir.path(), "local", "CMX", clock(), limits).unwrap();
    assert_eq!(engine.state(), &live);
}

/// Records written before the P8 stamp existed have no `stamp` field; they
/// still recover to the same state (the reducer uses the principal only).
#[test]
fn records_without_a_stamp_still_recover() {
    let dir = tempfile::tempdir().unwrap();
    let live = {
        let mut engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
        for i in 0..5 {
            create(&mut engine, i);
        }
        engine.state().clone()
    };
    let path = segment(dir.path());
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("\"stamp\""), "new records carry the stamp");
    let legacy: String = text
        .lines()
        .map(|line| {
            let mut value: serde_json::Value = serde_json::from_str(line).unwrap();
            value.as_object_mut().unwrap().remove("stamp");
            format!("{value}\n")
        })
        .collect();
    fs::write(&path, legacy).unwrap();
    let engine = Engine::open(dir.path(), "local", "CMX", clock()).unwrap();
    assert_eq!(engine.state(), &live);
    assert!(engine.events_after(0).unwrap().iter().all(|e| e.stamp.is_none()));
}

/// Review finding: before the stamp, ledger keys were scoped to the
/// principal, so one person's agent and the person could commit the same key
/// for different ops. Such a log must still recover to the same state.
#[test]
fn a_legacy_log_with_one_key_under_two_principals_recovers() {
    use cmux_tasks_core::ids::{AgentClass, AgentRef};
    use cmux_tasks_core::op::{Op, TaskCreate};
    use cmux_tasks_core::{Envelope, Origin};
    let dir = tempfile::tempdir().unwrap();
    let agent = Principal::Agent(AgentRef {
        principal: "agt_x".to_owned(),
        class: AgentClass::Ordinary,
        harness: "claude".to_owned(),
        on_behalf_of: "usr_a".to_owned(),
    });
    let legacy = |actor: Principal, id: &str| Envelope {
        actor,
        stamp: None,
        origin: Origin::Cli,
        key: "k".to_owned(),
        grants: Default::default(),
        op: Op::TaskCreate(TaskCreate {
            id: id.to_owned(),
            title: id.to_owned(),
            ..TaskCreate::default()
        }),
    };
    let live = {
        let (mut store, _) = Store::open(dir.path(), "local", "CMX").unwrap();
        store.stage(&legacy(agent, "task_a"), 1_000).unwrap();
        let second = store.stage(&legacy(Principal::user("usr_a"), "task_b"), 1_010).unwrap();
        assert!(!second.replay, "old records keep the principal scope");
        store.flush().unwrap();
        store.state().clone()
    };
    let (store, _) = Store::open(dir.path(), "local", "CMX").unwrap();
    assert_eq!(store.state(), &live);
    assert_eq!(store.state().tasks.len(), 2);
}
