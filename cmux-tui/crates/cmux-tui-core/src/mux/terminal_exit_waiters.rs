//! Terminal exit waiter state: detach trackers and leases, exit waiter subscriptions, and the exit state query guard.

use super::*;

#[derive(Default)]
pub(super) struct TerminalExitDetachTracker {
    pub(super) active: Mutex<HashSet<String>>,
    pub(super) changed: Condvar,
}

impl TerminalExitDetachTracker {
    pub(super) fn acquire(
        self: &Arc<Self>,
        terminal_id: String,
    ) -> Option<TerminalExitDetachLease> {
        if !self.active.lock().unwrap().insert(terminal_id.clone()) {
            return None;
        }
        Some(TerminalExitDetachLease { tracker: self.clone(), terminal_id })
    }

    pub(super) fn finish(&self, terminal_id: &str) {
        let mut active = self.active.lock().unwrap();
        if active.remove(terminal_id) {
            self.changed.notify_all();
        }
    }

    #[cfg(test)]
    pub(super) fn contains(&self, terminal_id: &str) -> bool {
        self.active.lock().unwrap().contains(terminal_id)
    }

    #[cfg(test)]
    pub(super) fn wait_until_finished(&self, terminal_id: &str, deadline: Instant) -> bool {
        let mut active = self.active.lock().unwrap();
        while active.contains(terminal_id) {
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return false;
            };
            let (next, timeout) =
                cmux_threads::checked::sync::wait_timeout(&self.changed, active, remaining)
                    .unwrap();
            active = next;
            if timeout.timed_out() && active.contains(terminal_id) {
                return false;
            }
        }
        true
    }
}

pub(super) struct TerminalExitDetachLease {
    pub(super) tracker: Arc<TerminalExitDetachTracker>,
    pub(super) terminal_id: String,
}

impl Drop for TerminalExitDetachLease {
    fn drop(&mut self) {
        self.tracker.finish(&self.terminal_id);
    }
}

type ExitWaiterMap = HashMap<TerminalPublicId, HashMap<u64, Weak<ResourceWaitWake>>>;

#[derive(Default)]
pub(super) struct TerminalExitWaiters {
    pub(super) next_id: AtomicU64,
    /// Shared with detached subscriptions, which outlive a borrow of the mux.
    pub(super) waiters: Arc<Mutex<ExitWaiterMap>>,
}

/// A terminal-exit subscription that holds no borrow of the mux, so a
/// long-lived watcher waits without keeping the mux alive. A terminal exit
/// or the drop of the mux's waiter registry wakes it.
pub(crate) struct DetachedTerminalExitSubscription {
    waiters: Arc<Mutex<ExitWaiterMap>>,
    terminal_id: TerminalPublicId,
    waiter_id: u64,
    wake: Arc<ResourceWaitWake>,
}

pub(crate) struct TerminalExitSubscription<'a> {
    pub(super) owner: &'a TerminalExitWaiters,
    pub(super) terminal_id: TerminalPublicId,
    pub(super) waiter_id: u64,
    pub(super) wake: Arc<ResourceWaitWake>,
}

impl TerminalExitWaiters {
    pub(super) fn subscribe(&self, terminal_id: &TerminalPublicId) -> TerminalExitSubscription<'_> {
        let (waiter_id, wake) = self.register(terminal_id);
        TerminalExitSubscription { owner: self, terminal_id: terminal_id.clone(), waiter_id, wake }
    }

    pub(super) fn subscribe_detached(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> DetachedTerminalExitSubscription {
        let (waiter_id, wake) = self.register(terminal_id);
        DetachedTerminalExitSubscription {
            waiters: self.waiters.clone(),
            terminal_id: terminal_id.clone(),
            waiter_id,
            wake,
        }
    }

    fn register(&self, terminal_id: &TerminalPublicId) -> (u64, Arc<ResourceWaitWake>) {
        let waiter_id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let wake = Arc::new(ResourceWaitWake::default());
        self.waiters
            .lock()
            .unwrap()
            .entry(terminal_id.clone())
            .or_default()
            .insert(waiter_id, Arc::downgrade(&wake));
        (waiter_id, wake)
    }

    pub(super) fn notify(&self, terminal_id: &TerminalPublicId) {
        let waiters = self.waiters.lock().unwrap().remove(terminal_id).unwrap_or_default();
        for waiter in waiters.into_values().filter_map(|waiter| waiter.upgrade()) {
            waiter.notify();
        }
    }

    #[cfg(test)]
    pub(super) fn waiter_count(&self, terminal_id: &TerminalPublicId) -> usize {
        self.waiters.lock().unwrap().get(terminal_id).map(HashMap::len).unwrap_or_default()
    }
}

