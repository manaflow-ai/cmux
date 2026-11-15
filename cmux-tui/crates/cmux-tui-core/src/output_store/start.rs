//! The start of the output store at the start of the daemon: it applies the
//! mode, removes the files that no terminal of the session owns, reads where
//! each terminal's stream ends on disk, and starts the writer thread.

use std::sync::{Arc, PoisonError};

use super::{
    OutputStore, PersistenceMode, PersistencePolicy, memory_budget, segments, snapshot, tail,
};
use crate::Mux;

impl OutputStore {
    /// Start the background writer. Without a directory there is nothing to
    /// write and no thread starts.
    ///
    /// The mode is applied here, before any terminal is adopted or
    /// respawned: memory mode removes what an earlier mode left, the other
    /// modes drop the files of terminals no longer in the session, and each
    /// terminal's stream continues at the offset its snapshot recorded.
    pub(crate) fn start(&self, mux: &Arc<Mux>) -> anyhow::Result<()> {
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
        {
            let _pass = self.lock_pass();
            snapshot::prune(mux, self, policy);
        }
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
        self.writer.start(Arc::downgrade(mux))
    }
}
