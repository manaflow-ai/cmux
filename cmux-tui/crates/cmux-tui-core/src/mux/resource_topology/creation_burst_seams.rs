//! Test seams of a burst of creations (SPLIT BURST). The hooks are no-ops
//! outside tests; the waits they count run in every build.

use super::*;

/// Test seams of a burst of creations (SPLIT BURST): a hook a creation runs
/// once before its effect, and the count of creations that wait while
/// another creation holds the creation path.
#[cfg(test)]
#[derive(Default)]
pub(crate) struct CreationBurstSeams {
    before_effect: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    before_fence: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    waiting: AtomicUsize,
}

impl Mux {
    /// Runs `hook` once, in the next group leader, after it joined its
    /// group and before it takes the creation fence.
    #[cfg(test)]
    pub(crate) fn set_creation_before_fence_hook_for_test(&self, hook: Box<dyn FnOnce() + Send>) {
        *self.creation_burst_seams.before_fence.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(hook);
    }

    /// The hook of [`Self::set_creation_before_fence_hook_for_test`];
    /// nothing outside tests.
    pub(crate) fn run_creation_before_fence_hook(&self) {
        #[cfg(test)]
        {
            let hook = self
                .creation_burst_seams
                .before_fence
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .take();
            if let Some(hook) = hook {
                hook();
            }
        }
    }

    /// Runs `hook` once, in the next creation, right before its effect.
    #[cfg(test)]
    pub(crate) fn set_creation_before_effect_hook_for_test(&self, hook: Box<dyn FnOnce() + Send>) {
        *self.creation_burst_seams.before_effect.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(hook);
    }

    /// The hook of [`Self::set_creation_before_effect_hook_for_test`];
    /// nothing outside tests.
    pub(crate) fn run_creation_before_effect_hook(&self) {
        #[cfg(test)]
        if let Some(hook) = self
            .creation_burst_seams
            .before_effect
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take()
        {
            hook();
        }
    }

    /// Creations that wait right now while another creation holds the
    /// creation path.
    #[cfg(test)]
    pub(crate) fn creations_waiting_for_test(&self) -> usize {
        self.creation_burst_seams.waiting.load(Ordering::SeqCst)
    }

    /// Runs `wait`, a creation's wait for another creation, counted for
    /// [`Self::creations_waiting_for_test`]; outside tests only `wait`.
    pub(crate) fn creation_wait<T>(&self, wait: impl FnOnce() -> T) -> T {
        #[cfg(test)]
        self.creation_burst_seams.waiting.fetch_add(1, Ordering::SeqCst);
        let value = wait();
        #[cfg(test)]
        self.creation_burst_seams.waiting.fetch_sub(1, Ordering::SeqCst);
        value
    }
}