impl TerminalExitSubscription<'_> {
    pub(crate) fn wake(&self) -> Arc<ResourceWaitWake> {
        self.wake.clone()
    }

    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        self.wake.wait_until(deadline)
    }
}

impl Drop for TerminalExitSubscription<'_> {
    fn drop(&mut self) {
        unregister(&self.owner.waiters, &self.terminal_id, self.waiter_id);
    }
}

impl DetachedTerminalExitSubscription {
    /// Blocks with no timeout until the terminal's exit is published or the
    /// mux's waiter registry drops; the caller then rereads the durable state.
    pub(crate) fn wait(&self) {
        self.wake.wait_until(None);
    }
}

impl Drop for DetachedTerminalExitSubscription {
    fn drop(&mut self) {
        unregister(&self.waiters, &self.terminal_id, self.waiter_id);
    }
}

/// The mux is gone: no exit can be published any more, so every detached
/// waiter wakes and finds its weak mux dead. A borrowed subscription cannot
/// outlive the registry.
impl Drop for TerminalExitWaiters {
    fn drop(&mut self) {
        let waiters =
            std::mem::take(&mut *self.waiters.lock().unwrap_or_else(PoisonError::into_inner));
        for waiter in waiters.into_values().flat_map(HashMap::into_values) {
            if let Some(waiter) = waiter.upgrade() {
                waiter.notify();
            }
        }
    }
}

fn unregister(waiters: &Mutex<ExitWaiterMap>, terminal_id: &TerminalPublicId, waiter_id: u64) {
    let mut waiters = waiters.lock().unwrap_or_else(PoisonError::into_inner);
    let remove_terminal = waiters.get_mut(terminal_id).is_some_and(|terminal_waiters| {
        terminal_waiters.remove(&waiter_id);
        terminal_waiters.is_empty()
    });
    if remove_terminal {
        waiters.remove(terminal_id);
    }
}

#[cfg(test)]
pub(super) struct TerminalExitStateQueryGuard<'a>(pub(super) &'a AtomicU64);

#[cfg(test)]
impl Drop for TerminalExitStateQueryGuard<'_> {
    fn drop(&mut self) {
        // Count completed queries. Tests use this release/acquire edge to
        // distinguish a waiter blocked after its initial read from one that
        // merely entered terminal_exit_state and is still behind the registry
        // writer lock.
        self.0.fetch_add(1, Ordering::Release);
    }
}

#[cfg(test)]
mod detached_subscription_tests {
    use super::*;

    fn terminal() -> TerminalPublicId {
        TerminalPublicId::parse("term_00000000000000000000000000000228").unwrap()
    }

    #[test]
    fn an_exit_wakes_a_detached_waiter_with_no_timeout() {
        let waiters = TerminalExitWaiters::default();
        let subscription = waiters.subscribe_detached(&terminal());
        let waiter = std::thread::spawn(move || subscription.wait());
        waiters.notify(&terminal());
        waiter.join().unwrap();
        assert_eq!(waiters.waiter_count(&terminal()), 0);
    }

    #[test]
    fn the_registry_drop_wakes_a_detached_waiter() {
        let waiters = TerminalExitWaiters::default();
        let subscription = waiters.subscribe_detached(&terminal());
        let waiter = std::thread::spawn(move || subscription.wait());
        drop(waiters);
        waiter.join().unwrap();
    }

    #[test]
    fn dropping_a_detached_subscription_unregisters_it() {
        let waiters = TerminalExitWaiters::default();
        let subscription = waiters.subscribe_detached(&terminal());
        assert_eq!(waiters.waiter_count(&terminal()), 1);
        drop(subscription);
        assert_eq!(waiters.waiter_count(&terminal()), 0);
    }
}
