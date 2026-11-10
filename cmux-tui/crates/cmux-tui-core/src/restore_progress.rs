//! What the owner's session restore is doing now (`identify` while it
//! restores).
//!
//! An owner binds its socket before it restores its session
//! (server/restoring.rs). Until the restore ends it answers `identify` and
//! `server-stats` from this record (`lifecycle_ready: false` and a `restore`
//! object) and parks every other request. A client can then tell a restore
//! that advances from one that hangs: a restore that replayed about 12M
//! journal rows took 26 minutes, every identify went unanswered for that
//! long, and the owner was taken for hung and replaced again and again.
//!
//! The restore steps report here as they run: the phase, `done`/`total` where
//! the step knows them, and when the restore last advanced. One record per
//! process; only an owner's restore reads it.

use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// The restore step that runs now, in restore order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RestorePhase {
    /// Session locks, an interrupted output cleanup swap, the connection.
    RegistryOpen,
    Schema,
    Migrations,
    /// The integrity check and the resource invariants.
    Integrity,
    /// The registry's saved state read into memory.
    Snapshot,
    /// The agent roster: its snapshot, then the journal tail after it
    /// (`done`/`total` journal rows; a reducer version change folds them all).
    AgentRoster,
    MuxBuild,
    Browsers,
    HostAdoption,
    Reconcile,
    /// Ephemeral workspaces, lost terminals, hooks and background workers.
    Finish,
}

impl RestorePhase {
    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::RegistryOpen => "registry_open",
            Self::Schema => "schema",
            Self::Migrations => "migrations",
            Self::Integrity => "integrity",
            Self::Snapshot => "snapshot",
            Self::AgentRoster => "agent_roster",
            Self::MuxBuild => "mux_build",
            Self::Browsers => "browsers",
            Self::HostAdoption => "host_adoption",
            Self::Reconcile => "reconcile",
            Self::Finish => "finish",
        }
    }
}

struct Step {
    phase: RestorePhase,
    done: Option<u64>,
    total: Option<u64>,
    last_advance: Instant,
}

/// The restore's progress: a phase change or a new `done` count advances it.
pub(crate) struct RestoreProgress {
    started: Instant,
    step: Mutex<Step>,
}

impl RestoreProgress {
    fn new() -> Self {
        let now = Instant::now();
        Self {
            started: now,
            step: Mutex::new(Step {
                phase: RestorePhase::RegistryOpen,
                done: None,
                total: None,
                last_advance: now,
            }),
        }
    }

    /// This process's record. The clock starts at the first call: the owner
    /// makes it when it binds its socket, before the restore.
    pub(crate) fn global() -> &'static Self {
        static PROGRESS: OnceLock<RestoreProgress> = OnceLock::new();
        PROGRESS.get_or_init(Self::new)
    }

    fn step(&self) -> std::sync::MutexGuard<'_, Step> {
        self.step.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// `phase` starts now; its counts are not known yet.
    pub(crate) fn enter(&self, phase: RestorePhase) {
        *self.step() = Step { phase, done: None, total: None, last_advance: Instant::now() };
    }

    /// The phase did `done` of `total` (when known). Only a new `done`
    /// advances the restore.
    pub(crate) fn advance(&self, done: u64, total: Option<u64>) {
        let mut step = self.step();
        step.total = total;
        if step.done != Some(done) {
            step.done = Some(done);
            step.last_advance = Instant::now();
        }
    }

    /// The wire form: the phase, its counts (null when unknown), the time
    /// since the restore started, and when (in that time) it last advanced.
    /// A restore that hangs keeps `last_advance_ms` while `elapsed_ms` grows.
    pub(crate) fn to_json(&self) -> Value {
        let step = self.step();
        let ms = |took: Duration| u64::try_from(took.as_millis()).unwrap_or(u64::MAX);
        json!({
            "phase": step.phase.name(),
            "done": step.done,
            "total": step.total,
            "elapsed_ms": ms(self.started.elapsed()),
            "last_advance_ms": ms(step.last_advance.saturating_duration_since(self.started)),
        })
    }
}

/// [`RestoreProgress::enter`] on this process's record.
pub(crate) fn enter(phase: RestorePhase) {
    RestoreProgress::global().enter(phase);
}

/// [`RestoreProgress::advance`] on this process's record.
pub(crate) fn advance(done: u64, total: Option<u64>) {
    RestoreProgress::global().advance(done, total);
}

/// Test hook (fault injection, debug builds): `CMUX_TUI_TEST_RESTORE_DELAY_MS`
/// makes the agent roster step this much slower, advancing every 50 ms as a
/// long journal fold does, so a test can ask the owner while it restores.
pub(crate) fn test_delay() {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("CMUX_TUI_TEST_RESTORE_DELAY_MS").ok().and_then(|ms| ms.parse::<u64>().ok())
    {
        const STEP: Duration = Duration::from_millis(50);
        let steps = ms.div_ceil(50);
        for done in 0..steps {
            advance(done, Some(steps));
            std::thread::sleep(STEP);
        }
        advance(steps, Some(steps));
    }
}

#[cfg(test)]
mod tests {
    use super::{RestorePhase, RestoreProgress};

    #[test]
    fn a_new_count_advances_the_restore_and_a_repeated_one_does_not() {
        let progress = RestoreProgress::new();
        progress.enter(RestorePhase::AgentRoster);
        progress.advance(1, Some(10));
        let first = progress.to_json();
        assert_eq!(first["phase"], "agent_roster");
        assert_eq!(first["done"], 1);
        assert_eq!(first["total"], 10);
        std::thread::sleep(std::time::Duration::from_millis(20));
        progress.advance(1, Some(10));
        let stalled = progress.to_json();
        assert_eq!(stalled["last_advance_ms"], first["last_advance_ms"], "{stalled}");
        assert!(stalled["elapsed_ms"].as_u64() >= Some(20), "{stalled}");
        progress.advance(2, Some(10));
        let advanced = progress.to_json();
        assert!(
            advanced["last_advance_ms"].as_u64() > first["last_advance_ms"].as_u64(),
            "{advanced}"
        );
        progress.enter(RestorePhase::HostAdoption);
        let next = progress.to_json();
        assert_eq!(next["phase"], "host_adoption");
        assert!(next["done"].is_null() && next["total"].is_null(), "{next}");
    }
}
