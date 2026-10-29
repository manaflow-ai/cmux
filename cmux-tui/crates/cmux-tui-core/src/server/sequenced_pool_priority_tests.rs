//! A sequence moves between priorities: its next task runs on
//! the new priority's workers, in post order, whether it was idle, queued,
//! running or waiting on a delayed task when it moved.

use std::sync::mpsc;
use std::time::Duration;

use super::super::{PoolConfig, SequencePriority, SequencedPool};

const WAIT: Duration = Duration::from_secs(5);

fn thread_name() -> String {
    std::thread::current().name().unwrap_or_default().to_owned()
}

#[test]
fn an_idle_sequence_runs_its_next_task_at_its_new_priority() {
    let pool = SequencedPool::new(PoolConfig::for_cores(8));
    let sequence = pool.sequence(SequencePriority::Input);
    let (tx, rx) = mpsc::channel();
    let first = tx.clone();
    sequence.post(move || first.send(thread_name()).unwrap()).unwrap();
    assert_eq!(rx.recv_timeout(WAIT).unwrap(), "mux-seq-input");
    sequence.update_priority(SequencePriority::Utility);
    assert_eq!(sequence.priority(), Some(SequencePriority::Utility));
    sequence.post(move || tx.send(thread_name()).unwrap()).unwrap();
    assert_eq!(rx.recv_timeout(WAIT).unwrap(), "mux-seq-utility");
}

#[test]
fn a_running_sequence_requeues_at_its_new_priority_in_order() {
    let pool = SequencedPool::new(PoolConfig::for_cores(8));
    let sequence = pool.sequence(SequencePriority::Input);
    let (gate_tx, gate_rx) = mpsc::channel::<()>();
    let (started_tx, started_rx) = mpsc::channel();
    let (tx, rx) = mpsc::channel();
    sequence
        .post(move || {
            started_tx.send(()).unwrap();
            gate_rx.recv_timeout(WAIT).unwrap();
        })
        .unwrap();
    started_rx.recv_timeout(WAIT).unwrap();
    for index in 0..3 {
        let tx = tx.clone();
        sequence.post(move || tx.send((index, thread_name())).unwrap()).unwrap();
    }
    // Moved while its first task runs and three more wait behind it.
    sequence.update_priority(SequencePriority::Background);
    gate_tx.send(()).unwrap();
    for index in 0..3 {
        assert_eq!(rx.recv_timeout(WAIT).unwrap(), (index, "mux-seq-background".to_owned()));
    }
}

#[test]
fn a_queued_sequence_moves_out_of_its_old_ready_list() {
    // One input worker, kept busy by another sequence: the moved sequence
    // waits in the input ready list until it moves, then runs on utility
    // while the input worker is still busy.
    let config = PoolConfig::for_cores(8).with_workers(SequencePriority::Input, 1);
    let pool = SequencedPool::new(config);
    let busy = pool.sequence(SequencePriority::Input);
    let moved = pool.sequence(SequencePriority::Input);
    let (gate_tx, gate_rx) = mpsc::channel::<()>();
    let (started_tx, started_rx) = mpsc::channel();
    busy.post(move || {
        started_tx.send(()).unwrap();
        gate_rx.recv_timeout(WAIT).unwrap();
    })
    .unwrap();
    started_rx.recv_timeout(WAIT).unwrap();
    let (tx, rx) = mpsc::channel();
    moved.post(move || tx.send(thread_name()).unwrap()).unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(50)).is_err(), "the input worker is busy");
    moved.update_priority(SequencePriority::Utility);
    assert_eq!(rx.recv_timeout(WAIT).unwrap(), "mux-seq-utility");
    gate_tx.send(()).unwrap();
}

#[test]
fn a_delayed_task_moves_with_its_sequence() {
    let pool = SequencedPool::new(PoolConfig::for_cores(8));
    let sequence = pool.sequence(SequencePriority::Input);
    let (tx, rx) = mpsc::channel();
    sequence
        .post_delayed(Duration::from_millis(30), move || tx.send(thread_name()).unwrap())
        .unwrap();
    sequence.update_priority(SequencePriority::Utility);
    assert_eq!(rx.recv_timeout(WAIT).unwrap(), "mux-seq-utility");
}

#[test]
fn the_same_priority_changes_nothing() {
    let pool = SequencedPool::new(PoolConfig::for_cores(8));
    let sequence = pool.sequence(SequencePriority::Utility);
    sequence.update_priority(SequencePriority::Utility);
    assert_eq!(sequence.priority(), Some(SequencePriority::Utility));
    let (tx, rx) = mpsc::channel();
    sequence.post(move || tx.send(thread_name()).unwrap()).unwrap();
    assert_eq!(rx.recv_timeout(WAIT).unwrap(), "mux-seq-utility");
}
