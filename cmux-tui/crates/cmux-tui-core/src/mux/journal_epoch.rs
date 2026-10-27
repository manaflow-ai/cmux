//! The journal's wake-only commit signal: an epoch every commit raises,
//! the threads that wait for it, and the watchers that a commit runs
//! instead of waking a thread (a `session.events` drain on `Mux::work`,
//! p05-ipc-146). Consumers always reread SQLite by cursor, so a missed or
//! coalesced wake is safe.
//!
//! A watcher is Chrome's observer of a commit: the observer list is copied
//! on write and run with the lock released (base/observer_list_threadsafe.h
//! posts each notification instead of calling it under the list's lock), so
//! a commit pays one `Arc` clone while nobody watches.

use cmux_threads::sync::{Condvar, Mutex, MutexGuard};
use std::sync::{Arc, Weak};

use crate::panic_free::RecoverPoison;
use crate::stream_interrupt::StreamInterrupt;

type Watcher = (u64, Arc<dyn Fn() + Send + Sync>);

#[derive(Default)]
struct EpochState {
    epoch: u64,
    next_watcher: u64,
    watchers: Arc<Vec<Watcher>>,
}

#[derive(Default)]
struct Inner {
    state: Mutex<EpochState>,
    changed: Condvar,
}

/// The mux's journal commit epoch.
#[derive(Default)]
pub(crate) struct JournalEpoch(Arc<Inner>);

impl JournalEpoch {
    fn lock(&self) -> MutexGuard<'_, EpochState> {
        self.0.state.lock().recover_poison()
    }

    /// Raises the epoch, wakes its waiters and runs its watchers, outside
    /// the lock.
    pub(crate) fn publish(&self) {
        let watchers = {
            let mut state = self.lock();
            state.epoch = state.epoch.wrapping_add(1);
            self.0.changed.notify_all();
            state.watchers.clone()
        };
        for (_, watcher) in watchers.iter() {
            watcher();
        }
    }

    pub(crate) fn current(&self) -> u64 {
        self.lock().epoch
    }

    /// The epoch once it differs from `epoch`, or `epoch` after `timeout`.
    #[cfg(test)]
    pub(crate) fn wait_timeout(&self, epoch: u64, timeout: std::time::Duration) -> u64 {
        let state = self.lock();
        if state.epoch != epoch {
            return state.epoch;
        }
        let (state, _) = self.0.changed.wait_timeout(state, timeout).recover_poison();
        state.epoch
    }

    /// The epoch once it differs from `epoch`, or `epoch` once `interrupt`
    /// has fired. No timeout.
    pub(crate) fn wait_until_interrupted(&self, epoch: u64, interrupt: &StreamInterrupt) -> u64 {
        let mut state = self.lock();
        while state.epoch == epoch && !interrupt.is_fired() {
            state = cmux_threads::checked::sync::wait(&self.0.changed, state).recover_poison();
        }
        state.epoch
    }

    /// Wakes every waiter so it rereads the interrupt it waits with.
    pub(crate) fn notify_waiters(&self) {
        let _state = self.lock();
        self.0.changed.notify_all();
    }

    /// Runs `watcher` after each commit until the returned watch drops.
    pub(crate) fn watch(&self, watcher: impl Fn() + Send + Sync + 'static) -> JournalWatch {
        let mut state = self.lock();
        let id = state.next_watcher;
        state.next_watcher += 1;
        let mut watchers = Vec::clone(&state.watchers);
        watchers.push((id, Arc::new(watcher)));
        state.watchers = Arc::new(watchers);
        JournalWatch { epoch: Arc::downgrade(&self.0), id }
    }

    #[cfg(test)]
    pub(crate) fn watcher_count(&self) -> usize {
        self.lock().watchers.len()
    }
}

/// A registered commit watcher; dropping it removes the watcher.
pub(crate) struct JournalWatch {
    epoch: Weak<Inner>,
    id: u64,
}

impl Drop for JournalWatch {
    fn drop(&mut self) {
        let Some(inner) = self.epoch.upgrade() else { return };
        let removed = {
            let mut state = inner.state.lock().recover_poison();
            let mut watchers = Vec::clone(&state.watchers);
            let removed = watchers
                .iter()
                .position(|(id, _)| *id == self.id)
                .map(|index| watchers.swap_remove(index));
            state.watchers = Arc::new(watchers);
            removed
        };
        // The watcher's captures drop outside the lock.
        drop(removed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn a_watcher_runs_on_each_commit_until_its_watch_drops() {
        let epoch = JournalEpoch::default();
        let runs = Arc::new(AtomicUsize::new(0));
        let counted = runs.clone();
        let watch = epoch.watch(move || {
            counted.fetch_add(1, Ordering::SeqCst);
        });
        epoch.publish();
        epoch.publish();
        assert_eq!(runs.load(Ordering::SeqCst), 2);
        assert_eq!(epoch.current(), 2);
        drop(watch);
        assert_eq!(epoch.watcher_count(), 0);
        epoch.publish();
        assert_eq!(runs.load(Ordering::SeqCst), 2, "a dropped watch still ran");
    }

    #[test]
    fn a_watcher_may_publish_again_and_drop_another_watch() {
        // Watchers run with the lock released: one that commits again
        // (or drops a watch) does not deadlock.
        let epoch = Arc::new(JournalEpoch::default());
        let other = Arc::new(Mutex::new(Some(epoch.watch(|| {}))));
        let (again, dropped) = (epoch.clone(), other);
        let _watch = epoch.watch(move || {
            dropped.lock().recover_poison().take();
            if again.current() < 2 {
                again.publish();
            }
        });
        epoch.publish();
        assert_eq!(epoch.current(), 2);
        assert_eq!(epoch.watcher_count(), 1);
    }
}
