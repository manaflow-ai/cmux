use super::*;
use std::sync::mpsc;

/// Real time only bounds how long the test waits for the timer thread.
const SAFETY_BOUND: Duration = Duration::from_secs(30);

#[test]
fn jobs_run_in_deadline_order_and_cancelled_ones_never_run() {
    let timers = Timers::default();
    // The first job holds the timer thread until every job is scheduled
    // and the cancel is in, so no deadline can pass ahead of the cancel.
    let (open_gate, gate) = mpsc::channel::<()>();
    timers.schedule(Duration::ZERO, move || {
        let _ = gate.recv();
    });
    let (tx, rx) = mpsc::channel();
    let t = tx.clone();
    timers.schedule(Duration::from_millis(40), move || t.send(2).unwrap());
    let t = tx.clone();
    let cancelled = timers.schedule(Duration::from_millis(10), move || t.send(9).unwrap());
    timers.schedule(Duration::from_millis(20), move || tx.send(1).unwrap());
    timers.cancel(cancelled);
    drop(open_gate);
    assert_eq!(rx.recv_timeout(SAFETY_BOUND).unwrap(), 1);
    assert_eq!(rx.recv_timeout(SAFETY_BOUND).unwrap(), 2);
    // Every job that held a sender has run or was dropped by the cancel.
    assert_eq!(rx.recv_timeout(SAFETY_BOUND), Err(mpsc::RecvTimeoutError::Disconnected));
    timers.stop();
}
