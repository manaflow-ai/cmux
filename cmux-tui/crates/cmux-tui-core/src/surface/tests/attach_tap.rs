//! Attach tap queue tests.

use super::*;

#[test]
fn attach_tap_overflow_cancels_the_shared_lifecycle_once() {
    let lifecycle = AttachLifecycle::default();
    let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 1, usize::MAX);

    assert!(tap.try_send(AttachFrame::ColorsChanged(Arc::new(TerminalColors::default()))));
    assert!(!tap.try_send(AttachFrame::ColorsChanged(Arc::new(TerminalColors::default()))));
    assert!(lifecycle.is_canceled());
    assert!(lifecycle.overflowed());
    assert!(lifecycle.claim_overflow_report());
    assert!(!lifecycle.claim_overflow_report());
}

#[test]
fn attach_tap_overflow_is_bounded_by_retained_bytes() {
    let lifecycle = AttachLifecycle::default();
    let frame_bytes = AttachFrame::Output(vec![1]).retained_bytes();
    let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 4, frame_bytes);

    assert!(tap.try_send(AttachFrame::Output(vec![1])));
    assert!(!tap.try_send(AttachFrame::Output(vec![2])));
    assert!(lifecycle.overflowed());
}

/// A tap whose receiver is gone cancels the attachment, and cancel fires the
/// attachment's interrupts. The receiver's interrupt waker locks the same
/// queue, so canceling while holding the queue lock deadlocked the sender
/// (the window between the receiver marking itself gone and its own cancel).
#[test]
fn attach_tap_cancels_without_holding_its_queue_lock() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::pair(lifecycle.clone(), 4, usize::MAX);
    let interrupt = crate::stream_interrupt::StreamInterrupt::new();
    receiver.wake_on(&interrupt);
    lifecycle.register_interrupt(&interrupt);
    // The receiver has marked itself gone but has not canceled yet.
    tap.state.queue.lock().unwrap().receiver_alive = false;
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let sent = tap.try_send(AttachFrame::Output(vec![1]));
        let _ = done_tx.send(sent);
    });
    let Ok(sent) = done_rx.recv_timeout(Duration::from_secs(2)) else {
        // Dropping the receiver locks the queue the stuck thread holds.
        std::mem::forget(receiver);
        panic!("try_send deadlocked on its own queue lock while canceling");
    };
    assert!(!sent);
    assert!(lifecycle.is_canceled());
    drop(receiver);
}
