//! A key's sizing note without the sizing lock (R-DAEMON-STATE stage S1 step 5,
//! handoff/rewrites/R-DAEMON-STATE/DESIGN.md section 3).
//!
//! After its PTY write a key notes activity in its terminal's sizing: under the default policy the newest view sets
//! the grid. The note takes the daemon-wide sizing lock, which every attach, detach, resize and size report of every
//! terminal holds (a PTY resize runs under it). The note changes nothing when the key's view is already the only
//! newest participant and the grid is settled (nothing for the next apply to do): a newer activity of the newest
//! participant moves no decision under any policy, and the published size state carries no activity values.
//!
//! So each sizing entry publishes, on its terminal's runtime (the object every view of the terminal holds), the view
//! a key may skip the note for: `(client, placement)` of the entry's sole newest member, only while the entry is
//! settled, else nothing. The publication is automatic: every read or write of an entry goes through
//! [`SizingEntries`], which marks the entry, and the sizing guard republishes the marked entries when it drops, under
//! the lock, so the publications follow the changes (the `Cell`s an apply changes through a shared borrow included).
//! A key compares its own `(client, placement)` with one atomic load. Another view's activity makes that view the
//! newest and republishes; the next key from the first view then takes the slow path once and takes the grid back.

use std::collections::HashMap;
use std::ops::{Deref, DerefMut};
use std::sync::{Arc, LockResult, Mutex, MutexGuard, PoisonError};

use arc_swap::ArcSwapOption;

use super::terminal_sizing::AppliedSeat;
use super::{ClientSizingState, TerminalSizingEntry};
use crate::SurfaceId;
use crate::sizing_policy::TerminalSizingReason;

/// The view a key may skip its sizing note for: a client's own view of one placement.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SizingFastPath {
    pub(crate) client: u64,
    pub(crate) placement: SurfaceId,
}

/// Where a terminal runtime publishes its [`SizingFastPath`]; every view (placement) of the runtime shares it.
pub(crate) type SizingFastPathSlot = Arc<ArcSwapOption<SizingFastPath>>;

/// The sizing entries by terminal runtime. Every access marks the entry (the guard republishes it), except a
/// lookup of keys or presence, which can change nothing.
#[derive(Default)]
pub(in crate::mux) struct SizingEntries {
    map: HashMap<SurfaceId, TerminalSizingEntry>,
    /// Entries read or written since the guard last published; only while publishing.
    touched: std::cell::RefCell<Vec<SurfaceId>>,
    publishing: bool,
}

impl SizingEntries {
    fn mark(&self, runtime: SurfaceId) {
        if self.publishing {
            self.touched.borrow_mut().push(runtime);
        }
    }

    pub(in crate::mux) fn get(&self, runtime: &SurfaceId) -> Option<&TerminalSizingEntry> {
        self.mark(*runtime);
        self.map.get(runtime)
    }

    pub(in crate::mux) fn get_mut(
        &mut self,
        runtime: &SurfaceId,
    ) -> Option<&mut TerminalSizingEntry> {
        self.mark(*runtime);
        self.map.get_mut(runtime)
    }

    pub(in crate::mux) fn insert(
        &mut self,
        runtime: SurfaceId,
        entry: TerminalSizingEntry,
    ) -> Option<TerminalSizingEntry> {
        self.mark(runtime);
        self.map.insert(runtime, entry)
    }

    /// Removes the entry; a removed entry publishes nothing, so its terminal's keys take the slow path.
    pub(in crate::mux) fn remove(&mut self, runtime: &SurfaceId) -> Option<TerminalSizingEntry> {
        let removed = self.map.remove(runtime);
        if self.publishing
            && let Some(slot) = removed.as_ref().and_then(|entry| entry.fast_path_slot.as_ref())
        {
            slot.store(None);
        }
        removed
    }

    /// Whether the entries publish their fast paths (the mux's stage S1 switch).
    pub(in crate::mux) fn publishing(&self) -> bool {
        self.publishing
    }

    pub(in crate::mux) fn contains_key(&self, runtime: &SurfaceId) -> bool {
        self.map.contains_key(runtime)
    }

    pub(in crate::mux) fn keys(&self) -> impl Iterator<Item = &SurfaceId> {
        self.map.keys()
    }

    pub(in crate::mux) fn values(&self) -> impl Iterator<Item = &TerminalSizingEntry> {
        self.map.iter().map(|(runtime, entry)| {
            self.mark(*runtime);
            entry
        })
    }

    pub(in crate::mux) fn iter(&self) -> impl Iterator<Item = (&SurfaceId, &TerminalSizingEntry)> {
        self.map.iter().inspect(|(runtime, _)| self.mark(**runtime))
    }

    /// Republishes every marked entry's fast path, or clears it when the change that marked it was cut short.
    fn publish_marked(&self, cut_short: bool) {
        let mut touched = std::mem::take(&mut *self.touched.borrow_mut());
        touched.sort_unstable();
        touched.dedup();
        for runtime in touched {
            let Some(entry) = self.map.get(&runtime) else { continue };
            let Some(slot) = entry.fast_path_slot.as_ref() else { continue };
            let published = if cut_short { None } else { entry.fast_path() };
            // An unchanged value is not stored again: a read that changed nothing allocates nothing.
            if slot.load().as_deref().copied() != published {
                slot.store(published.map(Arc::new));
            }
        }
    }

