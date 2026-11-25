//! Known UI-thread waits, each with a bound and a cancel handle.
//!
//! A wait the UI thread makes on purpose (a daemon request answered on another thread, for one)
//! registers here for as long as it waits. When a stalled turn's wait is past its bound, the
//! watchdog thread runs its cancel handle, and the wait returns the error it already returns for
//! its own timeout, so the loop goes on (recovery 1 of `ui_watchdog`).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::ThreadId;
use std::time::{Duration, Instant};

/// Cancels one wait; runs at most once, on the watchdog thread.
pub(crate) type Cancel = Box<dyn FnOnce() + Send>;

struct Entry {
    id: u64,
    label: String,
    started: Instant,
    bound: Duration,
    cancel: Option<Cancel>,
}

/// The waits in flight on the watched thread.
#[derive(Default)]
pub(crate) struct WaitRegistry {
    next: AtomicU64,
    entries: Mutex<Vec<Entry>>,
}

impl WaitRegistry {
    fn entries(&self) -> std::sync::MutexGuard<'_, Vec<Entry>> {
        self.entries.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Registers a wait; `unregister(id)` when it returns.
    pub(crate) fn register(&self, label: &str, bound: Duration, cancel: Cancel) -> u64 {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        self.entries().push(Entry {
            id,
            label: label.to_string(),
            started: Instant::now(),
            bound,
            cancel: Some(cancel),
        });
        id
    }

    pub(crate) fn unregister(&self, id: u64) {
        self.entries().retain(|entry| entry.id != id);
    }

    /// Runs the cancel handle of every wait past its bound (each once); returns their labels.
    pub(crate) fn cancel_overdue(&self, now: Instant) -> Vec<String> {
        let due: Vec<(String, Cancel)> = self
            .entries()
            .iter_mut()
            .filter(|entry| now.saturating_duration_since(entry.started) >= entry.bound)
            .filter_map(|entry| entry.cancel.take().map(|cancel| (entry.label.clone(), cancel)))
            .collect();
        // Outside the lock: a cancel may end the wait, whose guard unregisters.
        due.into_iter()
            .map(|(label, cancel)| {
                cancel();
                label
            })
            .collect()
    }

    /// `label (waited 1.2s of 5.0s)` for each wait in flight.
    pub(crate) fn describe(&self, now: Instant) -> Vec<String> {
        self.entries()
            .iter()
            .map(|entry| {
                format!(
                    "{} (waited {:.1}s of {:.1}s)",
                    entry.label,
                    now.saturating_duration_since(entry.started).as_secs_f64(),
                    entry.bound.as_secs_f64()
                )
            })
            .collect()
    }
}

/// The thread whose waits count: the loop thread of the running client watchdog.
static UI_THREAD: Mutex<Option<ThreadId>> = Mutex::new(None);

pub(super) fn set_ui_thread(thread: ThreadId) {
    *UI_THREAD.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(thread);
}

fn on_ui_thread() -> bool {
    *UI_THREAD.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
        == Some(std::thread::current().id())
}

/// Unregisters its wait when dropped.
pub(crate) struct UiWaitGuard {
    registered: Option<(Arc<super::Shared>, u64)>,
}

impl Drop for UiWaitGuard {
    fn drop(&mut self) {
        if let Some((shared, id)) = self.registered.take() {
            shared.waits.unregister(id);
        }
    }
}

/// Declares a wait the calling thread is about to make: when it is the client's UI thread and its
/// watchdog runs, the watchdog may run `cancel` once the wait passes `bound`. Elsewhere it does
/// nothing (a worker thread's wait stalls no frame).
pub(crate) fn ui_wait(label: &str, bound: Duration, cancel: Cancel) -> UiWaitGuard {
    if !on_ui_thread() {
        return UiWaitGuard { registered: None };
    }
    let Some(shared) = super::client_shared() else {
        return UiWaitGuard { registered: None };
    };
    let id = shared.waits.register(label, bound, cancel);
    UiWaitGuard { registered: Some((shared, id)) }
}
