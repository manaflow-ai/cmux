//! Repeats of one failed request. This file has the types that the writer and the tests use;
//! the rule is not here yet: each record is written.

use std::marker::PhantomData;

use super::Label;

/// The length of a run's window.
pub(super) const REPEAT_WINDOW_MS: u64 = 60_000;
/// The runs followed at one time.
pub(super) const RUNS: usize = 8;

/// What makes two failed requests equal.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct Key {
    pub(super) name: Option<Label>,
    pub(super) error: Label,
    pub(super) client_kind: Option<Label>,
}

/// What [`Repeats::offer`] says of a record.
pub(super) enum Offered<T> {
    /// Write `record` now: its line stands for `stands_for` equal records. `ended` is the count
    /// of a run that ended: its line goes first.
    Write { ended: Option<(T, u64)>, record: T, stands_for: u64 },
    /// No line: the record is counted.
    Counted,
}

/// The runs of equal failed requests. `T` is the record.
pub(super) struct Repeats<T> {
    records: PhantomData<T>,
}

impl<T> Default for Repeats<T> {
    fn default() -> Self {
        Self { records: PhantomData }
    }
}

impl<T> Repeats<T> {
    /// A failed request with `key` that arrived at `at_ms`.
    pub(super) fn offer(&mut self, _key: Key, _at_ms: u64, record: T) -> Offered<T> {
        Offered::Write { ended: None, record, stands_for: 1 }
    }

    /// Whether a count waits for the end of its window.
    pub(super) fn waits(&self) -> bool {
        false
    }

    /// A count whose window ended at `now_ms`.
    pub(super) fn take_due(&mut self, _now_ms: u64) -> Option<(T, u64)> {
        None
    }

    /// The milliseconds from `now_ms` to the first end of a window with a count that waits.
    pub(super) fn wait_ms(&self, _now_ms: u64) -> Option<u64> {
        None
    }
}
