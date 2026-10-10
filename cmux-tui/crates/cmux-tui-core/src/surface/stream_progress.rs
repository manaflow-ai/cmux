//! Terminal stream progress: the revision counter and waiters that tell
//! clear-history and resource waits when terminal output, geometry or
//! reconnects changed the stream.

use super::*;

pub(crate) struct TerminalStreamProgress {
    next_resource_waiter_id: AtomicU64,
    state: Mutex<TerminalStreamProgressState>,
    changed: Condvar,
    #[cfg(test)]
    test_before_notify: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

#[derive(Default)]
struct TerminalStreamProgressState {
    revision: u64,
    waiters: usize,
    resource_waiters: HashMap<u64, Weak<ResourceWaitWake>>,
    #[cfg(test)]
    resource_subscriptions: u64,
    clear_history_wait: Option<ClearHistoryWaitState>,
}

struct ClearHistoryWaitState {
    deadline: Instant,
    revision: u64,
    // Timed-out waits leave this state latched at zero only while the stream
    // revision is unchanged. Queued repeats then fail without restarting the
    // full timeout, while concurrent callers share one deadline.
    waiters: usize,
}

pub(crate) struct ClearHistoryWaitLease<'a> {
    progress: &'a TerminalStreamProgress,
    deadline: Instant,
    timed_out: bool,
}

/// One-shot terminal-stream wakeup. Registering before reading the viewport
/// closes the read/wait race, while cancellation and writer shutdown can wake
/// the same blocking primitive without a polling deadline.
pub(crate) struct TerminalStreamSubscription<'a> {
    progress: &'a TerminalStreamProgress,
    waiter_id: u64,
    wake: Arc<ResourceWaitWake>,
}

impl ClearHistoryWaitLease<'_> {
    pub(crate) fn deadline(&self) -> Instant {
        self.deadline
    }

    pub(crate) fn mark_timed_out(&mut self) {
        self.timed_out = true;
    }
}

impl Drop for ClearHistoryWaitLease<'_> {
    fn drop(&mut self) {
        self.progress.finish_clear_history_wait(self.timed_out);
    }
}

impl Default for TerminalStreamProgress {
    fn default() -> Self {
        Self {
            next_resource_waiter_id: AtomicU64::new(1),
            state: Mutex::new(TerminalStreamProgressState::default()),
            changed: Condvar::new(),
            #[cfg(test)]
            test_before_notify: Mutex::new(None),
        }
    }
}

impl TerminalStreamProgress {
    pub(crate) fn revision(&self) -> u64 {
        self.state.lock().unwrap().revision
    }

    pub(crate) fn notify(&self) {
        #[cfg(test)]
        if let Some(hook) = self.test_before_notify.lock().unwrap().clone() {
            hook();
        }
        let mut state = self.state.lock().unwrap();
        state.revision = state.revision.wrapping_add(1);
        // An expired budget is retained only while the stream is unchanged.
        // Active waiters keep their original deadline across fragmented output.
        if state.clear_history_wait.as_ref().is_some_and(|wait| wait.waiters == 0) {
            state.clear_history_wait = None;
        }
        let resource_waiters = std::mem::take(&mut state.resource_waiters);
        self.changed.notify_all();
        drop(state);
        for wake in resource_waiters.into_values().filter_map(|waiter| waiter.upgrade()) {
            wake.notify();
        }
    }

    #[cfg(test)]
    pub(super) fn set_before_notify_hook(&self, hook: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.test_before_notify.lock().unwrap() = hook;
    }

    pub(super) fn notify_reconnect(&self) {
        self.notify();
    }

    pub(crate) fn subscribe(&self) -> TerminalStreamSubscription<'_> {
        let waiter_id = self.next_resource_waiter_id.fetch_add(1, Ordering::Relaxed);
        let wake = Arc::new(ResourceWaitWake::default());
        let mut state = self.state.lock().unwrap();
        state.resource_waiters.insert(waiter_id, Arc::downgrade(&wake));
        #[cfg(test)]
        {
            state.resource_subscriptions = state.resource_subscriptions.wrapping_add(1);
        }
        TerminalStreamSubscription { progress: self, waiter_id, wake }
    }

    pub(crate) fn begin_clear_history_wait(&self, timeout: Duration) -> ClearHistoryWaitLease<'_> {
        let mut state = self.state.lock().unwrap();
        let revision = state.revision;
        let wait = state.clear_history_wait.get_or_insert_with(|| ClearHistoryWaitState {
            deadline: Instant::now() + timeout,
            revision,
            waiters: 0,
        });
        wait.waiters += 1;
        ClearHistoryWaitLease { progress: self, deadline: wait.deadline, timed_out: false }
    }

    fn finish_clear_history_wait(&self, timed_out: bool) {
        let mut state = self.state.lock().unwrap();
        let current_revision = state.revision;
        let clear_wait = {
            let Some(wait) = state.clear_history_wait.as_mut() else {
                return;
            };
            debug_assert!(wait.waiters > 0);
            wait.waiters -= 1;
            wait.waiters == 0 && (!timed_out || wait.revision != current_revision)
        };
        if clear_wait {
            state.clear_history_wait = None;
        }
    }

    pub(crate) fn wait_for_change(&self, observed: u64, deadline: Instant) -> Option<u64> {
        self.wait_for_change_until(observed, Some(deadline))
    }

    pub(super) fn wait_for_change_until(
        &self,
        observed: u64,
        deadline: Option<Instant>,
    ) -> Option<u64> {
        let mut state = self.state.lock().unwrap();
        if state.revision != observed {
            return Some(state.revision);
        }
        state.waiters += 1;
        while state.revision == observed {
            match deadline {
                Some(deadline) => {
                    let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                        state.waiters -= 1;
                        return None;
                    };
                    let (next, timeout) = self.changed.wait_timeout(state, remaining).unwrap();
                    state = next;
                    if timeout.timed_out() && state.revision == observed {
                        state.waiters -= 1;
                        return None;
                    }
                }
                None => state = self.changed.wait(state).unwrap(),
            }
        }
        let revision = state.revision;
        state.waiters -= 1;
        Some(revision)
    }

    #[cfg(test)]
    pub(super) fn waiter_count(&self) -> usize {
        let state = self.state.lock().unwrap();
        state.waiters + state.resource_waiters.len()
    }
}

impl TerminalStreamSubscription<'_> {
    pub(crate) fn wake(&self) -> Arc<ResourceWaitWake> {
        self.wake.clone()
    }

    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        self.wake.wait_until(deadline)
    }
}

impl Drop for TerminalStreamSubscription<'_> {
    fn drop(&mut self) {
        self.progress.state.lock().unwrap().resource_waiters.remove(&self.waiter_id);
    }
}