    /// Turns publishing on or off (tests); every entry publishes, or clears, at once.
    #[cfg(test)]
    fn set_publishing(&mut self, on: bool) {
        self.publishing = on;
        for entry in self.map.values() {
            if let Some(slot) = entry.fast_path_slot.as_ref() {
                slot.store(if on { entry.fast_path().map(Arc::new) } else { None });
            }
        }
        self.touched.borrow_mut().clear();
    }
}

impl TerminalSizingEntry {
    /// Points the entry at `surface`'s terminal runtime when that runtime is the entry's: a respawn under the same
    /// runtime id builds a new runtime with a new slot, and the entry outlives it. The old slot is cleared; the
    /// sizing guard publishes into the new one (the caller reached the entry through `SizingEntries`, which marked
    /// it). A surface of another runtime changes nothing. Called by a key's sizing note, which holds the surface, so
    /// it costs no lookup.
    pub(in crate::mux) fn follow_runtime_of(
        &mut self,
        runtime: SurfaceId,
        surface: &crate::Surface,
    ) {
        if surface.terminal_runtime_id() != Some(runtime) {
            return;
        }
        let Some(slot) = surface.sizing_fast_path_slot() else { return };
        if self.fast_path_slot.as_ref().is_some_and(|current| Arc::ptr_eq(current, &slot)) {
            return;
        }
        if let Some(old) = self.fast_path_slot.replace(slot) {
            old.store(None);
        }
    }

    /// The view a key may skip its note for: the sole newest member, a client's own view, while nothing waits for
    /// the next apply. Settled: no grid hold, no handheld that reported a size (a handheld caps or holds the grid),
    /// and, unless the engine holds the grid (no view counts, so an apply does nothing), the grid it applied is its
    /// decision and the participants are the ones it applied for.
    fn fast_path(&self) -> Option<SizingFastPath> {
        if self.hold.get().is_some() {
            return None;
        }
        let sized_handheld = self.engine.participant_ids().any(|id| {
            self.engine.participant(id).is_some_and(|participant| {
                participant.device_kind.is_handheld() && participant.viewport.is_some()
            })
        });
        if sized_handheld {
            return None;
        }
        let state = self.engine.state();
        if state.reason != TerminalSizingReason::Held
            && (self.applied.get() != Some((state.cols, state.rows)) || !self.applied_for_present())
        {
            return None;
        }
        let newest = self.engine.sole_latest()?;
        let member = self.members.get(newest).filter(|member| member.view.is_none())?;
        Some(SizingFastPath { client: member.client, placement: member.placement })
    }

    /// Whether the last apply saw the participants there are now (else the next apply notices an arrival or a
    /// departure); compared in place, with no copy.
    fn applied_for_present(&self) -> bool {
        let applied = self.applied_participants.borrow();
        applied.len() == self.engine.participant_ids().count()
            && self
                .engine
                .participant_ids()
                .all(|id| applied.get(id) == Some(&AppliedSeat::of(self.engine.participant(id))))
    }
}

/// `Mux::client_sizing`: the sizing state behind its mutex, whose guard republishes the entries it touched. Whether
/// it publishes is the mux's stage S1 switch, kept with the entries under the lock.
pub(in crate::mux) struct SizingMutex {
    value: Mutex<ClientSizingState>,
}

impl SizingMutex {
    pub(in crate::mux) fn new(mut state: ClientSizingState, publishing: bool) -> Self {
        state.terminal_sizing.publishing = publishing;
        Self { value: Mutex::new(state) }
    }

    pub(in crate::mux) fn lock(&self) -> LockResult<SizingGuard<'_>> {
        match self.value.lock() {
            Ok(guard) => Ok(SizingGuard::new(guard)),
            Err(poison) => Err(PoisonError::new(SizingGuard::new(poison.into_inner()))),
        }
    }

    /// Turns stage S1 on or off for the sizing (tests).
    #[cfg(test)]
    pub(in crate::mux) fn set_publishing_for_test(&self, on: bool) {
        let mut guard = self.value.lock().unwrap_or_else(PoisonError::into_inner);
        guard.terminal_sizing.set_publishing(on);
    }
}

/// A held [`SizingMutex`]. When it drops it republishes the entries it touched, before the mutex is released.
pub(in crate::mux) struct SizingGuard<'a> {
    guard: MutexGuard<'a, ClientSizingState>,
    /// Whether this thread was already unwinding when it took the lock, as `std::sync::MutexGuard` records it.
    panicking_at_lock: bool,
}

impl<'a> SizingGuard<'a> {
    fn new(guard: MutexGuard<'a, ClientSizingState>) -> Self {
        Self { guard, panicking_at_lock: std::thread::panicking() }
    }
}

impl Deref for SizingGuard<'_> {
    type Target = ClientSizingState;

    fn deref(&self) -> &ClientSizingState {
        &self.guard
    }
}

impl DerefMut for SizingGuard<'_> {
    fn deref_mut(&mut self) -> &mut ClientSizingState {
        &mut self.guard
    }
}

impl Drop for SizingGuard<'_> {
    fn drop(&mut self) {
        if self.guard.terminal_sizing.publishing {
            // A panic that began while this guard held the lock cut its change short: the marked entries publish
            // nothing, so their keys take the slow path. A later holder that recovers the poison republishes what it
            // touches (the settled and member checks still apply to what it sees).
            let cut_short = std::thread::panicking() && !self.panicking_at_lock;
            self.guard.terminal_sizing.publish_marked(cut_short);
        }
    }
}
