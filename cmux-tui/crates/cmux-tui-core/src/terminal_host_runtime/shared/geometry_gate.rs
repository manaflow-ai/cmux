//! Who holds a terminal host's geometry (`viewer_sizes`, `size`,
//! `cell_pixels`), so a snapshot waits for it under its deadline and wakes on
//! a release, never on a timer (p14-energy-112).
//!
//! Every geometry writer takes a [`GeometryHold`] before its first geometry
//! lock and keeps it until its last guard drops. A snapshot waits until no
//! hold is counted, counts itself, and try-locks the geometry; a refused
//! try-lock means a writer came in meanwhile, and the snapshot waits for that
//! writer's release. A `std::sync::Mutex` has no timed lock, so this count is
//! what bounds the snapshot by its deadline (Chromium bounds a waiter the same
//! way: `base::ConditionVariable::TimedWait` on a state the holders signal,
//! base/synchronization/condition_variable.h).

use crate::panic_free::RecoverPoison;
use cmux_threads::sync::{Condvar, Mutex, MutexGuard};
use std::time::Instant;

/// The holder count of one host's geometry. Its mutex is a leaf: no other
/// lock is taken while it is held.
#[derive(Default)]
pub(crate) struct GeometryGate {
    state: Mutex<GateState>,
    released: Condvar,
}

#[derive(Default)]
struct GateState {
    /// Writers and snapshot attempts that may hold a geometry lock now.
    holders: usize,
    /// Releases so far: a refused snapshot attempt that no counted holder
    /// explains waits for the next one.
    releases: u64,
}

/// One counted holder of the geometry: released when dropped. Declare it
/// before the geometry guards so it drops after them.
pub(crate) struct GeometryHold<'a> {
    gate: &'a GeometryGate,
    releases_at_start: u64,
}

impl GeometryGate {
    /// Counts a writer that is about to lock the geometry. Never waits.
    pub(crate) fn hold(&self) -> GeometryHold<'_> {
        let mut state = self.state.lock().recover_poison();
        state.holders += 1;
        GeometryHold { gate: self, releases_at_start: state.releases }
    }

    /// Waits until no holder is counted (and, with `after`, until a release
    /// past it), then counts the caller. `None` when `deadline` passes first.
    pub(crate) fn hold_when_free(
        &self,
        after: Option<u64>,
        deadline: Instant,
    ) -> Option<GeometryHold<'_>> {
        let busy = |state: &GateState| state.holders > 0 || after == Some(state.releases);
        let mut state = self.state.lock().recover_poison();
        while busy(&state) {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return None;
            }
            // wakeup-allow: deadline the snapshot's boundary timeout; a geometry release wakes it first.
            state = self
                .released
                .wait_timeout_while(state, remaining, |state| busy(state))
                .recover_poison()
                .0;
        }
        state.holders += 1;
        Some(GeometryHold { gate: self, releases_at_start: state.releases })
    }

    fn release(&self) -> MutexGuard<'_, GateState> {
        let mut state = self.state.lock().recover_poison();
        state.holders -= 1;
        state.releases = state.releases.wrapping_add(1);
        self.released.notify_all();
        state
    }
}

impl GeometryHold<'_> {
    /// Releases a snapshot attempt whose try-lock a geometry lock refused, and
    /// says what the next attempt waits for: `None` when another counted
    /// holder explains the refusal (wait until none is left), or the release
    /// count to wait past when none does (a holder that skipped its
    /// [`GeometryGate::hold`]: wait for a release or the deadline, not spin).
    pub(crate) fn refused(self) -> Option<u64> {
        let gate = self.gate;
        let started = self.releases_at_start;
        std::mem::forget(self);
        let state = gate.release();
        let explained = state.holders > 0 || state.releases != started.wrapping_add(1);
        (!explained).then_some(state.releases)
    }
}

impl Drop for GeometryHold<'_> {
    fn drop(&mut self) {
        drop(self.gate.release());
    }
}
