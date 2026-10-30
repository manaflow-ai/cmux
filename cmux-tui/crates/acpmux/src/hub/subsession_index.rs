//! Part of `subsessions.rs`: the live children of each parent, which count toward its width limit
//! (`maxChildren`), and the slots starts in flight reserve. A child holds a slot while its harness
//! is alive (`holds_width_slot`); its entry follows every status write, under the child's meta
//! lock (`Hub::set_status`).
//!
//! The index is a leaf lock: nothing else is locked while it is held, so it may be taken under
//! any other lock.

use super::*;
use std::collections::BTreeSet;

/// The live children of each parent, and the slots reserved by starts in flight.
#[derive(Default)]
pub struct Index {
    state: StdMutex<IndexState>,
}

#[derive(Default)]
struct IndexState {
    open: HashMap<String, BTreeSet<String>>,
    reserved: HashMap<String, u32>,
    /// Every short name a child of each parent has or had, open or closed;
    /// a failed start keeps its name, so a name is never given twice.
    names: HashMap<String, BTreeSet<String>>,
}

impl Index {
    fn lock(&self) -> std::sync::MutexGuard<'_, IndexState> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Notes `child` of `parent` as live or no longer live.
    fn set_open(&self, parent: &str, child: &str, open: bool) {
        let mut s = self.lock();
        if open {
            s.open.entry(parent.to_owned()).or_default().insert(child.to_owned());
        } else if let Some(set) = s.open.get_mut(parent) {
            set.remove(child);
            if set.is_empty() {
                s.open.remove(parent);
            }
        }
    }

    /// Updates a child's width slot from its session status.
    pub(in crate::hub) fn set_live(&self, parent: &str, child: &str, status: SessionStatus) {
        self.set_open(parent, child, holds_width_slot(status));
    }

    /// Notes a loaded child's short name as taken.
    pub(in crate::hub) fn note_name(&self, parent: &str, short: &str) {
        self.lock().names.entry(parent.to_owned()).or_default().insert(short.to_owned());
    }

    /// Takes the first free short name of `parent` from `base`, `base-2`, ...
    pub(in crate::hub) fn claim_name(&self, parent: &str, base: &str) -> String {
        let mut s = self.lock();
        let taken = s.names.entry(parent.to_owned()).or_default();
        let short = (1..)
            .map(|n| if n == 1 { base.to_owned() } else { format!("{base}-{n}") })
            .find(|n| !taken.contains(n))
            .unwrap_or_else(|| base.to_owned());
        taken.insert(short.clone());
        short
    }

    /// The live children of `parent`.
    pub(in crate::hub) fn open_children(&self, parent: &str) -> Vec<String> {
        self.lock().open.get(parent).map(|s| s.iter().cloned().collect()).unwrap_or_default()
    }

    /// How many children of `parent` are live.
    pub fn open_count(&self, parent: &str) -> u32 {
        self.lock().open.get(parent).map_or(0, |s| s.len() as u32)
    }

    /// Reserves one child slot of `parent` under `max`, or returns how many
    /// are open or reserved.
    pub(super) fn reserve<'a>(&'a self, parent: &'a str, max: u32) -> Result<Reservation<'a>, u32> {
        let mut s = self.lock();
        let used = s.open.get(parent).map_or(0, |set| set.len() as u32)
            + s.reserved.get(parent).copied().unwrap_or(0);
        if used >= max {
            return Err(used);
        }
        *s.reserved.entry(parent.to_owned()).or_default() += 1;
        Ok(Reservation { index: self, parent })
    }

    fn release(&self, parent: &str) {
        let mut s = self.lock();
        if let Some(n) = s.reserved.get_mut(parent) {
            *n = n.saturating_sub(1);
            if *n == 0 {
                s.reserved.remove(parent);
            }
        }
    }
}

/// One width slot held by a start in flight; dropped (an error, a panic, a
/// cancelled request) it frees the slot.
pub(super) struct Reservation<'a> {
    index: &'a Index,
    parent: &'a str,
}

impl Reservation<'_> {
    /// The start made `child`: it holds the slot from now on, unless it was
    /// closed meanwhile. Under the child's meta lock, like every other
    /// change of its entry ([`Hub::set_status`]), so the index follows the
    /// order of the status writes.
    pub(super) fn settle(self, child: &Session) {
        let m = child.meta.lock().unwrap_or_else(|e| e.into_inner());
        self.index.set_live(self.parent, &child.id, m.status);
    }
}

impl Drop for Reservation<'_> {
    fn drop(&mut self) {
        self.index.release(self.parent);
    }
}

/// A width slot represents a harness that can still do work. `Ready` means the harness process
/// is alive between turns; `Running` and `Waiting` cover an active turn and a prompt waiting for
/// input. `Idle` has no harness process, and `Disconnected` records a dead one.
pub(super) fn holds_width_slot(status: SessionStatus) -> bool {
    matches!(status, SessionStatus::Ready | SessionStatus::Running | SessionStatus::Waiting)
}

#[cfg(test)]
#[path = "subsession_width_tests.rs"]
mod width_tests;
