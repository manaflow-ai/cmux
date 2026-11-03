//! The registry open as a long job (`registry.open`): on a large or cold
//! registry its schema, migration, integrity and invariant steps can take
//! seconds before the owner accepts clients.

use rusqlite::Connection;

use crate::long_jobs::{Blocks, LongJobGuard, LongJobs, SqliteHeartbeat};
use crate::startup_timings::StartupTimings;

/// The open's timed steps, in order.
const OPEN_STEPS: [&str; 4] = [
    "registry.schema",
    "registry.migrations",
    "registry.integrity_check",
    "registry.resource_invariants",
];

pub(super) struct OpenProgress<'c> {
    // Field order: the heartbeat handler is cleared before the job ends.
    _beat: SqliteHeartbeat<'c>,
    job: LongJobGuard,
}

impl<'c> OpenProgress<'c> {
    /// Starts the job and beats it while statements run on `connection`.
    /// Drop it before the connection moves.
    pub(super) fn start(connection: &'c Connection) -> Self {
        let job = LongJobs::start(
            "registry.open",
            "Opening the saved session",
            &[Blocks::Startup, Blocks::Workspaces],
        )
        .unit("steps");
        job.step(0, OPEN_STEPS.len() as u64, OPEN_STEPS[0]);
        Self { _beat: job.beat_during_sqlite(connection), job }
    }

    /// Ends the step `step` in `timings` and in the job.
    pub(super) fn lap(&self, timings: &mut StartupTimings, step: &'static str) {
        timings.lap(step);
        let index = OPEN_STEPS.iter().position(|name| *name == step).map_or(0, |at| at + 1);
        self.job.step(
            index as u64,
            OPEN_STEPS.len() as u64,
            OPEN_STEPS.get(index).copied().unwrap_or(step),
        );
    }
}
