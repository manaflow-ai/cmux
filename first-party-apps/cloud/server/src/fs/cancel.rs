//! [`Cancel`]: how the loop stops a running transfer. The worker registers
//! one hook per child process it starts (the hook kills that child); a
//! cancel runs every hook once, and a hook registered after the cancel runs
//! at once. No timer and no polling: the kill ends the child's pipes, and
//! the worker's blocking read and wait return.

use std::sync::{Arc, Mutex, MutexGuard};

type Hook = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct State {
    cancelled: bool,
    hooks: Vec<Hook>,
}

/// Shared between the loop (which cancels) and the transfer's worker
/// (which registers its children). Cloning shares the same state.
#[derive(Clone, Default)]
pub struct Cancel(Arc<Mutex<State>>);

impl std::fmt::Debug for Cancel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Cancel {{ cancelled: {} }}", self.is_cancelled())
    }
}

impl Cancel {
    fn lock(&self) -> MutexGuard<'_, State> {
        // A hook that panicked leaves the flag and hooks consistent.
        self.0.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// True once [`Cancel::cancel`] ran.
    pub fn is_cancelled(&self) -> bool {
        self.lock().cancelled
    }

    /// Runs `hook` when the transfer is cancelled, or now when it already
    /// is. Each hook runs at most once, outside the lock.
    pub fn on_cancel(&self, hook: impl FnOnce() + Send + 'static) {
        let mut state = self.lock();
        if state.cancelled {
            drop(state);
            hook();
            return;
        }
        state.hooks.push(Box::new(hook));
    }

    /// Marks the transfer cancelled and runs every registered hook once.
    pub fn cancel(&self) {
        let hooks = {
            let mut state = self.lock();
            state.cancelled = true;
            std::mem::take(&mut state.hooks)
        };
        for hook in hooks {
            hook();
        }
    }
}
