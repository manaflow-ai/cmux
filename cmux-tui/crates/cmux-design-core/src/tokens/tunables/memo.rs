//! `TokenMemo`'s keep-or-compute rules as a pure state machine (CmuxNextDesign/TokenMemo.swift):
//! the epoch every drop bumps, the settling count a drop holds until the main queue's next turn,
//! the stored value's epoch and store activation, and what one read does. The Observation and
//! `withObservationTracking` wiring (which calls [`MemoState::drop_value`] when an input changes,
//! and [`MemoState::settle`] on the next main turn) stays Swift.

use serde::{Deserialize, Serialize};

/// What one `value(_:)` read does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum MemoRead {
    /// A scoped density: computed, nothing armed, nothing kept.
    Scoped,
    /// A drop is settling: computed in the caller's own tracking, nothing kept.
    Settling,
    /// The kept value.
    Hit,
    /// Computed in a fresh tracking scope (`tracks_store`: its shape holds the store) and kept.
    Kept {
        /// The tracking shape names the tunable store (it is active).
        tracks_store: bool,
    },
    /// Computed in a fresh tracking scope, not kept: a drop landed while it ran.
    Discarded {
        /// The tracking shape names the tunable store (it is active).
        tracks_store: bool,
    },
}

impl MemoRead {
    /// Whether the read ran `compute`.
    pub fn computed(self) -> bool {
        !matches!(self, MemoRead::Hit)
    }
}

/// One memo's state: `stored != nil`, `storedEpoch`, `storedActive`, `epoch`, `settling`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemoState {
    /// A value is kept.
    pub has_stored: bool,
    /// The epoch the kept value was computed at (-1 before the first).
    pub stored_epoch: i64,
    /// The store's activation when the kept value was computed.
    pub stored_active: bool,
    /// Bumped by every drop.
    pub epoch: i64,
    /// Drops whose change may not have landed yet.
    pub settling: i64,
}

impl Default for MemoState {
    fn default() -> Self {
        MemoState {
            has_stored: false,
            stored_epoch: -1,
            stored_active: false,
            epoch: 0,
            settling: 0,
        }
    }
}

impl MemoState {
    /// `drop()`: settling and epoch up by one (the change is announced).
    pub fn drop_value(&mut self) {
        self.settling = self.settling.wrapping_add(1);
        self.epoch = self.epoch.wrapping_add(1);
    }

    /// The main queue's next turn after a drop: settling down by one.
    pub fn settle(&mut self) {
        self.settling = self.settling.wrapping_sub(1);
    }

    /// `value(_:)` with the density scoped or not and the store active or not; `drops_during_compute`
    /// drops land while a tracked compute runs (before the keep check).
    pub fn read(&mut self, scoped: bool, active: bool, drops_during_compute: u32) -> MemoRead {
        if scoped {
            return MemoRead::Scoped;
        }
        let now = self.epoch;
        if self.settling != 0 {
            return MemoRead::Settling;
        }
        if self.has_stored && now == self.stored_epoch && active == self.stored_active {
            return MemoRead::Hit;
        }
        for _ in 0..drops_during_compute {
            self.drop_value();
        }
        if self.epoch == now && self.settling == 0 {
            self.has_stored = true;
            self.stored_epoch = now;
            self.stored_active = active;
            MemoRead::Kept { tracks_store: active }
        } else {
            MemoRead::Discarded { tracks_store: active }
        }
    }
}

/// One step of a memo's life, for [`run`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "event")]
pub enum MemoEvent {
    /// A read.
    #[serde(rename_all = "camelCase")]
    Read {
        /// A scoped density is set.
        #[serde(default)]
        scoped: bool,
        /// The tunable store is active.
        #[serde(default)]
        active: bool,
        /// Drops that land while the compute runs.
        #[serde(default)]
        drops_during_compute: u32,
    },
    /// An input changed (`drop()`).
    Drop,
    /// The main queue turned once (one settling drop closes).
    Settle,
}

/// Runs `events` from `state`; the reads' outcomes (None for drops and settles) and the end state.
pub fn run(mut state: MemoState, events: &[MemoEvent]) -> (Vec<Option<MemoRead>>, MemoState) {
    let outcomes = events
        .iter()
        .map(|event| match *event {
            MemoEvent::Read { scoped, active, drops_during_compute } => {
                Some(state.read(scoped, active, drops_during_compute))
            }
            MemoEvent::Drop => {
                state.drop_value();
                None
            }
            MemoEvent::Settle => {
                state.settle();
                None
            }
        })
        .collect();
    (outcomes, state)
}
