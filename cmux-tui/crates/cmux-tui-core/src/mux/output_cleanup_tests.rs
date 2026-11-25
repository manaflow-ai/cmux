use super::*;

fn worker_blocked_on(lock: Arc<Mutex<()>>) -> OutputCleanupWorker {
    let control = Arc::new(Control { stopped: Mutex::new(false), changed: Condvar::new() });
    let (exited_sender, exited) = std::sync::mpsc::channel::<()>();
    let thread = std::thread::spawn(move || {
        let _exited = exited_sender;
        // The final record waits on a lock a stalled journal commit holds.
        drop(lock.lock().unwrap_or_else(PoisonError::into_inner));
    });
    OutputCleanupWorker { control, thread: Some(thread), exited }
}

#[test]
fn a_stop_returns_while_the_worker_waits_on_a_held_registry_lock() {
    let lock = Arc::new(Mutex::new(()));
    let held = lock.lock().unwrap();
    let worker = worker_blocked_on(lock.clone());
    let started = Instant::now();
    worker.stop(Duration::from_millis(200));
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "a stop waited without a limit for a worker blocked on the registry lock"
    );
    drop(held);
}

/// Without the opt-in the owner schedules what it did before the
/// compaction existed: the output cleanup while that is not done, and
/// nothing after. The compaction is scheduled only with the opt-in, once.
#[test]
fn the_journal_compaction_is_scheduled_only_with_the_opt_in() {
    use journal_compact::{requested, scheduled_mode};
    use std::ffi::OsStr;
    assert!(!requested(None), "the compaction is on without its variable");
    for value in ["", "0", "true", "yes", "2"] {
        assert!(!requested(Some(OsStr::new(value))), "{value:?} turns the compaction on");
    }
    assert!(requested(Some(OsStr::new("1"))));
    for compact_done in [false, true] {
        assert_eq!(scheduled_mode(false, compact_done, true), None);
        assert_eq!(scheduled_mode(false, compact_done, false), Some(CleanupMode::Output));
    }
    assert_eq!(scheduled_mode(true, false, true), Some(CleanupMode::Compact));
    assert_eq!(scheduled_mode(true, false, false), Some(CleanupMode::Compact));
    assert_eq!(scheduled_mode(true, true, true), None, "the compaction runs once");
    assert_eq!(scheduled_mode(true, true, false), Some(CleanupMode::Output));
}

#[test]
fn a_stop_joins_a_worker_that_ends() {
    let worker = worker_blocked_on(Arc::new(Mutex::new(())));
    worker.stop(Duration::from_secs(5));
}
