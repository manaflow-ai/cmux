//! The start of the output store at the start of the daemon: it applies the
//! mode, removes the files that no terminal of the session owns, reads where
//! each terminal's stream ends on disk, and starts the writer thread.

use std::sync::{Arc, PoisonError};
use std::time::Instant;

use super::{
    OutputStore, PersistenceMode, PersistencePolicy, memory_budget, segments, snapshot, tail,
};
use crate::Mux;
use crate::startup_timings::StartupTimings;

impl OutputStore {
    /// Start the background writer. Without a directory there is nothing to
    /// write and no thread starts.
    ///
    /// The mode is applied here, before any terminal is adopted or
    /// respawned: memory mode removes what an earlier mode left, the other
    /// modes drop the files of terminals no longer in the session, and each
    /// terminal's stream continues at the offset its snapshot recorded.
    ///
    /// `parts` gets 3 entries of the start log, each timed here: the prune
    /// without its parked trim, the parked trim with the count of its
    /// rewrites, and the scans for the stream ends. A part that did not run
    /// (memory mode has no parked trim) has 0.
    pub(crate) fn start(&self, mux: &Arc<Mux>, parts: &mut StartupTimings) -> anyhow::Result<()> {
        let Some(directory) = self.directory.as_deref() else { return Ok(()) };
        let policy = PersistencePolicy::current(mux);
        eprintln!(
            "cmux-tui: terminal output store: mode {}, at most {} bytes per terminal, {} in total",
            policy.mode.as_str(),
            policy.max_bytes_per_terminal,
            policy.max_total_bytes
        );
        self.cache_policy(policy);
        self.set_resident_trigger(memory_budget::effective(policy.memory_total_bytes));
        self.full.set_enabled(policy.mode == PersistenceMode::Full);
        self.set_tail_enabled(policy.mode == PersistenceMode::Snapshot);
        let pruning = Instant::now();
        let trim = {
            let _pass = self.lock_pass();
            snapshot::prune(mux, self, policy)
        };
        parts.record("mux.build.output_store.prune", pruning.elapsed().saturating_sub(trim.took));
        parts.record_rows(
            "mux.build.output_store.parked_trim".to_owned(),
            trim.took,
            u64::try_from(trim.rewrites).unwrap_or(u64::MAX),
        );
        let scanning = Instant::now();
        let mut resume = snapshot::stream_ends(directory);
        // A tail reaches past its snapshot: a re-adopted terminal's stream
        // continues after it, so no stored offset is used twice.
        for (terminal_id, (generation, end)) in tail::stream_ends(directory) {
            let known = resume.entry(terminal_id).or_insert_with(|| (generation.clone(), end));
            if known.0 == generation {
                known.1 = known.1.max(end);
            }
        }
        *self.resume.lock().unwrap_or_else(PoisonError::into_inner) = resume;
        if policy.mode == PersistenceMode::Full {
            *self.segment_resume.lock().unwrap_or_else(PoisonError::into_inner) =
                segments::all_stream_ends(directory);
        }
        parts.record("mux.build.output_store.stream_ends", scanning.elapsed());
        self.writer.start(Arc::downgrade(mux))
    }
}
