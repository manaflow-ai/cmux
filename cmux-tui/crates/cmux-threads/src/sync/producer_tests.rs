//! A channel waiter boosts its producer: each test reads its own channel's
//! counts, since the process counts move with every test running in parallel.

use std::sync::mpsc as std_mpsc;
use std::time::Duration;

use super::ProducerBoosts;
use crate::ThreadQos;
use crate::sync::mpsc;

/// A wait the producer cannot answer: it sent once and sends no more.
const SHORT_WAIT: Duration = Duration::from_millis(20);

/// Runs `f` on a registered thread at `qos` and returns its result.
fn on<R: Send + 'static>(qos: ThreadQos, f: impl FnOnce() -> R + Send + 'static) -> R {
    crate::spawn("producer-boost-test", qos, f).expect("spawn").join().expect("test thread")
}

/// A producer at `qos` that runs `send` once, then stays registered and
/// holds `sender` until the returned sender fires. Returns what `send`
/// returned once it returned, so the message is queued before any consumer
/// starts: a consumer's first receive takes it without a wait. A panic in
/// `send` fails the caller with the producer's own message.
fn live_producer<S: Send + 'static, T: Send + 'static>(
    qos: ThreadQos,
    sender: S,
    send: fn(&S) -> T,
) -> (T, std_mpsc::Sender<()>, std::thread::JoinHandle<()>) {
    let (done, finished) = std_mpsc::channel();
    let (sent_tx, sent_rx) = std_mpsc::channel();
    let thread = crate::spawn("producer-boost-producer", qos, move || {
        sent_tx.send(send(&sender)).expect("the test waits for the send");
        finished.recv().expect("the test ends the producer");
    })
    .expect("spawn producer");
    match sent_rx.recv() {
        Ok(sent) => (sent, done, thread),
        Err(_) => match thread.join() {
            Err(panic) => std::panic::resume_unwind(panic),
            Ok(()) => unreachable!("the producer reports its send before it returns"),
        },
    }
}

fn send_zero(sender: &mpsc::Sender<u32>) {
    sender.send(0).expect("send");
}

/// What one wait on a lower, live producer counts: an override started and
/// ended where the platform boosts (macOS), a counted wait on Linux.
fn one_boosted_wait() -> ProducerBoosts {
    if super::boost::ENDS_AFTER_TARGET_EXITS {
        ProducerBoosts { started: 1, ended: 1, unboosted: 0 }
    } else {
        ProducerBoosts { started: 0, ended: 0, unboosted: 1 }
    }
}

/// The consumer at `qos` takes the producer's message, waits once for one
/// that never comes, and returns the channel's counts.
fn wait_once(qos: ThreadQos, producer: ThreadQos) -> ProducerBoosts {
    wait_once_after(qos, producer, send_zero).1
}

/// [`wait_once`] on a producer whose first message is sent by `send`; also
/// returns what `send` returned.
fn wait_once_after<T: Send + 'static>(
    qos: ThreadQos,
    producer: ThreadQos,
    send: fn(&mpsc::Sender<u32>) -> T,
) -> (T, ProducerBoosts) {
    let (sender, receiver) = mpsc::channel();
    let (sent, done, thread) = live_producer(producer, sender, send);
    let counts = on(qos, move || {
        assert_eq!(receiver.recv(), Ok(0));
        assert_eq!(receiver.recv_timeout(SHORT_WAIT), Err(mpsc::RecvTimeoutError::Timeout));
        receiver.boosts()
    });
    done.send(()).expect("producer alive");
    thread.join().expect("producer");
    (sent, counts)
}

#[test]
fn a_user_interactive_wait_on_a_utility_producer_starts_and_ends_one_override() {
    let counts = wait_once(ThreadQos::UserInteractive, ThreadQos::Utility);
    assert_eq!(counts, one_boosted_wait());
    assert_eq!(counts.open(), 0);
}

/// The producer sends at the waiter's class and is demoted before the wait:
/// the wait reads the producer's class when it starts, not the one it sent
/// at, so it boosts the producer. Utility to Background raises the nice
/// value, which needs no privilege unless the runner is above nice 10; then
/// the demotion is refused and the producer stays at the waiter's class.
#[test]
fn a_wait_on_a_producer_demoted_after_its_send_boosts_it() {
    fn send_then_demote(sender: &mpsc::Sender<u32>) -> crate::QosChange {
        send_zero(sender);
        crate::set_current(ThreadQos::Background)
    }
    let (demoted, counts) =
        wait_once_after(ThreadQos::Utility, ThreadQos::Utility, send_then_demote);
    let expected = if demoted == crate::QosChange::Applied {
        one_boosted_wait()
    } else {
        ProducerBoosts::default()
    };
    assert_eq!(counts, expected, "demotion {demoted:?}");
    assert_eq!(counts.open(), 0);
}

#[test]
fn an_equal_or_lower_waiter_boosts_nothing() {
    for (consumer, producer) in [
        (ThreadQos::Utility, ThreadQos::Utility),
        (ThreadQos::UserInitiated, ThreadQos::UserInitiated),
        (ThreadQos::Utility, ThreadQos::UserInitiated),
    ] {
        assert_eq!(
            wait_once(consumer, producer),
            ProducerBoosts::default(),
            "{consumer} on {producer}"
        );
    }
}

