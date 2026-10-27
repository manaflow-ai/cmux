//! Each test receives at its own source line: the site table is process-wide
//! and tests run in parallel, so a site belongs to one test.

use super::mpsc;
use crate::blocking::{self, BlockingKind, BlockingMode};
use crate::{ThreadQos, disallow_blocking};
use std::time::Duration;

/// Runs `f` on a registered thread at `qos` and returns its result.
fn on<R: Send + 'static>(qos: ThreadQos, f: impl FnOnce() -> R + Send + 'static) -> R {
    crate::spawn("sync-test", qos, f).expect("spawn").join().expect("test thread")
}

/// Sends `count` values from a registered thread at `qos`; it exits before
/// the receiver starts, so each message carries the QoS alone.
fn produce(qos: ThreadQos, sender: mpsc::Sender<u32>, count: u32) {
    on(qos, move || {
        for value in 0..count {
            sender.send(value).expect("send");
        }
    });
}

fn inversions_at(line: u32) -> Option<u64> {
    blocking::snapshot().site(file!(), line).map(|site| {
        assert!(site.kinds.contains(BlockingKind::PriorityInversion), "{site:?}");
        assert!(!site.lane_sync, "{site:?}");
        site.count
    })
}

#[cfg(debug_assertions)]
#[test]
fn a_user_interactive_receiver_of_a_utility_producer_records_one_site() {
    let (sender, receiver) = mpsc::channel();
    produce(ThreadQos::Utility, sender, 3);
    let line = on(ThreadQos::UserInteractive, move || {
        let mut line = 0;
        for _ in 0..3 {
            line = line!() + 1;
            receiver.recv().expect("recv");
        }
        line
    });
    assert_eq!(inversions_at(line), Some(3));
}

#[test]
fn equal_or_lower_receiver_qos_records_nothing() {
    let (sender, receiver) = mpsc::channel();
    produce(ThreadQos::Utility, sender, 2);
    let equal = on(ThreadQos::Utility, move || {
        let line = line!() + 1;
        receiver.recv().expect("recv");
        let timeout_line = line!() + 1;
        receiver.recv_timeout(Duration::from_secs(5)).expect("recv_timeout");
        [line, timeout_line]
    });

    let (sender, receiver) = mpsc::channel();
    produce(ThreadQos::UserInteractive, sender, 1);
    let lower = on(ThreadQos::Utility, move || {
        let line = line!() + 1;
        receiver.recv().expect("recv");
        line
    });

    for line in equal.into_iter().chain([lower]) {
        assert_eq!(inversions_at(line), None, "line {line}");
    }
}

#[test]
fn a_receive_that_does_not_wait_records_nothing() {
    let (sender, receiver) = mpsc::channel();
    produce(ThreadQos::Utility, sender, 2);
    let lines = on(ThreadQos::UserInteractive, move || {
        let line = line!() + 1;
        assert_eq!(receiver.try_recv(), Ok(0));
        let iter_line = line!() + 1;
        assert_eq!(receiver.try_iter().collect::<Vec<_>>(), [1]);
        [line, iter_line]
    });
    for line in lines {
        assert_eq!(inversions_at(line), None, "line {line}");
    }
}

#[test]
fn an_unregistered_receiver_records_nothing() {
    let (sender, receiver) = mpsc::channel();
    produce(ThreadQos::Utility, sender, 1);
    let line = line!() + 1;
    receiver.recv().expect("recv");
    assert_eq!(inversions_at(line), None);
}

#[cfg(debug_assertions)]
#[test]
fn blocking_iteration_records_at_the_loop() {
    let (sender, receiver) = mpsc::sync_channel(4);
    on(ThreadQos::Utility, move || {
        for value in 0..2 {
            sender.send(value).expect("send");
        }
    });
    let line = on(ThreadQos::UserInitiated, move || {
        let line = line!() + 1;
        let values: Vec<u32> = receiver.iter().collect();
        assert_eq!(values, [0, 1]);
        line
    });
    assert_eq!(inversions_at(line), Some(2));
}

#[test]
fn failed_sends_hand_the_value_back() {
    let (sender, receiver) = mpsc::channel::<u32>();
    drop(receiver);
    assert_eq!(sender.send(5), Err(mpsc::SendError(5)));

    let (sender, receiver) = mpsc::sync_channel::<u32>(1);
    sender.try_send(1).expect("room for one");
    assert_eq!(sender.try_send(2), Err(mpsc::TrySendError::Full(2)));
    drop(receiver);
    assert_eq!(sender.try_send(3), Err(mpsc::TrySendError::Disconnected(3)));
}

#[test]
fn a_receive_on_a_disallowed_thread_is_a_recv_site() {
    blocking::set_mode(BlockingMode::Record);
    let line = on(ThreadQos::Utility, || {
        let (sender, receiver) = mpsc::channel();
        sender.send(1).expect("send");
        disallow_blocking();
        let line = line!() + 1;
        assert_eq!(receiver.recv(), Ok(1));
        line
    });
    let site = blocking::snapshot().site(file!(), line).copied().expect("recv site");
    assert!(site.kinds.contains(BlockingKind::Recv), "{site:?}");
    assert!(!site.kinds.contains(BlockingKind::PriorityInversion), "{site:?}");
}

#[cfg(not(debug_assertions))]
#[test]
fn release_records_no_inversion() {
    let (sender, receiver) = mpsc::channel();
    produce(ThreadQos::Utility, sender, 1);
    let line = on(ThreadQos::UserInteractive, move || {
        let line = line!() + 1;
        receiver.recv().expect("recv");
        line
    });
    assert_eq!(inversions_at(line), None);
}

#[cfg(feature = "crossbeam")]
mod crossbeam {
    use super::{inversions_at, on};
    use crate::ThreadQos;
    use crate::sync::crossbeam;

    fn produce(qos: ThreadQos, sender: crossbeam::Sender<u32>, count: u32) {
        on(qos, move || {
            for value in 0..count {
                sender.send(value).expect("send");
            }
        });
    }

    #[cfg(debug_assertions)]
    #[test]
    fn a_user_interactive_receiver_of_a_utility_producer_records_one_site() {
        let (sender, receiver) = crossbeam::unbounded();
        produce(ThreadQos::Utility, sender, 2);
        let line = on(ThreadQos::UserInteractive, move || {
            let line = line!() + 1;
            for value in &receiver {
                assert!(value < 2);
            }
            line
        });
        assert_eq!(inversions_at(line), Some(2));
    }

    #[test]
    fn equal_qos_records_nothing() {
        let (sender, receiver) = crossbeam::bounded(2);
        produce(ThreadQos::UserInitiated, sender, 2);
        let line = on(ThreadQos::UserInitiated, move || {
            let line = line!() + 1;
            let values: Vec<u32> = receiver.iter().collect();
            assert_eq!(values, [0, 1]);
            line
        });
        assert_eq!(inversions_at(line), None);
    }

    #[test]
    fn failed_sends_hand_the_value_back() {
        let (sender, receiver) = crossbeam::bounded::<u32>(1);
        sender.try_send(1).expect("room for one");
        assert_eq!(sender.try_send(2), Err(crossbeam::TrySendError::Full(2)));
        assert_eq!(sender.len(), 1);
        drop(receiver);
        assert_eq!(sender.send(3), Err(crossbeam::SendError(3)));
    }
}
