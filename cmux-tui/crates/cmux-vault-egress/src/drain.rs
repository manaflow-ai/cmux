//! Admission covers the entire upgraded CONNECT task, not its HTTP response.
use std::sync::{Arc, Mutex};

use tokio::sync::Notify;

#[derive(Default)]
struct State {
    active: usize,
    drainers: usize,
    committed: bool,
}

/// Shared by every accept loop whose tunnels must survive an update.
#[derive(Default)]
pub struct Admission {
    state: Mutex<State>,
    changed: Notify,
}

pub(crate) struct Permit(Arc<Admission>);

impl Drop for Permit {
    fn drop(&mut self) {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner()).active -= 1;
        self.0.changed.notify_waiters();
    }
}

/// Fences new tunnels. Dropping a cancelled/failed drain reopens admission.
pub struct Drain(Arc<Admission>);

impl Admission {
    pub(crate) fn admit(self: &Arc<Self>) -> Option<Permit> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.drainers > 0 || state.committed {
            return None;
        }
        state.active += 1;
        Some(Permit(self.clone()))
    }

    pub fn begin_drain(self: &Arc<Self>) -> Drain {
        self.state.lock().unwrap_or_else(|e| e.into_inner()).drainers += 1;
        Drain(self.clone())
    }
}

impl Drain {
    /// An open blind tunnel may carry encrypted work even when no bytes arrive.
    /// A deadline defers the update; it never permits closing such a tunnel.
    pub async fn wait_until(&self, deadline: tokio::time::Instant) -> bool {
        tokio::time::timeout_at(deadline, async {
            loop {
                let changed = self.0.changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if self.0.state.lock().unwrap_or_else(|e| e.into_inner()).active == 0 {
                    return;
                }
                changed.await;
            }
        })
        .await
        .is_ok()
    }

    /// Keep the fence closed through process replacement after a successful drain.
    pub fn commit(self) {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner()).committed = true;
    }
}

impl Drop for Drain {
    fn drop(&mut self) {
        self.0.state.lock().unwrap_or_else(|e| e.into_inner()).drainers -= 1;
    }
}

#[cfg(test)]
#[path = "drain_tests.rs"]
mod tests;
