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
//!
//! A reader that writes the tree to its socket (`read_text`) takes the
//! tree's text (tree_reply_text.rs), which the readers of one build write
//! one time and share, so they do not serialize the same tree once each.

use super::tree_reply_text::TreeText;
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
    shared: Option<(u64, Arc<SharedTree>)>,
}

/// A built tree that the readers of its build share.
struct SharedTree {
    value: Value,
    /// Its text, written by the first of its readers that takes it.
    text: Mutex<Option<Arc<TreeText>>>,
}

impl SharedTree {
    /// The tree's text, written by `write` if no reader wrote it yet. A
    /// reader that comes while it is written waits for it.
    fn text(
        &self,
        write: impl FnOnce(&Value) -> std::io::Result<TreeText>,
    ) -> std::io::Result<Arc<TreeText>> {
        let mut text = self.text.lock().recover_poison();
        if let Some(text) = &*text {
            return Ok(text.clone());
        }
        let written = Arc::new(write(&self.value)?);
        *text = Some(written.clone());
        Ok(written)
    }
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
    /// Hands the built tree that `share` makes to the readers that this
    /// build serves, if any wait; `share` runs only then, outside the lock.
    /// `drop` then ends the build.
    fn finish(self, share: impl FnOnce() -> SharedTree) {
        // While this build runs, a reader that it serves only waits (it
        // leaves when the build ends or shares), so the check holds until
        // the tree is shared.
        if self.flight.state.lock().recover_poison().awaits(self.number) {
            let tree = Arc::new(share());
            self.flight.state.lock().recover_poison().shared = Some((self.number, tree));
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
        self.join(
            build,
            |guard, value| {
                guard.finish(|| SharedTree { value: value.clone(), text: Mutex::default() });
                Ok(value)
            },
            |tree| Ok(tree.value.clone()),
        )
    }

    /// [`Self::read`]'s tree as its text, written by `write` one time for
    /// all the callers that its build serves.
    pub(crate) fn read_text(
        &self,
        build: impl FnOnce() -> anyhow::Result<Value>,
        write: impl Fn(&Value) -> std::io::Result<TreeText>,
    ) -> anyhow::Result<Arc<TreeText>> {
        self.join(
            build,
            |guard, value| {
                // Written before the build ends, so the readers it serves
                // take this text. If the write fails, `guard`'s drop ends
                // the build and they build again.
                let text = Arc::new(write(&value)?);
                let shared = text.clone();
                guard.finish(move || SharedTree { value, text: Mutex::new(Some(shared)) });
                Ok(text)
            },
            |tree| Ok(tree.text(&write)?),
        )
    }

    /// Waits for a build that started after this call: `built` takes the
    /// value of the build this call ran, `shared` the tree that another
    /// caller's build shared with it.
    fn join<T>(
        &self,
        build: impl FnOnce() -> anyhow::Result<Value>,
        built: impl FnOnce(BuildGuard<'_>, Value) -> anyhow::Result<T>,
        shared: impl FnOnce(&SharedTree) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let mut state = self.state.lock().recover_poison();
        // A running build may have read the tree before this call: this read
        // needs the build after it (or, when none runs, the one it starts).
        let needed = state.started + 1;
        let mut registered = false;
        loop {
            if let Some((number, tree)) = &state.shared
                && *number >= needed
            {
                let tree = tree.clone();
                state.stop_waiting(needed);
                drop(state);
                return shared(&tree);
            }
            if !state.building {
                if registered {
                    state.stop_waiting(needed);
                }
                state.building = true;
                state.started += 1;
                let guard = BuildGuard { flight: self, number: state.started };
                drop(state);
                // On an error `guard`'s drop ends the build; the waiters
                // build again.
                let value = build()?;
                return built(guard, value);
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
impl TreeReplyFlight {
    /// Test seam: the readers that wait for a build.
    pub(crate) fn waiting_readers(&self) -> usize {
        self.state.lock().recover_poison().waiting.values().sum()
    }
}

#[cfg(test)]
#[path = "tree_reply_flight_tests.rs"]
mod tests;
