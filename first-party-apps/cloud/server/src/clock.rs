//! [`Clock`]: the one source of bounded waits in runtime code. A timer
//! fires its callback once after a delay unless it is cancelled first
//! (dropping the [`Timer`] cancels it). No polling: the system clock's
//! timer thread blocks on its cancel channel with the delay as the bound.
//! Tests inject a clock they fire by hand.

use std::sync::mpsc::{RecvTimeoutError, channel};
use std::time::Duration;

/// A pending callback; dropping it cancels the callback.
pub struct Timer {
    cancel: Option<Box<dyn FnOnce() + Send>>,
}

impl Timer {
    /// A timer whose cancellation runs `cancel` (for clock implementations).
    pub fn new(cancel: Box<dyn FnOnce() + Send>) -> Self {
        Self { cancel: Some(cancel) }
    }
}

impl Drop for Timer {
    fn drop(&mut self) {
        if let Some(cancel) = self.cancel.take() {
            cancel();
        }
    }
}

impl std::fmt::Debug for Timer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Timer")
    }
}

pub trait Clock: Send + Sync {
    /// Calls `fire` once after `delay`, on another thread, unless the
    /// returned timer is dropped first. `fire` must not block.
    fn after(&self, delay: Duration, fire: Box<dyn FnOnce() + Send>) -> Timer;
}

/// The real clock: one short-lived thread per timer, blocked on the
/// cancel channel with `delay` as its bound.
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemClock;

impl Clock for SystemClock {
    fn after(&self, delay: Duration, fire: Box<dyn FnOnce() + Send>) -> Timer {
        let (cancel, cancelled) = channel::<()>();
        let spawned =
            std::thread::Builder::new().name("cmux-cloud-timer".into()).spawn(move || {
                // A send or a dropped sender is a cancel; only the full delay fires.
                if let Err(RecvTimeoutError::Timeout) = cancelled.recv_timeout(delay) {
                    fire();
                }
            });
        if let Err(e) = spawned {
            eprintln!("cmux-cloud: no timer thread ({e}); the wait has no deadline");
        }
        Timer::new(Box::new(move || drop(cancel)))
    }
}
