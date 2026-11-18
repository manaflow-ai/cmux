//! Repeats of one failed request are counted, not written. A client that sends the same refused
//! request in a loop gets a line for the first one at once; after it, the log holds at most one
//! line of that run for each window: the newest equal record, with the count of the equal records
//! since the run's last line.
//!
//! The rule has no clock of its own: each time is a record's own `at_ms` or the caller's.

use super::Label;

/// The length of a run's window. Equal records inside it are counted; the count is due at its end.
pub(super) const REPEAT_WINDOW_MS: u64 = 60_000;
/// The runs followed at one time. One more key ends the oldest run. Each client that fails is a
/// key of its own, so many clients that fail in turn fill the table sooner.
pub(super) const RUNS: usize = 8;

/// What makes two failed requests equal.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) struct Key {
    name: Option<Label>,
    error: Label,
    client_kind: Option<Label>,
    /// The connection's number. None for the kind `plugin`.
    client: Option<u64>,
}

impl Key {
    /// The key of a failed request of the connection with the number `client`.
    ///
    /// The log is read to find which client failed, so the failed requests of 2 clients are 2
    /// runs. Not for the kind `plugin`: each pass of the session's journal plugin is a new
    /// connection, and a key with its number would never repeat.
    pub(super) fn new(
        name: Option<Label>,
        error: Label,
        client_kind: Option<Label>,
        client: u64,
    ) -> Self {
        let client = (client_kind != Label::plugin()).then_some(client);
        Self { name, error, client_kind, client }
    }
}

struct Run<T> {
    key: Key,
    /// The time of the run's last line.
    line_ms: u64,
    /// The newest equal record since that line, and how many there were.
    waiting: Option<(T, u64)>,
}

/// What [`Repeats::offer`] says of a record.
pub(super) enum Offered<T> {
    /// Write `record` now: its line stands for `stands_for` equal records (itself and the counted
    /// ones before it). `ended` is the count of the run that lost its place to this record's new
    /// run: its line goes first.
    Write { ended: Option<(T, u64)>, record: T, stands_for: u64 },
    /// No line: the record is counted, and its run keeps it as the newest.
    Counted,
}

/// The runs of equal failed requests, by key. `T` is the record.
pub(super) struct Repeats<T> {
    runs: Vec<Run<T>>,
}

impl<T> Default for Repeats<T> {
    fn default() -> Self {
        Self { runs: Vec::with_capacity(RUNS) }
    }
}

/// Whether `time_ms` is less than one window away from a run's last line. A time before that line
/// (a request that arrived earlier and ended later, a clock that was set back) is inside too,
/// until it is a whole window before it.
fn in_window(line_ms: u64, time_ms: u64) -> bool {
    time_ms.abs_diff(line_ms) < REPEAT_WINDOW_MS
}

impl<T> Repeats<T> {
    /// A failed request with `key` that arrived at `at_ms`.
    pub(super) fn offer(&mut self, key: Key, at_ms: u64, record: T) -> Offered<T> {
        if let Some(run) = self.runs.iter_mut().find(|run| run.key == key) {
            let counted = run.waiting.take().map_or(0, |(_, count)| count);
            if in_window(run.line_ms, at_ms) {
                run.waiting = Some((record, counted.saturating_add(1)));
                return Offered::Counted;
            }
            run.line_ms = at_ms;
            return Offered::Write { ended: None, record, stands_for: counted.saturating_add(1) };
        }
        let mut ended = None;
        if self.runs.len() >= RUNS {
            let oldest = self.runs.iter().enumerate().min_by_key(|(_, run)| run.line_ms);
            if let Some(index) = oldest.map(|(index, _)| index) {
                ended = self.runs.swap_remove(index).waiting;
            }
        }
        self.runs.push(Run { key, line_ms: at_ms, waiting: None });
        Offered::Write { ended, record, stands_for: 1 }
    }

    /// Whether a count waits for the end of its window.
    pub(super) fn waits(&self) -> bool {
        self.runs.iter().any(|run| run.waiting.is_some())
    }

    /// A count whose window ended at `now_ms`: the run's newest record and how many records it
    /// stands for. The run's next window starts at `now_ms`. None when no count is due.
    pub(super) fn take_due(&mut self, now_ms: u64) -> Option<(T, u64)> {
        let run = self
            .runs
            .iter_mut()
            .find(|run| run.waiting.is_some() && !in_window(run.line_ms, now_ms))?;
        run.line_ms = now_ms;
        run.waiting.take()
    }

    /// The milliseconds from `now_ms` to the first end of a window with a count that waits: 0 when
    /// one is due, at most one window, none when no count waits.
    pub(super) fn wait_ms(&self, now_ms: u64) -> Option<u64> {
        self.runs
            .iter()
            .filter(|run| run.waiting.is_some())
            .map(|run| {
                if in_window(run.line_ms, now_ms) {
                    let end = run.line_ms.saturating_add(REPEAT_WINDOW_MS);
                    end.saturating_sub(now_ms).min(REPEAT_WINDOW_MS)
                } else {
                    0
                }
            })
            .min()
    }
}
