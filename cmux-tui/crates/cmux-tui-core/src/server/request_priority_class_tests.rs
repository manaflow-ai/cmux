//! The person before automation across connections (p05-ipc-143): the ready
//! queues' order and starvation bound, the pool's person headroom and
//! automation cap, and the person's share of server permits.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use super::*;
use crate::server::connection_scheduler::connection_qos::{ConnectionClass, ConnectionClassCell};
use crate::server::sequenced_pool::{PoolConfig, Sequence, SequencePriority, SequencedPool};
use crate::server::tests::captured_writer;
use crate::server::worker_admission::{
    ResourceWorkerAdmission, ResourceWorkerAdmissionError, ServerSurfaceOperationAdmission,
};
use crate::server::{ClientRegistry, ClientTransport};

const WAIT: Duration = Duration::from_secs(5);

fn eventually(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + WAIT;
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn request_priority_class_follows_the_connection() {
    assert_eq!(RequestClass::of_connection(ConnectionClass::Person), RequestClass::Person);
    assert_eq!(RequestClass::of_connection(ConnectionClass::Unclassified), RequestClass::Person);
    assert_eq!(RequestClass::of_connection(ConnectionClass::Automation), RequestClass::Automation);
}

#[test]
fn request_priority_ready_takes_person_first_with_a_starvation_bound() {
    use RequestClass::{Automation, Person};
    let mut ready = ClassedReady::default();
    for id in 1..=3 {
        ready.push_back(Automation, 100 + id);
    }
    for id in 1..=PERSON_STREAK_BOUND as u64 + 2 {
        ready.push_back(Person, id);
    }
    let order: Vec<(u64, RequestClass)> = std::iter::from_fn(|| ready.pop(true)).collect();
    let mut expected: Vec<(u64, RequestClass)> =
        (1..=PERSON_STREAK_BOUND as u64).map(|id| (id, Person)).collect();
    expected.push((101, Automation));
    expected.extend(
        (PERSON_STREAK_BOUND as u64 + 1..=PERSON_STREAK_BOUND as u64 + 2).map(|id| (id, Person)),
    );
    expected.extend([(102, Automation), (103, Automation)]);
    assert_eq!(order, expected);
}

#[test]
fn request_priority_ready_holds_automation_at_its_cap() {
    use RequestClass::{Automation, Person};
    let mut ready = ClassedReady::default();
    ready.push_back(Automation, 7);
    assert_eq!(ready.pop(false), None, "automation at its cap waits");
    assert_eq!(ready.runnable(0), 0);
    ready.push_back(Person, 1);
    assert_eq!(ready.runnable(0), 1);
    assert_eq!(ready.pop(false), Some((1, Person)));
    // A streak counts only picks made while automation could run.
    for id in 2..2 + PERSON_STREAK_BOUND as u64 * 2 {
        ready.push_back(Person, id);
        assert_eq!(ready.pop(false), Some((id, Person)));
    }
    ready.push_back(Person, 99);
    assert_eq!(ready.pop(true), Some((99, Person)), "no streak built while automation was capped");
    assert!(ready.remove(Automation, 7));
    assert!(!ready.remove(Automation, 7));
    assert_eq!(ready.pop(true), None);
}

#[test]
fn request_priority_permits_keep_the_persons_share() {
    use RequestClass::{Automation, Person};
    assert_eq!(person_reserve(1), 0, "a cap of one is never the person's alone");
    assert_eq!(person_reserve(16), 2);
    assert_eq!(automation_capacity(64), 56);
    assert!(admits(Person, 4, 3, 3));
    assert!(!admits(Automation, 4, 3, 3));
    assert!(!admits(Person, 4, 4, 0));

    let admission = ResourceWorkerAdmission::new(64, 16);
    let automation: Vec<_> = (0..automation_capacity(16) as u64)
        .map(|client| admission.try_reserve(client, Automation).expect("under automation's share"))
        .collect();
    assert_eq!(
        admission.try_reserve(99, Automation).err(),
        Some(ResourceWorkerAdmissionError::ServerCapacity)
    );
    let person: Vec<_> = (0..person_reserve(16) as u64)
        .map(|client| admission.try_reserve(200 + client, Person).expect("the person's share"))
        .collect();
    assert_eq!(
        admission.try_reserve(300, Person).err(),
        Some(ResourceWorkerAdmissionError::ServerCapacity)
    );
    drop(person);
    drop(automation);
    assert_eq!(admission.active(), 0);
    assert!(admission.try_reserve(99, Automation).is_ok(), "released automation permits return");

    let surface = Arc::new(ServerSurfaceOperationAdmission::default());
    let held: Vec<_> =
        std::iter::from_fn(|| surface.try_reserve_worker(Automation)).take(64).collect();
    assert_eq!(held.len(), automation_capacity(super::super::SERVER_SURFACE_WORKER_CAPACITY));
    assert!(surface.try_reserve_worker(Person).is_some(), "a person clear finds a worker");
}

/// A task on `sequence` that says it started and runs until `release` is
/// dropped or sent.
fn hold(sequence: &Sequence, class: RequestClass, started: &mpsc::Sender<()>) -> mpsc::Sender<()> {
    let (release, wait) = mpsc::channel::<()>();
    let started = started.clone();
    sequence
        .post_as(class, move || {
            let _ = started.send(());
            let _ = wait.recv_timeout(WAIT);
        })
        .expect("posted");
    release
}

/// Every control worker runs automation: a person task still starts at
/// once, on one worker past the count, and automation never gets it.
#[test]
fn request_priority_person_runs_while_automation_holds_every_worker() {
    let pool =
        SequencedPool::new(PoolConfig::for_cores(4).with_workers(SequencePriority::Control, 2));
    let (started, started_rx) = mpsc::channel();
    let automation: Vec<Sequence> =
        (0..4).map(|_| pool.sequence(SequencePriority::Control)).collect();
    let releases: Vec<_> = automation
        .iter()
        .map(|sequence| hold(sequence, RequestClass::Automation, &started))
        .collect();
    for _ in 0..2 {
        started_rx.recv_timeout(WAIT).expect("automation holds a worker");
    }
    assert_eq!(pool.automation_running(SequencePriority::Control), 2);

    let person = pool.sequence(SequencePriority::Control);
    let (ran, ran_rx) = mpsc::channel();
    person.post_as(RequestClass::Person, move || ran.send(()).expect("receiver")).expect("posted");
    ran_rx.recv_timeout(WAIT).expect("the person's task ran while automation held every worker");
    assert!(
        started_rx.try_recv().is_err(),
        "the person's extra worker never runs a third automation task"
    );
    assert_eq!(pool.automation_running(SequencePriority::Control), 2);
    eventually("the extra worker exits", || pool.worker_count(SequencePriority::Control) == 2);

    drop(releases);
    for _ in 0..2 {
        started_rx.recv_timeout(WAIT).expect("queued automation runs once a slot frees");
    }
    eventually("automation drains", || pool.automation_running(SequencePriority::Control) == 0);
}

/// One worker, both classes queued: four person tasks, then one automation
/// task, until the person queue is empty.
#[test]
fn request_priority_pool_takes_person_first_and_bounds_the_wait_of_automation() {
    let pool =
        SequencedPool::new(PoolConfig::for_cores(4).with_workers(SequencePriority::Control, 1));
    let (started, started_rx) = mpsc::channel();
    let gate = pool.sequence(SequencePriority::Control);
    let release = hold(&gate, RequestClass::Person, &started);
    started_rx.recv_timeout(WAIT).expect("the gate runs");

    let order = Arc::new(Mutex::new(Vec::new()));
    let (done, done_rx) = mpsc::channel();
    let mut sequences = Vec::new();
    let mut post = |label: String, class: RequestClass| {
        let sequence = pool.sequence(SequencePriority::Control);
        let (order, done) = (order.clone(), done.clone());
        sequence
            .post_as(class, move || {
                order.lock().unwrap().push(label);
                done.send(()).unwrap();
            })
            .expect("posted");
        sequences.push(sequence);
    };
    for index in 1..=3 {
        post(format!("A{index}"), RequestClass::Automation);
    }
    for index in 1..=PERSON_STREAK_BOUND + 2 {
        post(format!("P{index}"), RequestClass::Person);
    }
    drop(release);
    for _ in 0..sequences.len() {
        done_rx.recv_timeout(WAIT).expect("every task runs");
    }
    let mut expected: Vec<String> = (1..=PERSON_STREAK_BOUND).map(|i| format!("P{i}")).collect();
    expected.push("A1".into());
    expected.extend((PERSON_STREAK_BOUND + 1..=PERSON_STREAK_BOUND + 2).map(|i| format!("P{i}")));
    expected.extend(["A2".into(), "A3".into()]);
    assert_eq!(*order.lock().unwrap(), expected);
}

/// A connection classed after its sequence queued work: the queued
/// sequence moves to the automation queue at the next post.
#[test]
fn request_priority_post_as_moves_a_queued_sequence() {
    let pool =
        SequencedPool::new(PoolConfig::for_cores(4).with_workers(SequencePriority::Control, 1));
    let (started, started_rx) = mpsc::channel();
    let gate = pool.sequence(SequencePriority::Control);
    let release = hold(&gate, RequestClass::Person, &started);
    started_rx.recv_timeout(WAIT).expect("the gate runs");

    let order = Arc::new(Mutex::new(Vec::new()));
    let ran = Arc::new(AtomicUsize::new(0));
    let task = |label: &'static str| {
        let (order, ran) = (order.clone(), ran.clone());
        move || {
            order.lock().unwrap().push(label);
            ran.fetch_add(1, Ordering::SeqCst);
        }
    };
    let reclassed = pool.sequence(SequencePriority::Control);
    reclassed.post(task("S1")).expect("posted");
    reclassed.post_as(RequestClass::Automation, task("S2")).expect("posted");
    let person = pool.sequence(SequencePriority::Control);
    person.post_as(RequestClass::Person, task("P")).expect("posted");
    drop(release);
    eventually("every task runs", || ran.load(Ordering::SeqCst) == 3);
    assert_eq!(*order.lock().unwrap(), ["P", "S1", "S2"]);
}