#[test]
fn an_unregistered_waiter_boosts_nothing() {
    let (sender, receiver) = mpsc::channel();
    let ((), done, thread) = live_producer(ThreadQos::Utility, sender, send_zero);
    assert_eq!(receiver.recv(), Ok(0));
    assert_eq!(receiver.recv_timeout(SHORT_WAIT), Err(mpsc::RecvTimeoutError::Timeout));
    done.send(()).expect("producer alive");
    thread.join().expect("producer");
    assert_eq!(receiver.boosts(), ProducerBoosts::default());
}

#[test]
fn a_queued_message_is_taken_without_a_boost() {
    // The producer has exited, so a wait would count as unboosted.
    let (sender, receiver) = mpsc::sync_channel(2);
    on(ThreadQos::Utility, move || sender.send(1).expect("send"));
    let counts = on(ThreadQos::UserInteractive, move || {
        assert_eq!(receiver.recv(), Ok(1));
        receiver.boosts()
    });
    assert_eq!(counts, ProducerBoosts::default());
}

#[test]
fn a_wait_on_a_producer_that_exited_starts_no_override() {
    let (sender, receiver) = mpsc::channel();
    let kept = sender.clone();
    on(ThreadQos::Utility, move || send_zero(&sender));
    let counts = on(ThreadQos::UserInteractive, move || {
        assert_eq!(receiver.recv(), Ok(0));
        assert_eq!(receiver.recv_timeout(SHORT_WAIT), Err(mpsc::RecvTimeoutError::Timeout));
        receiver.boosts()
    });
    drop(kept);
    assert_eq!(counts, ProducerBoosts { started: 0, ended: 0, unboosted: 1 });
}

#[test]
fn a_disconnected_channel_ends_its_wait_with_no_override_open() {
    let (sender, receiver) = mpsc::channel::<u32>();
    let ((), done, thread) = live_producer(ThreadQos::Utility, sender, send_zero);
    let waiter = crate::spawn("producer-boost-waiter", ThreadQos::UserInteractive, move || {
        assert_eq!(receiver.recv(), Ok(0));
        // The producer drops the last sender while this waits.
        let ended = receiver.recv();
        (ended, receiver.boosts())
    })
    .expect("spawn waiter");
    done.send(()).expect("producer alive");
    thread.join().expect("producer");
    let (ended, counts) = waiter.join().expect("waiter");
    assert_eq!(ended, Err(mpsc::RecvError));
    assert_eq!(counts.open(), 0);
    assert!(counts.started <= 1 && counts.unboosted <= 1, "{counts:?}");
}

/// The producer runs at the waiter's class while the waiter waits, and at its
/// own once the wait ended.
#[cfg(target_vendor = "apple")]
#[test]
fn macos_the_producer_runs_at_the_waiters_class_during_the_wait() {
    use crate::qos::{LiveQos, current_effective};
    use std::time::Instant;

    let (sender, receiver) = mpsc::channel::<u32>();
    let (read_tx, read_rx) = std_mpsc::channel();
    let (sent_tx, sent_rx) = std_mpsc::channel();
    let producer = crate::spawn("producer-boost-producer", ThreadQos::Utility, move || {
        sender.send(0).expect("send");
        // 0 is queued before the consumer starts, so its first receive does
        // not wait: the only override is the wait for 1.
        sent_tx.send(()).expect("the test waits for the send");
        let deadline = Instant::now() + Duration::from_secs(10);
        while sender.boosts().started == 0 {
            assert!(Instant::now() < deadline, "the waiter never boosted the producer");
            std::thread::yield_now();
        }
        let during = current_effective();
        sender.send(1).expect("send");
        read_tx.send(during).expect("read");
    })
    .expect("spawn producer");
    sent_rx.recv().expect("the producer sends");
    let counts = on(ThreadQos::UserInteractive, move || {
        assert_eq!(receiver.recv(), Ok(0));
        assert_eq!(receiver.recv(), Ok(1));
        receiver.boosts()
    });
    producer.join().expect("producer");
    assert_eq!(read_rx.recv(), Ok(LiveQos::Class(ThreadQos::UserInteractive)));
    assert_eq!(counts, ProducerBoosts { started: 1, ended: 1, unboosted: 0 });
}

#[cfg(feature = "crossbeam")]
#[test]
fn crossbeam_a_user_interactive_wait_on_a_utility_producer_starts_and_ends_one_override() {
    use crate::sync::crossbeam;

    let (sender, receiver) = crossbeam::unbounded::<u32>();
    let ((), done, thread) = live_producer(ThreadQos::Utility, sender, |sender| {
        sender.send(0).expect("send");
    });
    let counts = on(ThreadQos::UserInteractive, move || {
        assert_eq!(receiver.recv(), Ok(0));
        assert_eq!(receiver.recv_timeout(SHORT_WAIT), Err(crossbeam::RecvTimeoutError::Timeout));
        receiver.boosts()
    });
    done.send(()).expect("producer alive");
    thread.join().expect("producer");
    assert_eq!(counts, one_boosted_wait());
}
