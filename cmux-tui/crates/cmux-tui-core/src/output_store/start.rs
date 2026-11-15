//! The start of the output store at the start of the daemon: it applies the
//! mode, removes the files that no terminal of the session owns, reads where
//! each terminal's stream ends on disk, and starts the writer thread.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, PoisonError};
use std::time::{Duration, Instant};

use super::{
    OutputStore, PersistenceMode, PersistencePolicy, memory_budget, parked_trim, segments,
    snapshot, tail,
};
use crate::Mux;
use crate::resource::TerminalPublicId;
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
        let reads = {
            let _pass = self.lock_pass();
            prune_at_start(mux, self, policy)
        };
        let trim = reads.trim;
        parts.record(
            "mux.build.output_store.prune",
            pruning.elapsed().saturating_sub(trim.took + reads.ends_took),
        );
        parts.record_rows(
            "mux.build.output_store.parked_trim".to_owned(),
            trim.took,
            u64::try_from(trim.rewrites).unwrap_or(u64::MAX),
        );
        let scanning = Instant::now();
        let mut resume = reads.stream_ends;
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
        parts.record("mux.build.output_store.stream_ends", reads.ends_took + scanning.elapsed());
        self.writer.start(Arc::downgrade(mux))
    }
}

/// The parked trim of the start's prune ([`prune_at_start`]): how long it took
/// and how many rewrites of a snapshot file it ran. Zero also when the prune
/// did not come to it.
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct ParkedTrimLap {
    pub(super) took: Duration,
    pub(super) rewrites: usize,
}

/// What the start reads from the snapshot files.
#[derive(Debug, Default)]
pub(super) struct StartReads {
    pub(super) trim: ParkedTrimLap,
    /// How long the read of the stream ends took.
    pub(super) ends_took: Duration,
    /// The stream end each snapshot recorded, by terminal: (generation, end).
    pub(super) stream_ends: HashMap<TerminalPublicId, (String, u64)>,
}

/// The parked trim of the snapshots of `parked`, then the stream end of each snapshot that stays. `low`: the
/// free-disk guard (`parked_trim::disk_low`).
pub(super) fn trim_parked_and_read_ends(
    directory: &Path,
    parked: &HashSet<TerminalPublicId>,
    now_ms: u64,
    max_total_bytes: u64,
    low: bool,
) -> StartReads {
    let trimming = Instant::now();
    let rewrites = parked_trim::run_with(directory, parked, now_ms, max_total_bytes, low);
    let trim = ParkedTrimLap { took: trimming.elapsed(), rewrites };
    let reading = Instant::now();
    let stream_ends = snapshot::stream_ends(directory);
    StartReads { trim, ends_took: reading.elapsed(), stream_ends }
}

/// The start's prune: [`snapshot::remove_unowned`], then the parked trim and where each snapshot's stream ends.
/// Without a parked trim (memory mode, a registry that cannot be read) the stream ends of the files that stay are
/// still read.
fn prune_at_start(mux: &Mux, store: &OutputStore, policy: PersistencePolicy) -> StartReads {
    let Some(directory) = store.directory() else { return StartReads::default() };
    let Some(parked) = snapshot::remove_unowned(mux, store, directory, policy) else {
        let reading = Instant::now();
        let stream_ends = snapshot::stream_ends(directory);
        return StartReads { ends_took: reading.elapsed(), stream_ends, ..StartReads::default() };
    };
    let now_ms = crate::workspace_registry::unix_epoch_ms().unwrap_or(0);
    // The read of the free disk is a part of the trim's lap.
    let checking = Instant::now();
    let low = parked_trim::low_disk(directory, policy.min_free_disk_bytes);
    let checked = checking.elapsed();
    let mut reads =
        trim_parked_and_read_ends(directory, &parked, now_ms, policy.parked_max_total_bytes, low);
    reads.trim.took += checked;
    reads
}
