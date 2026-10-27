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

pub(crate) type Watcher = (u64, Arc<dyn Fn() + Send + Sync>);

/// A copy-on-write list of commit watchers, kept under its owner's state
/// lock: a commit clones the list's `Arc` under the lock and runs it after
/// releasing it ([`run_watchers`]). The journal epoch and the shared journal
/// fan-out (`JournalKernel`, p05-ipc-147) each hold one.
#[derive(Default)]
pub(crate) struct CommitWatchers {
    next: u64,
    list: Arc<Vec<Watcher>>,
}

impl CommitWatchers {
    fn add(&mut self, watcher: impl Fn() + Send + Sync + 'static) -> u64 {
        let id = self.next;
        self.next += 1;
        let mut list = Vec::clone(&self.list);
        list.push((id, Arc::new(watcher)));
        self.list = Arc::new(list);
        id
    }

    /// Removes watcher `id`; the caller drops it outside its lock.
    pub(crate) fn remove(&mut self, id: u64) -> Option<Watcher> {
        let mut list = Vec::clone(&self.list);
        let removed = list
            .iter()
            .position(|(watcher, _)| *watcher == id)
            .map(|index| list.swap_remove(index));
        self.list = Arc::new(list);
        removed
    }

    /// The list a commit runs once its lock is released.
    pub(crate) fn snapshot(&self) -> Arc<Vec<Watcher>> {
        self.list.clone()
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.list.len()
    }
}

/// Runs a [`CommitWatchers::snapshot`]; never under its owner's lock.
pub(crate) fn run_watchers(watchers: &[Watcher]) {
    for (_, watcher) in watchers {
        watcher();
    }
}

/// The owner of a [`CommitWatchers`]: what a [`JournalWatch`] removes its
/// watcher from.
pub(crate) trait WatcherOwner: Send + Sync {
    /// Runs `f` on the owner's list under its state lock.
    fn with_watchers<R>(&self, f: impl FnOnce(&mut CommitWatchers) -> R) -> R
    where
        Self: Sized;
    /// Removes watcher `id` and returns it, to drop outside the lock.
    fn unwatch(&self, id: u64) -> Option<Watcher>;
}

/// Registers `watcher` on `owner` until the returned watch drops.
pub(crate) fn watch_on<O: WatcherOwner + 'static>(
    owner: &Arc<O>,
    watcher: impl Fn() + Send + Sync + 'static,
) -> JournalWatch {
    let id = owner.with_watchers(|watchers| watchers.add(watcher));
    let owner: Weak<O> = Arc::downgrade(owner);
    let owner: Weak<dyn WatcherOwner> = owner;
    JournalWatch { owner, id }
}

#[derive(Default)]
struct EpochState {
    epoch: u64,
    watchers: CommitWatchers,
}

#[derive(Default)]
struct Inner {
    state: Mutex<EpochState>,
    changed: Condvar,
}

impl WatcherOwner for Inner {
    fn with_watchers<R>(&self, f: impl FnOnce(&mut CommitWatchers) -> R) -> R {
        f(&mut self.state.lock().recover_poison().watchers)
    }

    fn unwatch(&self, id: u64) -> Option<Watcher> {
        self.with_watchers(|watchers| watchers.remove(id))
    }
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
            state.watchers.snapshot()
        };
        run_watchers(&watchers);
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
        watch_on(&self.0, watcher)
    }

    #[cfg(test)]
    pub(crate) fn watcher_count(&self) -> usize {
        self.lock().watchers.len()
    }
}

/// A registered commit watcher; dropping it removes the watcher.
pub(crate) struct JournalWatch {
    owner: Weak<dyn WatcherOwner>,
    id: u64,
}

impl Drop for JournalWatch {
    fn drop(&mut self) {
        let Some(owner) = self.owner.upgrade() else { return };
        // The watcher's captures drop outside the lock.
        drop(owner.unwatch(self.id));
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