/// With `daemonPersonFirst` off every connection's requests are the
/// person's; on, an automation connection's are automation's.
#[test]
fn request_priority_class_needs_the_feature() {
    for (enabled, expected) in [(false, RequestClass::Person), (true, RequestClass::Automation)] {
        let cell = ConnectionClassCell::of_client(1, enabled);
        cell.set(ConnectionClass::Automation);
        assert_eq!(RequestClass::of_cell(&cell), expected, "feature on: {enabled}");
        cell.set(ConnectionClass::Person);
        assert_eq!(RequestClass::of_cell(&cell), RequestClass::Person);
    }
    assert_eq!(RequestClass::of_cell(&ConnectionClassCell::default()), RequestClass::Person);

    let registry = ClientRegistry::new();
    registry.person_first.set_for_test(true);
    let (writer, _outbound) = captured_writer();
    let client = registry.register(ClientTransport::Unix, writer);
    let cell = registry.connection_class(client);
    cell.set(ConnectionClass::Automation);
    assert_eq!(RequestClass::of_cell(&cell), RequestClass::Automation);
}

/// A sequence queued as automation at its cap that its connection then
/// posts to as the person's runs at once, on the person's extra worker.
#[test]
fn request_priority_a_sequence_moved_to_the_person_wakes_a_worker() {
    let pool =
        SequencedPool::new(PoolConfig::for_cores(4).with_workers(SequencePriority::Control, 1));
    let (started, started_rx) = mpsc::channel();
    let automation = pool.sequence(SequencePriority::Control);
    let release = hold(&automation, RequestClass::Automation, &started);
    started_rx.recv_timeout(WAIT).expect("automation holds the worker");

    let moved = pool.sequence(SequencePriority::Control);
    let (ran, ran_rx) = mpsc::channel();
    let first = ran.clone();
    moved.post_as(RequestClass::Automation, move || first.send(1).unwrap()).expect("posted");
    moved.post_as(RequestClass::Person, move || ran.send(2).unwrap()).expect("posted");
    assert_eq!(ran_rx.recv_timeout(WAIT).ok(), Some(1), "the moved sequence runs");
    assert_eq!(ran_rx.recv_timeout(WAIT).ok(), Some(2));
    drop(release);
}
