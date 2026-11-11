//! One whole-tree build for concurrent `list-workspaces` reads.
//!
//! A `list-workspaces` reply is the whole tree, built under the state lock
//! (O(workspaces + terminals)). Clients that read it at once took the lock
//! one after another and built the same tree once each, so each waited for
//! every build queued before it. Here a read that arrives while a build runs
//! waits for the next build, which starts after it arrived, and every read
//! waiting then shares that build. Each reply still shows every change
//! committed before its request arrived (a client that changed the tree and
//! then lists it sees its change), and at most two builds run back to back
//! however many clients read at once.
//!
//! Only a built tree is shared. A build that fails (or panics) gives its
//! error to its own caller only; the readers that waited for it build again,
//! so each error reply is the one its own build made, with its error code.
//!
//! The shared value is kept only while a reader waits for it: a read with no
//! company builds and returns its own value, with no copy and nothing kept.

use crate::panic_free::RecoverPoison;
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex};

#[derive(Default)]
pub(crate) struct TreeReplyFlight {
    state: Mutex<FlightState>,
    finished: Condvar,
}

#[derive(Default)]
struct FlightState {
    /// The number of builds started; while `building`, the running one.
    started: u64,
    building: bool,
    /// Readers waiting, by the build number each needs at least. A build
    /// serves every reader that needs it or an older one.
    waiting: BTreeMap<u64, usize>,
    /// The newest built tree that a reader waits for, and its build number.
    shared: Option<(u64, Arc<Value>)>,
}

impl FlightState {
    /// Whether a reader waits that build `number` serves.
    fn awaits(&self, number: u64) -> bool {
        self.waiting.range(..=number).next().is_some()
    }

    fn stop_waiting(&mut self, needed: u64) {
        if let Some(count) = self.waiting.get_mut(&needed) {
            *count -= 1;
            if *count == 0 {
                self.waiting.remove(&needed);
            }
        }
        // Readers that need a newer build than the shared one cannot use it.
        if let Some((number, _)) = &self.shared
            && !self.awaits(*number)
        {
            self.shared = None;
        }
    }
}

/// Ends a build even if it unwinds: clears `building` and wakes every
/// waiter, so one of them starts the next build instead of waiting for ever.
struct BuildGuard<'a> {
    flight: &'a TreeReplyFlight,
    number: u64,
}

impl BuildGuard<'_> {
    /// Hands a built tree to the readers that this build serves, if any
    /// wait; `value` is copied only then. `drop` then ends the build.
    fn finish(self, value: &Value) {
        let mut state = self.flight.state.lock().recover_poison();
        if state.awaits(self.number) {
            state.shared = Some((self.number, Arc::new(value.clone())));
        }
    }
}

impl Drop for BuildGuard<'_> {
    fn drop(&mut self) {
        self.flight.state.lock().recover_poison().building = false;
        self.flight.finished.notify_all();
    }
}

impl TreeReplyFlight {
    /// `build`'s value from a build that started after this call, shared
    /// with every concurrent caller that this build serves.
    pub(crate) fn read(
        &self,
        build: impl FnOnce() -> anyhow::Result<Value>,
    ) -> anyhow::Result<Value> {
        let mut state = self.state.lock().recover_poison();
        // A running build may have read the tree before this call: this read
        // needs the build after it (or, when none runs, the one it starts).
        let needed = state.started + 1;
        let mut registered = false;
        loop {
            if let Some((number, value)) = &state.shared
                && *number >= needed
            {
                let value = value.clone();
                state.stop_waiting(needed);
                drop(state);
                return Ok(Value::clone(&value));
            }
            if !state.building {
                if registered {
                    state.stop_waiting(needed);
                }
                state.building = true;
                state.started += 1;
                let guard = BuildGuard { flight: self, number: state.started };
                drop(state);
                let result = build();
                match &result {
                    Ok(value) => guard.finish(value),
                    // `drop` ends the build; the waiters build again.
                    Err(_) => drop(guard),
                }
                return result;
            }
            if !registered {
                *state.waiting.entry(needed).or_default() += 1;
                registered = true;
            }
            state = self.finished.wait(state).recover_poison();
        }
    }
}

#[cfg(test)]
#[path = "tree_reply_flight_tests.rs"]
mod tests;
