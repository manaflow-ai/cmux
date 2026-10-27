//! Session mutations leave the echo thread (Lawrence 2026-10-27: "we need
//! resize tests, for both windows, and panes too"; a divider drag in the TUI
//! panicked `mux-pty-input` in debug builds).

use super::*;

/// A session mutation is blocking work: for a local session it commits the
/// layout to the workspace registry (SQLite), for a remote one it waits for
/// the daemon's reply. A divider drag sends one per drag event
/// (`set_split_ratio_in_transaction`); on `mux-pty-input`, an echo thread
/// with blocking disallowed, each one was a detector violation (a panic in
/// debug builds, a key echo stuck behind a disk commit in release). It runs
/// on a thread that may block, still in queue order: after the input before
/// it, before the input after it.
#[test]
fn session_mutations_run_off_the_echo_thread_in_queue_order() {
    let dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let (order_tx, order_rx) = std::sync::mpsc::channel();
    let before_tx = order_tx.clone();
    let mut before = event(41, 1, PtyInputKind::Ordered);
    before.after_operation = Some(Box::new(move || before_tx.send(("before", None)).unwrap()));
    assert_eq!(sender.enqueue(before), PtyInputEnqueueResult::Accepted);
    let mutation_tx = order_tx.clone();
    sender.enqueue_session_mutation("set split ratio", false, move || {
        let thread = std::thread::current().name().unwrap_or("<unnamed>").to_owned();
        let blocking_disallowed = cmux_threads::blocking::is_blocking_disallowed();
        mutation_tx.send(("mutation", Some((thread, blocking_disallowed)))).unwrap();
        Ok(())
    });
    let mut after = event(43, 2, PtyInputKind::Ordered);
    after.after_operation = Some(Box::new(move || order_tx.send(("after", None)).unwrap()));
    assert_eq!(sender.enqueue(after), PtyInputEnqueueResult::Accepted);

    let wait = || order_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(wait().0, "before");
    let (step, ran_on) = wait();
    assert_eq!(step, "mutation", "input overtook the session mutation");
    let (thread, blocking_disallowed) = ran_on.unwrap();
    assert!(
        !blocking_disallowed,
        "the session mutation ran on '{thread}', which disallows blocking"
    );
    assert_ne!(thread, "mux-pty-input", "the session mutation ran on the echo thread");
    assert_eq!(wait().0, "after");
}

/// Shutdown drains a queued session mutation and joins both threads.
#[test]
fn shutdown_drains_a_queued_session_mutation() {
    let mut dispatcher = PtyInputDispatcher::spawn(|_| {}).unwrap();
    let sender = dispatcher.sender();
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    sender.enqueue_session_mutation("close pane", false, move || {
        std::thread::sleep(Duration::from_millis(50));
        done_tx.send(()).unwrap();
        Ok(())
    });
    assert!(dispatcher.shutdown(Duration::from_secs(5)), "the queue did not drain");
    done_rx.try_recv().expect("shutdown returned before the session mutation ran");
}
