//! The restart budget (H12): every stop of a supervised thing is counted, with its cause, in a
//! persisted per-day ledger. Above the budget the supervisor stops restarting and its health
//! reads [`BudgetState::Exceeded`] with the causes, so a restart loop never looks like normal
//! life (leo-workspace `tools/daemon_stops.py`).
//!
//! The day is the UTC calendar day of the wall clock: the ledger outlives the process and the
//! boot, so no monotonic clock can key it. A wall clock that jumps back only reopens a day it
//! already counted; one that jumps ahead starts a fresh day, which is what a person reads as
//! "today".

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// Most stop records kept per day; counts go on past it.
const KEPT_PER_DAY: usize = 64;

/// Why a supervised thing stopped.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum StopCause {
    /// The process was gone by its recorded identity (crashed, killed, OOM).
    Died(String),
    /// The progress probe failed for the whole bound.
    NoProgress(String),
    /// The thing stopped itself for a restart (a store repair, a fatal task).
    SelfStop(String),
    /// An update replaced it (make-before-break swap): counted, never against the budget.
    Update(String),
    /// A person or a command stopped it on purpose: counted, never against the budget, and
    /// never respawned ([`crate::intent`]).
    Intentional(String),
}

impl StopCause {
    /// Whether this stop is a fault the budget counts. Updates and intentional stops are not.
    pub fn counts(&self) -> bool {
        matches!(self, Self::Died(_) | Self::NoProgress(_) | Self::SelfStop(_))
    }
}

/// One counted stop.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stop {
    pub at_ms: u64,
    pub cause: StopCause,
}

/// The ledger of one day.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Ledger {
    /// Days since the Unix epoch, UTC.
    pub day: u64,
    /// Stops that count against the budget today.
    pub faults: u32,
    /// Every stop today, counted or not.
    pub stops: u32,
    /// The latest stops, oldest first, at most [`KEPT_PER_DAY`].
    pub recent: Vec<Stop>,
}

/// Where the budget stands.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "state")]
pub enum BudgetState {
    Within {
        faults: u32,
        budget: u32,
    },
    /// `restart-budget-exceeded`: the supervisor restarts no more today.
    #[serde(rename = "restart-budget-exceeded")]
    Exceeded {
        faults: u32,
        budget: u32,
        causes: Vec<StopCause>,
    },
}

impl BudgetState {
    pub fn exceeded(&self) -> bool {
        matches!(self, Self::Exceeded { .. })
    }
}

/// A persisted per-day restart budget.
#[derive(Clone, Debug)]
pub struct Budget {
    path: PathBuf,
    /// Fault stops allowed per day before the supervisor holds.
    pub per_day: u32,
}

impl Budget {
    pub fn new(path: impl Into<PathBuf>, per_day: u32) -> Self {
        Self { path: path.into(), per_day }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Today's ledger (empty when the file is missing, unreadable or from another day).
    pub fn today(&self) -> Ledger {
        self.today_at(now_ms())
    }

    pub fn today_at(&self, now_ms: u64) -> Ledger {
        let day = day_of(now_ms);
        std::fs::read(&self.path)
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Ledger>(&bytes).ok())
            .filter(|l| l.day == day)
            .unwrap_or(Ledger { day, ..Ledger::default() })
    }

    /// Count one stop, persist it, and answer where the budget stands after it.
    pub fn record(&self, cause: StopCause) -> std::io::Result<BudgetState> {
        self.record_at(cause, now_ms())
    }

    pub fn record_at(&self, cause: StopCause, now_ms: u64) -> std::io::Result<BudgetState> {
        self.record_with(cause, now_ms, &crate::record::write_file)
    }

    /// [`Self::record_at`] through the caller's own atomic writer (acpmux writes under its held
    /// home only).
    pub fn record_with(
        &self,
        cause: StopCause,
        now_ms: u64,
        write: crate::record::Writer<'_>,
    ) -> std::io::Result<BudgetState> {
        let mut ledger = self.today_at(now_ms);
        ledger.stops = ledger.stops.saturating_add(1);
        if cause.counts() {
            ledger.faults = ledger.faults.saturating_add(1);
        }
        ledger.recent.push(Stop { at_ms: now_ms, cause });
        if ledger.recent.len() > KEPT_PER_DAY {
            let extra = ledger.recent.len() - KEPT_PER_DAY;
            ledger.recent.drain(..extra);
        }
        let bytes = serde_json::to_vec(&ledger).map_err(std::io::Error::other)?;
        write(&self.path, &bytes)?;
        Ok(self.state_of(&ledger))
    }

    /// Where the budget stands now.
    pub fn state(&self) -> BudgetState {
        self.state_of(&self.today())
    }

    pub fn state_of(&self, ledger: &Ledger) -> BudgetState {
        if ledger.faults > self.per_day {
            BudgetState::Exceeded {
                faults: ledger.faults,
                budget: self.per_day,
                causes: ledger
                    .recent
                    .iter()
                    .filter(|s| s.cause.counts())
                    .map(|s| s.cause.clone())
                    .collect(),
            }
        } else {
            BudgetState::Within { faults: ledger.faults, budget: self.per_day }
        }
    }
}

/// Milliseconds since the Unix epoch on the wall clock.
pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn day_of(ms: u64) -> u64 {
    ms / 86_400_000
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: u64 = 86_400_000;

    fn budget(tag: &str, per_day: u32) -> Budget {
        let dir =
            std::env::temp_dir().join(format!("supervise-budget-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        Budget::new(dir.join("stops.json"), per_day)
    }

    #[test]
    fn faults_above_the_budget_hold_with_their_causes_and_a_new_day_starts_over() {
        let b = budget("hold", 2);
        let t = 20_000 * DAY + 5;
        assert!(!b.record_at(StopCause::Died("sigkill".into()), t).unwrap().exceeded());
        assert!(!b.record_at(StopCause::SelfStop("74".into()), t + 1).unwrap().exceeded());
        let over = b.record_at(StopCause::NoProgress("60s".into()), t + 2).unwrap();
        match over {
            BudgetState::Exceeded { faults, budget, causes } => {
                assert_eq!((faults, budget), (3, 2));
                assert_eq!(causes.len(), 3);
            }
            other => panic!("not exceeded: {other:?}"),
        }
        // Persisted: another reader sees the same day.
        let again = Budget::new(b.path().to_owned(), 2);
        assert!(again.state_of(&again.today_at(t + 3)).exceeded());
        // The next day starts with nothing.
        assert_eq!(again.today_at(t + DAY).faults, 0);
        let _ = std::fs::remove_dir_all(b.path().parent().unwrap());
    }

    #[test]
    fn updates_and_intentional_stops_never_spend_the_budget() {
        let b = budget("free", 0);
        let t = 20_001 * DAY;
        for i in 0..5 {
            let s = b.record_at(StopCause::Update(format!("v{i}")), t + i).unwrap();
            assert!(!s.exceeded());
            assert!(!b.record_at(StopCause::Intentional("quit".into()), t + i).unwrap().exceeded());
        }
        let ledger = b.today_at(t + 9);
        assert_eq!((ledger.stops, ledger.faults), (10, 0));
        let _ = std::fs::remove_dir_all(b.path().parent().unwrap());
    }
}
