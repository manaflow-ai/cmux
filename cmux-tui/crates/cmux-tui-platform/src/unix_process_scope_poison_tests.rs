//! A process scope and its tracker are used again after a panic in another holder.

use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use super::{ProcessScopeTracker, UnixProcessScope};

/// Panics in another thread while it holds `lock`, which poisons it.
fn poison<T: Send + 'static>(lock: Arc<Mutex<T>>) {
    let panicked = std::thread::spawn(move || {
        let _guard = lock.lock().unwrap();
        panic!("a holder panics with the lock held");
    })
    .join();
    assert!(panicked.is_err());
}

#[test]
fn a_scope_whose_tracked_set_was_poisoned_still_terminates_and_closes_admission() {
    let mut scope = UnixProcessScope::prepare().unwrap();
    poison(Arc::clone(&scope.tracked));
    assert!(scope.tracked.is_poisoned());
    scope.terminate();
    assert!(!scope.tracked.lock().unwrap_or_else(PoisonError::into_inner).active);
}

#[test]
fn a_tracker_whose_state_was_poisoned_still_finalizes() {
    // A private tracker (never started), so no other test shares its poisoned lock.
    let tracker = Arc::new(ProcessScopeTracker::default());
    let held = Arc::clone(&tracker);
    let panicked = std::thread::spawn(move || {
        let _state = held.state.lock().unwrap();
        panic!("a holder panics with the tracker state locked");
    })
    .join();
    assert!(panicked.is_err() && tracker.state.is_poisoned());
    // An unknown registration has nothing left to finalize: it returns at once.
    let started = Instant::now();
    tracker.finalize(7, Instant::now() + Duration::from_secs(5));
    assert!(started.elapsed() < Duration::from_secs(1));
    let state = tracker.state.lock().unwrap_or_else(PoisonError::into_inner);
    assert!(state.scopes.is_empty() && state.finalizing.is_empty());
}
