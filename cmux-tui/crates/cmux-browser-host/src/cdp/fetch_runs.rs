//! The engine's record of running host fetches, by the gate's `fetchId`, so
//! the gate can cancel one (its cell timed out, or the session ended).
//! Bounded: an entry goes when its fetch returns, and a cancel that found
//! no running fetch (it came first, or late) is swept after a short time.

use std::collections::HashMap;
use std::time::{Duration, Instant};

/// How long a cancel waits for its fetch to start. The gate cancels only
/// fetches it handed to the engine, so the fetch starts within moments or
/// has already returned.
pub(super) const EARLY_CANCEL_TTL: Duration = Duration::from_secs(30);

#[derive(Debug, Default)]
struct Run {
    target: Option<String>,
    cancelled: bool,
}

#[derive(Debug, Default)]
pub(crate) struct Runs {
    running: HashMap<String, Run>,
    /// Cancels that found no running fetch, with when they came.
    early: HashMap<String, Instant>,
    /// Shells a fetch keeps across its redirect hops, one per origin
    /// (origin, target), until the gate says the fetch is done.
    kept: HashMap<String, Vec<(String, String)>>,
}

impl Runs {
    /// A fetch starts; false when its cancel came first.
    pub(super) fn start(&mut self, id: &str, now: Instant) -> bool {
        self.sweep(now);
        if self.early.remove(id).is_some() {
            return false;
        }
        self.running.insert(id.to_owned(), Run::default());
        true
    }

    /// The fetch returned: its entry goes.
    pub(super) fn finish(&mut self, id: &str) {
        self.running.remove(id);
    }

    /// Records the tab the fetch runs in; true when it was cancelled.
    pub(super) fn set_target(&mut self, id: &str, target: &str) -> bool {
        self.running.get_mut(id).is_some_and(|run| {
            run.target = Some(target.to_owned());
            run.cancelled
        })
    }

    pub(super) fn is_cancelled(&self, id: &str) -> bool {
        self.running.get(id).is_some_and(|run| run.cancelled)
    }

    /// Cancels a fetch: the tab of a running one (None while it has none
    /// yet). A cancel that finds no running fetch is kept briefly, so a
    /// fetch that has not started yet fails when it starts.
    pub(super) fn cancel(&mut self, id: &str, now: Instant) -> Option<String> {
        self.sweep(now);
        match self.running.get_mut(id) {
            Some(run) => {
                run.cancelled = true;
                run.target.clone()
            }
            None => {
                self.early.insert(id.to_owned(), now);
                None
            }
        }
    }

    /// The fetch that runs in (or keeps) `target`, if any.
    pub(super) fn fetch_in(&self, target: &str) -> Option<String> {
        self.running
            .iter()
            .find(|(_, run)| run.target.as_deref() == Some(target))
            .map(|(id, _)| id.clone())
            .or_else(|| {
                self.kept
                    .iter()
                    .find(|(_, shells)| shells.iter().any(|(_, t)| t == target))
                    .map(|(id, _)| id.clone())
            })
    }

    /// The shell a fetch keeps for `origin`, if any.
    pub(super) fn kept_shell(&self, id: &str, origin: &str) -> Option<String> {
        self.kept.get(id)?.iter().find(|(o, _)| o == origin).map(|(_, target)| target.clone())
    }

    pub(super) fn keep_shell(&mut self, id: &str, origin: &str, target: &str) {
        self.kept.entry(id.to_owned()).or_default().push((origin.to_owned(), target.to_owned()));
    }

    /// The fetch is done (every hop): the shells it kept, to close.
    pub(super) fn done(&mut self, id: &str) -> Vec<String> {
        self.kept.remove(id).unwrap_or_default().into_iter().map(|(_, target)| target).collect()
    }

    fn sweep(&mut self, now: Instant) {
        self.early.retain(|_, at| now.saturating_duration_since(*at) < EARLY_CANCEL_TTL);
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.running.len() + self.early.len() + self.kept.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_finished_fetch_leaves_no_entry() {
        let mut runs = Runs::default();
        let now = Instant::now();
        assert!(runs.start("f1", now));
        assert!(!runs.set_target("f1", "T1"));
        runs.finish("f1");
        assert_eq!(runs.len(), 0);
    }

    #[test]
    fn a_cancel_that_came_first_fails_the_fetch_when_it_starts() {
        let mut runs = Runs::default();
        let now = Instant::now();
        assert_eq!(runs.cancel("f1", now), None);
        assert!(!runs.start("f1", now), "the fetch fails at once");
        assert_eq!(runs.len(), 0, "the early cancel is used up");
    }

    #[test]
    fn a_running_fetch_is_cancelled_in_its_tab() {
        let mut runs = Runs::default();
        let now = Instant::now();
        assert!(runs.start("f1", now));
        assert!(!runs.set_target("f1", "T1"));
        assert_eq!(runs.cancel("f1", now), Some("T1".to_owned()));
        assert!(runs.is_cancelled("f1"));
        runs.finish("f1");
        assert_eq!(runs.len(), 0);
    }

    /// No per-fetch leak: a cancel that came after its fetch returned is
    /// swept by a later call.
    #[test]
    fn a_late_cancel_is_swept() {
        let mut runs = Runs::default();
        let now = Instant::now();
        assert!(runs.start("f1", now));
        runs.finish("f1");
        assert_eq!(runs.cancel("f1", now), None);
        let later = now + EARLY_CANCEL_TTL + Duration::from_secs(1);
        assert!(runs.start("f2", later));
        runs.finish("f2");
        assert_eq!(runs.len(), 0, "the late cancel stayed");
    }
}
