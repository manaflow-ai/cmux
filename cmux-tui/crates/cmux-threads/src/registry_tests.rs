//! A thread that follows a [`DesiredQos`] applies a request itself, once,
//! at its next pass (p02-threads task 236).

use std::sync::mpsc;

use crate::{
    DesiredQos, QosChange, ThreadInfo, ThreadQos, apply_pending_qos, reversible, snapshot,
    spawn_following,
};
#[cfg(target_vendor = "apple")]
use crate::{LiveQos, current};

fn row(name: &str) -> Option<ThreadInfo> {
    snapshot().into_iter().find(|row| row.name == name)
}

/// What the calling thread's next pass sees: the change applied, if any,
/// and the result of a second pass with no new request.
fn two_passes() -> (Option<QosChange>, Option<QosChange>) {
    (apply_pending_qos(), apply_pending_qos())
}

#[test]
fn following_threads_apply_a_request_at_their_next_pass_only() {
    let desired = DesiredQos::new(ThreadQos::UserInteractive);
    let names = ["cmux-threads-test-follow-a", "cmux-threads-test-follow-b"];
    let mut steps = Vec::new();
    let mut results = Vec::new();
    let mut handles = Vec::new();
    for name in names {
        let (step_tx, step_rx) = mpsc::channel::<()>();
        let (result_tx, result_rx) = mpsc::channel();
        handles.push(
            spawn_following(name, ThreadQos::UserInteractive, desired.clone(), move || {
                // The first pass: nothing requested yet.
                result_tx.send(two_passes()).unwrap();
                while step_rx.recv().is_ok() {
                    result_tx.send(two_passes()).unwrap();
                }
            })
            .unwrap(),
        );
        steps.push(step_tx);
        results.push(result_rx);
    }
    for result in &results {
        assert_eq!(result.recv().unwrap(), (None, None), "no request, no syscall");
    }
    // The start state is the runner's: from a raised nice the raise to
    // UserInteractive at spawn is refused and counted already.
    let start = names.map(|name| row(name).expect("a running thread has a row"));

    // One request reaches both threads; each applies it once.
    assert!(desired.request(ThreadQos::Utility));
    assert!(!desired.request(ThreadQos::Utility), "the same request is no change");
    let demoted =
        if reversible(ThreadQos::Utility) { QosChange::Applied } else { QosChange::Refused };
    for (step, result) in steps.iter().zip(&results) {
        step.send(()).unwrap();
        assert_eq!(result.recv().unwrap(), (Some(demoted), None));
    }
    for (name, start) in names.iter().zip(&start) {
        let row = row(name).expect("a running thread has a row");
        assert_eq!(row.desired, ThreadQos::Utility);
        assert_eq!(row.declared, ThreadQos::UserInteractive);
        if demoted == QosChange::Applied {
            assert_eq!(row.effective, Some(ThreadQos::Utility));
        } else {
            assert_eq!(
                row.refused_changes,
                start.refused_changes + 1,
                "a demotion it could not undo is counted"
            );
        }
        #[cfg(target_vendor = "apple")]
        assert_eq!(row.live, LiveQos::Class(ThreadQos::Utility));
    }

    // Shown again: the threads return to their class at the next pass.
    assert!(desired.request(ThreadQos::UserInteractive));
    for (step, result) in steps.iter().zip(&results) {
        step.send(()).unwrap();
        let (promoted, again) = result.recv().unwrap();
        assert!(promoted.is_some());
        assert_eq!(again, None);
    }
    #[cfg(target_vendor = "apple")]
    for name in names {
        assert_eq!(row(name).unwrap().live, LiveQos::Class(ThreadQos::UserInteractive));
    }
    drop(steps);
    for handle in handles {
        handle.join().unwrap();
    }
}

#[test]
fn an_unregistered_thread_has_nothing_pending() {
    let pending = std::thread::Builder::new()
        .name("cmux-threads-test-unregistered".into())
        .spawn(apply_pending_qos)
        .unwrap()
        .join()
        .unwrap();
    assert_eq!(pending, None);
}

#[cfg(target_vendor = "apple")]
#[test]
fn a_thread_that_starts_after_a_request_applies_it_at_its_first_pass() {
    let desired = DesiredQos::new(ThreadQos::UserInteractive);
    desired.request(ThreadQos::Utility);
    let (before, change, after) = spawn_following(
        "cmux-threads-test-follow-late",
        ThreadQos::UserInteractive,
        desired,
        || (current(), apply_pending_qos(), current()),
    )
    .unwrap()
    .join()
    .unwrap();
    assert_eq!(before, LiveQos::Class(ThreadQos::UserInteractive));
    assert_eq!(change, Some(QosChange::Applied));
    assert_eq!(after, LiveQos::Class(ThreadQos::Utility));
}
