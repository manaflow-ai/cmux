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
            let (next, timeout) = self.changed.wait_timeout(active, remaining).unwrap();
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

#[derive(Default)]
pub(super) struct TerminalExitWaiters {
    pub(super) next_id: AtomicU64,
    pub(super) waiters: Mutex<HashMap<TerminalPublicId, HashMap<u64, Weak<ResourceWaitWake>>>>,
}

pub(crate) struct TerminalExitSubscription<'a> {
    pub(super) owner: &'a TerminalExitWaiters,
    pub(super) terminal_id: TerminalPublicId,
    pub(super) waiter_id: u64,
    pub(super) wake: Arc<ResourceWaitWake>,
}

impl TerminalExitWaiters {
    pub(super) fn subscribe(&self, terminal_id: &TerminalPublicId) -> TerminalExitSubscription<'_> {
        let waiter_id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let wake = Arc::new(ResourceWaitWake::default());
        self.waiters
            .lock()
            .unwrap()
            .entry(terminal_id.clone())
            .or_default()
            .insert(waiter_id, Arc::downgrade(&wake));
        TerminalExitSubscription { owner: self, terminal_id: terminal_id.clone(), waiter_id, wake }
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
        let mut waiters = self.owner.waiters.lock().unwrap();
        let remove_terminal = waiters.get_mut(&self.terminal_id).is_some_and(|terminal_waiters| {
            terminal_waiters.remove(&self.waiter_id);
            terminal_waiters.is_empty()
        });
        if remove_terminal {
            waiters.remove(&self.terminal_id);
        }
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
