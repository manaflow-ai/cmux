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
    let request = Request { id: i as u64, op: "task.create".to_owned(), params: json!({"id": format!("task_{i}"), "title": format!("Task {i}")}), key: Some(format!("k{i}")), origin: None };
    let outcome = engine.handle(&Principal::user("usr_a"), request).unwrap();
    assert!(outcome.reply.is_ok(), "{:?}", outcome.reply.err());
}

fn segment(dir: &Path) -> std::path::PathBuf {
    let mut files: Vec<_> = fs::read_dir(dir.join("log")).unwrap().map(|e| e.unwrap().path()).collect();
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
