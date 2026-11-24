//! The Mac is away (RFD 0007, "The Mac goes away"): a read of a file not fetched yet waits up to
//! [`crate::link::AWAY_WAIT`], then fails with `EHOSTDOWN`, and "the session tells the agent
//! once, in its context, that the Mac is away and which reads failed; it does not retry on its
//! own". [`Away`] keeps the episodes: the first failed read of one starts it, the reads that fail
//! within [`Away::gather`] after it are named in the one [`Report`] its teller gets, and the
//! failures after that are counted in no second report. A new stream from the Mac ([`Away::back`])
//! ends the episode, so the next failure starts another.

use std::collections::BTreeSet;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

/// The most paths a [`Report`] names; the rest are only counted.
pub const MAX_PATHS: usize = 20;
/// How long an episode gathers failed reads before its report goes. A tool that reads many files
/// (`git status`, a build) fails them within about one [`crate::link::AWAY_WAIT`] of each other.
pub const GATHER: Duration = Duration::from_secs(2);

/// What the agent is told about one episode.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    /// Which episode of this projection it is (1 for the first).
    pub episode: u64,
    /// The first [`MAX_PATHS`] distinct paths whose reads failed, in the folder, sorted.
    pub paths: Vec<String>,
    /// How many distinct paths failed in all (at least `paths.len()`).
    pub failed: usize,
    /// The Mac came back before the report went.
    pub back: bool,
}

type Teller = Box<dyn Fn(Report) + Send + Sync>;

#[derive(Default)]
struct Episode {
    /// The current episode's number (0 before the first).
    number: u64,
    /// Failed paths of the current episode, while it gathers.
    gathering: Option<BTreeSet<String>>,
    /// The current episode was reported: nothing more is told until [`Away::back`].
    told: bool,
    /// [`Away::back`] came while the episode gathered.
    back: bool,
}

/// The away episodes of one projection.
pub struct Away {
    state: Mutex<Episode>,
    gather: Duration,
    tell: Teller,
}

impl Away {
    /// Episodes whose report goes to `tell`, [`GATHER`] after each one's first failed read.
    #[must_use]
    pub fn new(tell: impl Fn(Report) + Send + Sync + 'static) -> Arc<Self> {
        Self::with_gather(GATHER, tell)
    }

    /// [`Away::new`] gathering for `gather`.
    #[must_use]
    pub fn with_gather(
        gather: Duration,
        tell: impl Fn(Report) + Send + Sync + 'static,
    ) -> Arc<Self> {
        Arc::new(Self { state: Mutex::default(), gather, tell: Box::new(tell) })
    }

    /// How long an episode gathers.
    #[must_use]
    pub fn gather(&self) -> Duration {
        self.gather
    }

    /// A read of `path` (relative to the folder) failed because the Mac is away. The first of an
    /// episode starts it and schedules its report.
    pub fn failed(self: &Arc<Self>, path: &str) {
        let start = {
            let mut state = self.lock();
            if state.told {
                return;
            }
            match state.gathering.as_mut() {
                Some(paths) => {
                    paths.insert(path.to_owned());
                    None
                }
                None => {
                    state.number += 1;
                    state.back = false;
                    state.gathering = Some(BTreeSet::from([path.to_owned()]));
                    Some(state.number)
                }
            }
        };
        let Some(episode) = start else { return };
        let away = Arc::clone(self);
        let spawned = std::thread::Builder::new().name("projection-away".into()).spawn(move || {
            std::thread::sleep(away.gather);
            away.report(episode);
        });
        if spawned.is_err() {
            self.report(episode);
        }
    }

    /// The Mac attached a new stream: the episode ends (its report still goes if it gathers).
    pub fn back(&self) {
        let mut state = self.lock();
        if state.gathering.is_some() {
            state.back = true;
        }
        state.told = false;
    }

    /// Ends episode `episode`'s gathering and tells its report.
    fn report(&self, episode: u64) {
        let report = {
            let mut state = self.lock();
            if state.number != episode {
                return;
            }
            let Some(paths) = state.gathering.take() else { return };
            // Back before the report: the next failure starts a new episode.
            state.told = !state.back;
            let failed = paths.len();
            Report {
                episode,
                paths: paths.into_iter().take(MAX_PATHS).collect(),
                failed,
                back: state.back,
            }
        };
        (self.tell)(report);
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Episode> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }
}

#[cfg(test)]
#[path = "away_tests.rs"]
mod tests;
