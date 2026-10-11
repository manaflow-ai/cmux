//! SignaledMutex hold and wait telemetry.

use super::*;

#[test]
fn signaled_mutex_records_holder_site_wait_and_hold() {
    let mutex = SignaledMutex::new(0u32);
    assert!(mutex.stats().snapshot().holder.is_none());
    {
        let lock_line = line!() + 1;
        let mut guard = mutex.lock().unwrap();
        *guard += 1;
        let snapshot = mutex.stats().snapshot();
        let holder = snapshot.holder.expect("held lock reports its holder");
        assert!(
            holder.site.ends_with(&format!("signaled_mutex.rs:{lock_line}")),
            "{}",
            holder.site
        );
    }
    let snapshot = mutex.stats().snapshot();
    assert!(snapshot.holder.is_none());
    assert_eq!(snapshot.hold_us.count, 1);
    assert_eq!(snapshot.wait_us.count, 1);
    assert_eq!(snapshot.top_sites.len(), 1);
    assert_eq!(snapshot.top_sites[0].acquisitions, 1);

    // A waiter that outlasts the stall threshold names the site that
    // held the lock when its wait began.
    let mutex = Arc::new(SignaledMutex::new(0u32));
    let held = mutex.clone();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
    let holder = std::thread::spawn(move || {
        let _guard = held.lock().unwrap();
        held_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    held_rx.recv().unwrap();
    let waiter = mutex.clone();
    let waiting = std::thread::spawn(move || {
        let _guard = waiter.lock_until(Instant::now() + Duration::from_secs(5)).unwrap();
    });
    std::thread::sleep(crate::diagnostics::LOCK_STALL_THRESHOLD + Duration::from_millis(20));
    release_tx.send(()).unwrap();
    holder.join().unwrap();
    waiting.join().unwrap();
    let snapshot = mutex.stats().snapshot();
    assert_eq!(snapshot.stalls, 1, "{snapshot:?}");
    let stall = snapshot.last_stall.expect("stall recorded");
    assert!(
        stall.blocker.as_deref().is_some_and(|site| site.contains("signaled_mutex.rs:")),
        "{stall:?}"
    );
    assert!(stall.waited_us >= 100_000);
}

#[test]
fn signaled_mutex_records_failed_wait_telemetry() {
    let mutex = Arc::new(SignaledMutex::new(0u32));
    let held = mutex.clone();
    let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
    let (held_tx, held_rx) = std::sync::mpsc::channel::<()>();
    let holder = std::thread::spawn(move || {
        let _guard = held.lock().unwrap();
        held_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    held_rx.recv().unwrap();

    let deadline =
        Instant::now() + crate::diagnostics::LOCK_STALL_THRESHOLD + Duration::from_millis(20);
    assert!(mutex.lock_until(deadline).is_err());
    release_tx.send(()).unwrap();
    holder.join().unwrap();

    let snapshot = mutex.stats().snapshot();
    assert_eq!(snapshot.wait_us.count, 2, "failed wait must enter wait histogram");
    assert_eq!(snapshot.hold_us.count, 1, "failed wait must not report a hold");
    assert_eq!(snapshot.stalls, 1, "failed stall must be visible");
    assert!(snapshot.last_stall.is_some());
}
