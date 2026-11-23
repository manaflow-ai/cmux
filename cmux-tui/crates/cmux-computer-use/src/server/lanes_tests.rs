use super::*;
use std::sync::mpsc;
use std::time::Duration;

#[test]
fn stop_waits_for_the_running_call() {
    let lanes = Lanes::new();
    let (started_tx, started_rx) = mpsc::channel::<()>();
    let finished = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let done = Arc::clone(&finished);
    lanes.submit("a", move || {
        started_tx.send(()).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        done.store(true, std::sync::atomic::Ordering::SeqCst);
    });
    started_rx.recv().unwrap();
    lanes.stop();
    assert!(finished.load(std::sync::atomic::Ordering::SeqCst), "stop returned mid-call");
}

#[test]
fn one_session_runs_in_order_and_others_are_not_blocked() {
    let lanes = Lanes::new();
    let (gate_tx, gate_rx) = mpsc::channel::<()>();
    let (done_tx, done_rx) = mpsc::channel::<String>();
    let gate = Mutex::new(gate_rx);
    let slow_done = done_tx.clone();
    lanes.submit("a", move || {
        gate.lock().unwrap().recv().unwrap();
        slow_done.send("a1".into()).unwrap();
    });
    let a2 = done_tx.clone();
    lanes.submit("a", move || a2.send("a2".into()).unwrap());
    let b1 = done_tx;
    lanes.submit("b", move || b1.send("b1".into()).unwrap());
    // b runs while a's first job is still blocked.
    assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "b1");
    gate_tx.send(()).unwrap();
    assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "a1");
    assert_eq!(done_rx.recv_timeout(Duration::from_secs(5)).unwrap(), "a2");
    lanes.stop();
}

#[test]
fn a_panicking_job_does_not_stop_its_lane() {
    let lanes = Lanes::new();
    let (tx, rx) = mpsc::channel::<u8>();
    lanes.submit("s", || panic!("boom"));
    lanes.submit("s", move || tx.send(7).unwrap());
    assert_eq!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), 7);
    lanes.stop();
}
