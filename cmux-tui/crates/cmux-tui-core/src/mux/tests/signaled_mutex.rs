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

/// The (caller class, op) row of `lock` in `debug-daemon-locks`, ops named
/// `op<index>`.
fn lock_row(
    mux: &Mux,
    lock: &str,
    caller: crate::diagnostics::LockCaller,
    op: crate::diagnostics::LockOp,
) -> Option<crate::diagnostics::OpLockSnapshot> {
    let (name, table) = mux.daemon_lock_tables().into_iter().find(|(name, _)| *name == lock)?;
    let snapshot = table.snapshot(name, &|op| format!("op{}", op.0));
    let op = format!("op{}", op.0);
    snapshot.ops.into_iter().find(|row| row.caller == caller.wire_name() && row.op == op)
}

/// Takes `lock` ("mux.state" or "workspace.registry") of `mux` and runs
/// `while_held` with it held.
fn with_daemon_lock(mux: &Mux, lock: &str, while_held: impl FnOnce()) {
    if lock == "mux.state" {
        let _state = mux.state.lock().unwrap();
        while_held();
    } else {
        let _registry = mux.workspace_registry.lock().unwrap();
        while_held();
    }
}

/// p06-scheduler-226 acceptance: an automation request that holds a daemon
/// lock for 5 ms shows in its op's hold histogram, and a frontend request
/// that waits behind it shows in its own op's wait histogram. The holder
/// starts its 5 ms only once the frontend is blocked on the lock.
#[test]
fn signaled_mutex_daemon_locks_attribute_a_forced_automation_hold() {
    use crate::diagnostics::{LockCaller, LockCallerScope, LockOp, LockOpScope, on_contended_lock};
    const AUTOMATION_OP: LockOp = LockOp(7);
    const FRONTEND_OP: LockOp = LockOp(9);
    for lock in ["mux.state", "workspace.registry"] {
        let mux = test_mux();
        let (waiting_tx, waiting_rx) = std::sync::mpsc::channel::<()>();
        let mut waiter = None;
        {
            let _caller = LockCallerScope::enter(LockCaller::Automation);
            let _op = LockOpScope::enter(AUTOMATION_OP);
            with_daemon_lock(&mux, lock, || {
                let waiter_mux = mux.clone();
                waiter = Some(std::thread::spawn(move || {
                    on_contended_lock(move || waiting_tx.send(()).unwrap());
                    let _caller = LockCallerScope::enter(LockCaller::Frontend);
                    let _op = LockOpScope::enter(FRONTEND_OP);
                    with_daemon_lock(&waiter_mux, lock, || {});
                }));
                waiting_rx.recv().unwrap();
                std::thread::sleep(Duration::from_millis(5));
            });
        }
        waiter.expect("the waiter started").join().unwrap();

        let hold = lock_row(&mux, lock, LockCaller::Automation, AUTOMATION_OP)
            .unwrap_or_else(|| panic!("{lock}: the automation op has a row"));
        assert_eq!(hold.hold_us.count, 1, "{lock}: {hold:?}");
        assert!(hold.hold_us.max >= 5_000, "{lock}: {hold:?}");
        let wait = lock_row(&mux, lock, LockCaller::Frontend, FRONTEND_OP)
            .unwrap_or_else(|| panic!("{lock}: the frontend op has a row"));
        assert_eq!(wait.wait_us.count, 1, "{lock}: {wait:?}");
        // The frontend's wait began before the holder's 5 ms.
        assert!(wait.wait_us.max >= 5_000, "{lock}: {wait:?}");
        assert!(
            lock_row(&mux, lock, LockCaller::Frontend, AUTOMATION_OP).is_none(),
            "{lock}: the hold is the automation op's only"
        );
    }
}

/// A free lock costs two clock reads: its acquisition and its release (its
/// wait is zero, read from no clock).
#[test]
fn signaled_mutex_daemon_locks_read_the_clock_twice_per_free_acquisition() {
    use crate::diagnostics::lock_clock_reads;
    let mutex = SignaledMutex::new(0u32);
    let before = lock_clock_reads();
    drop(mutex.lock().unwrap());
    assert_eq!(lock_clock_reads() - before, 2);
    let state = test_mux().state.lock().unwrap().clone();
    let state = crate::mux::signaled_mutex::StateMutex::new(state);
    let before = lock_clock_reads();
    drop(state.lock().unwrap());
    assert_eq!(lock_clock_reads() - before, 2);
}
