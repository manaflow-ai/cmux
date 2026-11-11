use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Receiver, sync_channel};
use std::time::Duration;

/// A build that reports its start, waits for `release`, and returns its number.
fn gated_build(
    builds: &Arc<AtomicU64>,
    started: std::sync::mpsc::SyncSender<u64>,
    release: Receiver<()>,
) -> impl FnOnce() -> anyhow::Result<Value> + use<> {
    let builds = builds.clone();
    move || {
        let number = builds.fetch_add(1, Ordering::SeqCst) + 1;
        started.send(number).unwrap();
        release.recv_timeout(Duration::from_secs(10)).unwrap();
        Ok(Value::from(number))
    }
}

fn wait_until(what: &str, done: impl Fn() -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(std::time::Instant::now() < deadline, "timed out waiting until {what}");
        std::thread::yield_now();
    }
}

fn waiting(flight: &TreeReplyFlight) -> usize {
    flight.state.lock().unwrap().waiting.values().sum()
}

#[test]
fn reads_one_after_another_each_build_their_own_value() {
    let flight = TreeReplyFlight::default();
    let builds = AtomicU64::new(0);
    for expected in 1..=3 {
        let value = flight.read(|| Ok(Value::from(builds.fetch_add(1, Ordering::SeqCst) + 1)));
        assert_eq!(value.unwrap(), Value::from(expected));
    }
    assert!(flight.state.lock().unwrap().shared.is_none(), "a lone read keeps nothing");
}

#[test]
fn readers_that_arrive_during_a_build_share_the_next_one() {
    let flight = Arc::new(TreeReplyFlight::default());
    let builds = Arc::new(AtomicU64::new(0));
    let (first_started, first_running) = sync_channel(1);
    let (release_first, first_gate) = sync_channel(1);
    let first = {
        let flight = flight.clone();
        let build = gated_build(&builds, first_started, first_gate);
        std::thread::spawn(move || flight.read(build).unwrap())
    };
    assert_eq!(first_running.recv_timeout(Duration::from_secs(10)).unwrap(), 1);

    // Eight readers arrive while build 1 runs: build 1 may have read the tree
    // before they arrived, so they need build 2, and share it.
    let (second_started, second_running) = sync_channel(8);
    let (release_second, second_gate) = sync_channel(1);
    let second_gate = Arc::new(Mutex::new(second_gate));
    let readers = (0..8)
        .map(|_| {
            let flight = flight.clone();
            let builds = builds.clone();
            let started = second_started.clone();
            let gate = second_gate.clone();
            std::thread::spawn(move || {
                flight
                    .read(move || {
                        let number = builds.fetch_add(1, Ordering::SeqCst) + 1;
                        started.send(number).unwrap();
                        gate.lock().unwrap().recv_timeout(Duration::from_secs(10)).unwrap();
                        Ok(Value::from(number))
                    })
                    .unwrap()
            })
        })
        .collect::<Vec<_>>();
    wait_until("the eight readers wait", || waiting(&flight) == 8);
    release_first.send(()).unwrap();
    assert_eq!(first.join().unwrap(), Value::from(1));

    assert_eq!(second_running.recv_timeout(Duration::from_secs(10)).unwrap(), 2);
    wait_until("seven readers wait for build 2", || waiting(&flight) == 7);
    release_second.send(()).unwrap();
    for reader in readers {
        assert_eq!(reader.join().unwrap(), Value::from(2), "every reader got build 2");
    }
    assert_eq!(builds.load(Ordering::SeqCst), 2, "eight readers cost one build");
    assert!(second_running.try_recv().is_err(), "no third build ran");
    let state = flight.state.lock().unwrap();
    assert!(state.shared.is_none(), "the shared value is dropped once taken");
    assert!(state.waiting.is_empty());
}

#[test]
fn a_failed_build_goes_to_its_own_reader_and_the_waiters_share_the_next() {
    let flight = Arc::new(TreeReplyFlight::default());
    let builds = Arc::new(AtomicU64::new(0));
    let (started, running) = sync_channel(1);
    let (release, gate) = sync_channel(1);
    let first = {
        let flight = flight.clone();
        let build = gated_build(&builds, started, gate);
        std::thread::spawn(move || flight.read(build))
    };
    running.recv_timeout(Duration::from_secs(10)).unwrap();
    // Build 2 fails; any later build succeeds.
    let (failing_started, failing_running) = sync_channel(1);
    let (release_failing, failing_gate) = sync_channel::<()>(1);
    let failing_gate = Arc::new(Mutex::new(failing_gate));
    let readers = (0..3)
        .map(|_| {
            let flight = flight.clone();
            let builds = builds.clone();
            let started = failing_started.clone();
            let gate = failing_gate.clone();
            std::thread::spawn(move || {
                flight.read(move || {
                    let number = builds.fetch_add(1, Ordering::SeqCst) + 1;
                    if number == 2 {
                        started.send(()).unwrap();
                        gate.lock().unwrap().recv_timeout(Duration::from_secs(10)).unwrap();
                        anyhow::bail!("terminal registry: read failed")
                    }
                    Ok(Value::from(number))
                })
            })
        })
        .collect::<Vec<_>>();
    wait_until("the three readers wait", || waiting(&flight) == 3);
    release.send(()).unwrap();
    assert_eq!(first.join().unwrap().unwrap(), Value::from(1));
    failing_running.recv_timeout(Duration::from_secs(10)).unwrap();
    wait_until("two readers wait for the failing build", || waiting(&flight) == 2);
    release_failing.send(()).unwrap();
    let mut errors = Vec::new();
    let mut values = Vec::new();
    for reader in readers {
        match reader.join().unwrap() {
            Ok(value) => values.push(value),
            Err(error) => errors.push(error.to_string()),
        }
    }
    assert_eq!(errors, ["terminal registry: read failed"], "only the failed build's reader fails");
    assert_eq!(values, [Value::from(3), Value::from(3)], "the two waiters share build 3");
    assert_eq!(builds.load(Ordering::SeqCst), 3);
    assert!(flight.state.lock().unwrap().shared.is_none());
}

#[test]
fn a_build_that_panics_leaves_its_waiters_a_build_of_their_own() {
    let flight = Arc::new(TreeReplyFlight::default());
    let (started, running) = sync_channel(1);
    let (release, gate) = sync_channel::<()>(1);
    let panicking = {
        let flight = flight.clone();
        std::thread::spawn(move || {
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                flight.read(move || {
                    started.send(()).unwrap();
                    gate.recv_timeout(Duration::from_secs(10)).unwrap();
                    panic!("the tree build panicked")
                })
            }))
            .is_err()
        })
    };
    running.recv_timeout(Duration::from_secs(10)).unwrap();
    let waiter = {
        let flight = flight.clone();
        std::thread::spawn(move || flight.read(|| Ok(Value::from("rebuilt"))).unwrap())
    };
    wait_until("the reader waits", || waiting(&flight) == 1);
    release.send(()).unwrap();
    assert!(panicking.join().unwrap(), "the build panicked");
    assert_eq!(waiter.join().unwrap(), Value::from("rebuilt"));
}
