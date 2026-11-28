//! The spare starts' guard: no combination of harness count, spare RSS and cap loops a spare
//! through start, cap eviction and start again.
//!
//! 1. A spare the RSS cap ended is held, like one that idled out: the daemon never starts it
//!    again on its own (daemon start, the person is back, the dead-spare worker, a reserved home
//!    folder); only a new session of the person's of its harness does (`Start::Used`).
//! 2. Backstop: each harness starts at most [`MAX_STARTS`] spares on its own per [`WINDOW`]; the
//!    next waits for the window, logged once when it trips.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::Duration;

/// Spare starts on its own a harness gets per [`WINDOW`].
pub(super) const MAX_STARTS: usize = 3;
pub(super) const WINDOW: Duration = Duration::from_secs(30 * 60);

/// Who wants a spare.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Start {
    /// A session of the person's of that harness was created (`spare_note_used`): it releases a
    /// held spare and is not rate limited, since each one is a real new chat.
    Used,
    /// The daemon on its own: daemon start, the person is back, a dead spare's restart, a
    /// reserved home folder.
    Auto,
}

/// What the guard says to a spare start.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Verdict {
    Start,
    /// The cap ended this harness's spare and the person has not used the harness since.
    Held,
    /// Over its start budget for the window; `first` on the start that tripped it (log once).
    Tripped {
        first: bool,
    },
}

#[derive(Debug, Default)]
pub(super) struct SpareGuard {
    held: HashSet<String>,
    starts: HashMap<String, VecDeque<Duration>>,
    tripped: HashSet<String>,
}

impl SpareGuard {
    /// The RSS cap ended `harness`'s spare. Returns whether it was not held already (log once).
    pub fn evicted_by_cap(&mut self, harness: &str) -> bool {
        self.held.insert(harness.to_owned())
    }

    /// May a spare of `harness` start at `now`, wanted by `who`? A start it allows on its own
    /// (`Start::Auto`) is counted against the harness's budget.
    pub fn admit(&mut self, harness: &str, who: Start, now: Duration) -> Verdict {
        if who == Start::Used {
            self.held.remove(harness);
            return Verdict::Start;
        }
        if self.held.contains(harness) {
            return Verdict::Held;
        }
        let starts = self.starts.entry(harness.to_owned()).or_default();
        while starts.front().is_some_and(|at| now.saturating_sub(*at) >= WINDOW) {
            starts.pop_front();
        }
        if starts.len() >= MAX_STARTS {
            return Verdict::Tripped { first: self.tripped.insert(harness.to_owned()) };
        }
        starts.push_back(now);
        self.tripped.remove(harness);
        Verdict::Start
    }
}

#[cfg(test)]
#[path = "spare_guard_tests.rs"]
mod tests;
