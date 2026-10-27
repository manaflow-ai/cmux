//! Timed receives and completion waits block until their event or their one
//! deadline (p14-energy-077g): no re-check period.

use super::*;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

#[test]
fn attach_recv_timeout_times_out_once_at_its_deadline() {
    let (_tap, receiver) = AttachTap::pair(AttachLifecycle::default(), 4, usize::MAX);
    let started = Instant::now();
    assert!(matches!(
        receiver.recv_timeout(Duration::from_millis(30)),
        Err(RecvTimeoutError::Timeout)
    ));
    assert!(started.elapsed() >= Duration::from_millis(30), "timed out before its deadline");
}

#[test]
fn attach_recv_timeout_wakes_on_a_frame() {
    let (tap, receiver) = AttachTap::pair(AttachLifecycle::default(), 4, usize::MAX);
    let sender = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(20));
        assert!(tap.try_send(AttachFrame::Output(vec![7].into())));
        tap
    });
    let started = Instant::now();
    // A timeout past the clock's range waits with no deadline.
    let frame = receiver.recv_timeout(Duration::MAX).expect("the frame wakes the receiver");
    assert!(started.elapsed() < Duration::from_secs(5), "receiver waited past the frame");
    assert!(matches!(frame, AttachFrame::Output(_)));
    drop(sender.join().unwrap());
}

#[test]
fn attach_recv_timeout_wakes_on_the_senders_drop() {
    let (tap, receiver) = AttachTap::pair(AttachLifecycle::default(), 4, usize::MAX);
    let sender = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(20));
        drop(tap);
    });
    let started = Instant::now();
    assert!(matches!(
        receiver.recv_timeout(Duration::from_secs(30)),
        Err(RecvTimeoutError::Disconnected)
    ));
    assert!(started.elapsed() < Duration::from_secs(5), "receiver waited past the drop");
    sender.join().unwrap();
}

#[test]
fn reader_completion_wait_ends_on_complete_or_its_deadline() {
    let completion = Arc::new(ReaderCompletion::default());
    let started = Instant::now();
    assert!(!completion.wait_until(started + Duration::from_millis(30)));
    assert!(started.elapsed() >= Duration::from_millis(30), "gave up before its deadline");
    assert!(!completion.wait_until(Instant::now()));

    let completer = completion.clone();
    let complete = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(20));
        completer.complete();
    });
    let started = Instant::now();
    assert!(completion.wait_until(Instant::now() + Duration::from_secs(30)));
    assert!(started.elapsed() < Duration::from_secs(5), "waited past the completion");
    complete.join().unwrap();
    // Already complete: no wait, even with the deadline gone.
    assert!(completion.wait_until(Instant::now()));
}
