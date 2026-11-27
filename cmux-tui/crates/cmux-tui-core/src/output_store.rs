//! The terminal output store: where terminal output lives, outside the
<<<<<<< ours
//! durable session journal.
//!
//! The session journal used to keep every PTY read as a `terminal.output`
//! row (about 1.2 KB of metadata, six index rows and a synced commit per
//! read). An agent TUI that redraws its cursor at 40 Hz then made the daemon
//! write about 25 MB/s while idle, and one registry grew to 41.6 GB. Output
//! now never enters the journal; the journal keeps only structural events
//! (workspaces, panes, tabs, titles, cwd, agent status, resize, exit).
//!
//! Who owns what:
//! - The daemon's Ghostty terminal of each terminal is the hot copy: screen
//!   and scrollback, capped per terminal by Ghostty's `scrollback-limit`.
//!   Attach, screen, history and copy reads already come from it.
//! - This store keeps, per terminal, the stream position (offsets of the
//!   current generation) and a small tail of raw bytes for
//!   `terminal.output_read`, and it owns what is on disk, by
//!   `terminal.persistence.mode`:
//!   - `memory`: nothing on disk. A reboot (or the loss of a terminal host)
//!     loses the output; a daemon restart still re-adopts the live hosts.
//!   - `snapshot` (default): one compressed file per terminal (screen plus
//!     recent scrollback), replaced atomically, written only when the
//!     terminal's content changed (cursor redraws write nothing), at most
//!     every [`SNAPSHOT_INTERVAL`] and at quit, and the output after it in
//!     an append-only tail file written every [`TAIL_FLUSH_INTERVAL`]
//!     (`output_store/tail.rs`; the snapshot is its compaction). A respawn
//!     after the daemon and its hosts died (a crash, a reboot) seeds the new
//!     shell with the snapshot plus its tail (REOPEN-F3). What a kill of
//!     every process loses: the output of the last [`TAIL_FLUSH_INTERVAL`]
//!     and one writer pass, plus bytes that changed nothing the content
//!     digest sees (text, size, screen, history, cursor position: a cursor
//!     redrawn in place, a color-only change), which wait in memory up to
//!     [`TAIL_IDLE_BYTES`] so an idle TUI writes nothing. An OS crash or a
//!     power loss can lose up to [`TAIL_SYNC_INTERVAL`] more: the tail files
//!     are synced together at that interval, and each at quit.
//!   - `full`: the snapshot plus every output byte in per-terminal
//!     compressed segment files (see `output_store/segments.rs`).
=======
//! durable session journal (port of feat #22937, PR 1 of 3).
//!
//! The session journal kept every PTY read as a `terminal.output` row (about
//! 1.2 KB of metadata, index rows and a synced commit per read). An agent TUI
//! that redraws its cursor at 40 Hz then made the daemon write about 25 MB/s
//! while idle. Output that never stops also moved the journal head during
//! every checkpoint capture (no stable cut), and one flooding terminal filled
//! the journal's shared terminal lane, so other terminals lost their output.
//! Output now never enters the journal; the journal keeps only structural
//! events (workspaces, panes, tabs, titles, cwd, agent status, resize, exit
//! and the `terminal.output.gap` markers of host reconnects).
//!
//! Who owns what:
//! - The daemon's Ghostty terminal of each terminal is the hot copy: screen
//!   and scrollback. Attach, screen, history and copy reads come from it.
//! - This store keeps, per terminal, the stream position (byte offsets of the
//!   current generation) and a small tail of raw bytes for
//!   `terminal.output_read`, and it owns what is on disk, by
//!   `CMUX_TUI_TERMINAL_PERSISTENCE`:
//!   - `memory`: nothing on disk.
//!   - `snapshot` (default): one compressed file per terminal (screen plus
//!     about [`SNAPSHOT_HISTORY_LINES`] recent lines), replaced atomically,
//!     written only when the terminal's content changed (cursor redraws write
//!     nothing), at most every [`SNAPSHOT_INTERVAL`], at each journal
//!     checkpoint and at quit. A daemon that re-adopts a live terminal host
//!     continues that terminal's stream at the offset its snapshot recorded.
>>>>>>> theirs
//!
//! The append path (each PTY read) only copies bytes into memory under a
//! per-terminal lock. Disk work happens on one background writer thread
//! that sleeps until a terminal has new output, then waits out the interval,
<<<<<<< ours
//! so an idle session wakes nothing (tails written since their last sync
//! wake it once more, for that sync).

mod memory_budget;
mod parked_trim;
mod recovery;
pub(crate) mod segments;
pub(crate) mod snapshot;
pub(crate) use recovery::RecoveryCut;
mod start;
mod tail;
mod writer;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};
=======
//! so an idle session wakes nothing.

pub(crate) mod snapshot;

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;
>>>>>>> theirs

use crate::Mux;
use crate::resource::TerminalPublicId;

<<<<<<< ours
/// `cmux-next.json` key: `memory`, `snapshot` (default) or `full`.
pub(crate) const PERSISTENCE_MODE_SETTING: &str = "terminal.persistence.mode";
/// `cmux-next.json` key: disk cap per terminal in bytes (mode default when unset).
pub(crate) const PERSISTENCE_MAX_PER_TERMINAL_SETTING: &str =
    "terminal.persistence.maxBytesPerTerminal";
/// `cmux-next.json` key: disk cap across terminals in bytes (mode default when unset).
pub(crate) const PERSISTENCE_MAX_TOTAL_SETTING: &str = "terminal.persistence.maxTotalBytes";
/// Process override of the mode (tests, and a way out when the settings file
/// cannot be read). Same values as the setting.
=======
/// Process setting of the mode: `memory` or `snapshot` (the default).
>>>>>>> theirs
const PERSISTENCE_MODE_ENV: &str = "CMUX_TUI_TERMINAL_PERSISTENCE";
/// Test-only shorter snapshot interval in milliseconds.
const SNAPSHOT_INTERVAL_ENV: &str = "CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS";

/// The longest a changed terminal waits before its snapshot is written.
pub(crate) const SNAPSHOT_INTERVAL: Duration = Duration::from_secs(30);
<<<<<<< ours
/// Full mode: how long new output waits before it goes to a segment file.
pub(crate) const FULL_FLUSH_INTERVAL: Duration = Duration::from_secs(3);
/// Snapshot mode: how long new output waits before it goes to the tail
/// file. The most output a kill of the daemon and its hosts loses.
pub(crate) const TAIL_FLUSH_INTERVAL: Duration = Duration::from_millis(100);
/// Snapshot mode: the tail files written since their last sync are synced
/// together, this long after the first such write (`snapshot.rs`
/// `sync_due_tails`). The most output an OS crash or a power loss adds to
/// [`TAIL_FLUSH_INTERVAL`]; a kill of every process loses none of it (the
/// page cache keeps what write(2) took), and the quit pass syncs at once.
/// It was 1 s per tail with an F_FULLFSYNC each: 40 of 45 sampled file
/// system calls of the writer thread, and on scratch files 1.7 MiB/min of
/// physical writes for 0.19 MiB/min of output, against 0.2 MiB/min at 30 s
/// (`output_store/tail_sync_tests.rs`).
pub(crate) const TAIL_SYNC_INTERVAL: Duration = Duration::from_secs(30);
/// Snapshot mode: tail bytes past which a snapshot is written (the
/// compaction), so a restore replays about this much over it; at most once
/// per [`TAIL_COMPACT_SPACING`], so a flood captures its screen under the
/// parser lock once a second, not at every pass.
const TAIL_MAX_BYTES: u64 = 1024 * 1024;
/// Snapshot mode: the least time between two tail-cap compactions.
const TAIL_COMPACT_SPACING: Duration = Duration::from_secs(1);
/// Snapshot mode: tail bytes past which the compaction does not wait for
/// its spacing (what a restore replays over the snapshot during a flood).
const TAIL_FLOOD_MAX_BYTES: u64 = 16 * 1024 * 1024;
/// Snapshot mode: the most raw bytes one tail file takes while snapshots
/// fail; past it the bytes wait in memory (capped) for a snapshot. Below
/// what a restore reads (`tail.rs` MAX_TAIL_FILE_BYTES, compressed).
const TAIL_HARD_MAX_BYTES: u64 = 32 * 1024 * 1024;
/// Snapshot mode: bytes of unchanged content (cursor redraws) a terminal
/// keeps in memory instead of the tail; past it a snapshot replaces them.
const TAIL_IDLE_BYTES: usize = 1024 * 1024;
/// Snapshot mode: unwritten tail bytes one terminal keeps while its writes
/// fail; past it the oldest go and the next snapshot starts the tail again.
const TAIL_MAX_UNWRITTEN_BYTES: usize = 8 * 1024 * 1024;
/// Snapshot mode: how long a resized terminal's size must hold before its
/// snapshot at the new size is written. Output in that window is not in the
/// tail (it continues a snapshot of the old size): the most a kill loses
/// right after a resize.
const RESIZE_SETTLE: Duration = Duration::from_secs(1);
/// The first and the longest wait before a snapshot is tried again after a
/// failed write.
const STORE_RETRY_MIN: Duration = Duration::from_secs(1);
const STORE_RETRY_MAX: Duration = Duration::from_secs(30);
/// Snapshot mode targets this many lines when sizing a replay request. The
/// replay is ultimately bounded by `MAX_SNAPSHOT_REPLAY_BYTES`, so terminals
/// with long lines keep fewer rows while short-line terminals retain much
/// older scrollback.
pub(crate) const SNAPSHOT_HISTORY_LINES: usize = 100_000;
/// Snapshot mode: total disk across terminals; the oldest terminals go first.
pub(crate) const SNAPSHOT_DEFAULT_MAX_TOTAL_BYTES: u64 = 50 * 1024 * 1024;
/// Full mode: segment bytes per terminal; the oldest segments go first.
pub(crate) const FULL_DEFAULT_MAX_PER_TERMINAL_BYTES: u64 = 100 * 1024 * 1024;
/// Full mode: segment bytes across terminals; the oldest segments go first.
pub(crate) const FULL_DEFAULT_MAX_TOTAL_BYTES: u64 = 2 * 1024 * 1024 * 1024;
/// Smallest cap a setting may ask for (smaller values are raised to it).
const MIN_CAP_BYTES: u64 = 1024 * 1024;
/// Full mode: unflushed bytes one terminal may hold before the writer is
/// woken at once (a flood does not wait out the flush interval in RAM).
const FULL_PENDING_WAKE_BYTES: usize = 8 * 1024 * 1024;
/// Raw output bytes each terminal keeps in memory for `terminal.output_read`.
pub(crate) const OUTPUT_TAIL_BYTES: usize = 64 * 1024;
/// Directory beside the registry that holds the store's files.
pub(crate) const STORE_DIRECTORY: &str = "terminal-output";
=======
/// Snapshot mode keeps the screen plus about this many recent lines.
pub(crate) const SNAPSHOT_HISTORY_LINES: usize = 2_000;
/// Snapshot mode: total disk across terminals; the oldest terminals go first.
pub(crate) const SNAPSHOT_DEFAULT_MAX_TOTAL_BYTES: u64 = 50 * 1024 * 1024;
/// Raw output bytes each terminal keeps in memory for `terminal.output_read`.
pub(crate) const OUTPUT_TAIL_BYTES: usize = 64 * 1024;
/// Directory beside the registry that holds the store's files.
const STORE_DIRECTORY: &str = "terminal-output";
/// Terminals that left this daemon whose tails stay readable (exit receipts
/// answer `terminal.output_read` after the runtime is gone); the oldest go
/// first, so at most this many times [`OUTPUT_TAIL_BYTES`] stay in memory.
const RETIRED_TAILS: usize = 64;
/// A snapshot that could not be captured or written is tried again this many
/// times before it waits for the terminal's next output.
const SNAPSHOT_RETRIES: u8 = 3;
>>>>>>> theirs

/// What the store keeps on disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PersistenceMode {
    Memory,
    Snapshot,
<<<<<<< ours
    Full,
=======
>>>>>>> theirs
}

impl PersistenceMode {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "memory" => Some(Self::Memory),
            "snapshot" => Some(Self::Snapshot),
<<<<<<< ours
            "full" => Some(Self::Full),
=======
>>>>>>> theirs
            _ => None,
        }
    }

<<<<<<< ours
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::Snapshot => "snapshot",
            Self::Full => "full",
=======
    const fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::Snapshot => "snapshot",
>>>>>>> theirs
        }
    }
}

/// The effective persistence settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PersistencePolicy {
    pub(crate) mode: PersistenceMode,
<<<<<<< ours
    /// Full mode: segment bytes per terminal. Snapshot mode: the largest
    /// uncompressed replay one snapshot may hold.
    pub(crate) max_bytes_per_terminal: u64,
    pub(crate) max_total_bytes: u64,
    /// Total scrollback RAM across terminals
    /// (`terminal.scrollback.maxTotalMemoryBytes`).
    pub(crate) memory_total_bytes: u64,
    /// Parked snapshots' disk budget (`terminal.persistence.parkedMaxTotalBytes`, `parked_trim.rs`).
    pub(crate) parked_max_total_bytes: u64,
    /// Free disk under which no parked trim rewrites a file (`terminal.persistence.minFreeDiskBytes`).
    pub(crate) min_free_disk_bytes: u64,
}

impl PersistencePolicy {
    pub(crate) fn resolve(
        mode: Option<&str>,
        per_terminal: Option<u64>,
        total: Option<u64>,
    ) -> Self {
        let mode = mode.and_then(PersistenceMode::parse).unwrap_or(PersistenceMode::Snapshot);
        let (default_per_terminal, default_total) = match mode {
            PersistenceMode::Memory => (0, 0),
            PersistenceMode::Snapshot => {
                (snapshot::MAX_SNAPSHOT_REPLAY_BYTES as u64, SNAPSHOT_DEFAULT_MAX_TOTAL_BYTES)
            }
            PersistenceMode::Full => {
                (FULL_DEFAULT_MAX_PER_TERMINAL_BYTES, FULL_DEFAULT_MAX_TOTAL_BYTES)
            }
        };
        let memory_total_bytes = memory_budget::DEFAULT_MEMORY_TOTAL_BYTES;
        if mode == PersistenceMode::Memory {
            return Self {
                mode,
                max_bytes_per_terminal: 0,
                max_total_bytes: 0,
                memory_total_bytes,
                parked_max_total_bytes: parked_trim::DEFAULT_PARKED_MAX_TOTAL_BYTES,
                min_free_disk_bytes: parked_trim::DEFAULT_MIN_FREE_DISK_BYTES,
            };
        }
        let max_total_bytes = total.unwrap_or(default_total).max(MIN_CAP_BYTES);
        let max_bytes_per_terminal =
            per_terminal.unwrap_or(default_per_terminal).max(MIN_CAP_BYTES).min(max_total_bytes);
        Self {
            mode,
            max_bytes_per_terminal,
            max_total_bytes,
            memory_total_bytes,
            parked_max_total_bytes: parked_trim::DEFAULT_PARKED_MAX_TOTAL_BYTES,
            min_free_disk_bytes: parked_trim::DEFAULT_MIN_FREE_DISK_BYTES,
        }
    }

    /// The policy from the environment override, else the settings owner.
    pub(crate) fn current(mux: &Arc<Mux>) -> Self {
        let env_mode = std::env::var(PERSISTENCE_MODE_ENV).ok();
        let (mode, per_terminal, total, memory, parked) = mux.with_settings(|state| {
            let value = |key: &str| {
                state.get(&cmux_config::Target::Key(key.to_string())).row.and_then(|row| row.value)
            };
            (
                value(PERSISTENCE_MODE_SETTING).and_then(|value| value.as_str().map(str::to_owned)),
                value(PERSISTENCE_MAX_PER_TERMINAL_SETTING).as_ref().and_then(byte_count),
                value(PERSISTENCE_MAX_TOTAL_SETTING).as_ref().and_then(byte_count),
                value(memory_budget::MEMORY_TOTAL_SETTING).as_ref().and_then(byte_count),
                (
                    value(parked_trim::PARKED_MAX_TOTAL_SETTING).as_ref().and_then(byte_count),
                    value(parked_trim::MIN_FREE_DISK_SETTING).as_ref().and_then(byte_count),
                ),
            )
        });
        let mut policy =
            Self::resolve(env_mode.as_deref().or(mode.as_deref()), per_terminal, total);
        let env_memory = std::env::var(memory_budget::MEMORY_TOTAL_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok());
        if let Some(memory) = env_memory.or(memory) {
            policy.memory_total_bytes = memory;
        }
        if let Some(bytes) = parked.0 {
            policy.parked_max_total_bytes = bytes;
        }
        if let Some(bytes) = parked.1 {
            policy.min_free_disk_bytes = bytes;
        }
        policy
    }
}

/// A byte count setting: the schema stores a number, possibly fractional.
fn byte_count(value: &serde_json::Value) -> Option<u64> {
    value.as_u64().or_else(|| {
        let value = value.as_f64()?;
        // Truncation is the intent: the setting is a whole number of bytes.
        #[allow(
            clippy::cast_possible_truncation,
            clippy::cast_sign_loss,
            reason = "a finite non-negative f64 floors to a whole byte count; `as` saturates"
        )]
        (value.is_finite() && value >= 0.0).then(|| value.floor() as u64)
    })
}

=======
    /// The largest uncompressed replay one snapshot may hold.
    pub(crate) max_bytes_per_terminal: u64,
    /// Snapshot bytes across terminals.
    pub(crate) max_total_bytes: u64,
}

impl PersistencePolicy {
    /// The policy of a mode value; an absent or unknown value is `snapshot`.
    pub(crate) fn resolve(mode: Option<&str>) -> Self {
        match mode.and_then(PersistenceMode::parse).unwrap_or(PersistenceMode::Snapshot) {
            PersistenceMode::Memory => Self {
                mode: PersistenceMode::Memory,
                max_bytes_per_terminal: 0,
                max_total_bytes: 0,
            },
            PersistenceMode::Snapshot => Self {
                mode: PersistenceMode::Snapshot,
                max_bytes_per_terminal: snapshot::MAX_SNAPSHOT_REPLAY_BYTES as u64,
                max_total_bytes: SNAPSHOT_DEFAULT_MAX_TOTAL_BYTES,
            },
        }
    }
}

>>>>>>> theirs
/// One terminal's place in its output stream and its in-memory tail.
struct LogState {
    generation: Arc<str>,
    /// Stream offset of `tail[0]`.
    tail_start: u64,
    tail: VecDeque<u8>,
    /// Output arrived since the snapshot writer last looked.
    dirty: bool,
<<<<<<< ours
    /// Content digest of the last snapshot written (or found unchanged).
    snapshot_digest: Option<u64>,
    /// When the last snapshot was written (full mode spaces them out).
    snapshot_at: Option<Instant>,
    /// Content digest at the last stored segment frame.
    segment_digest: Option<u64>,
    last_output: Instant,
    /// Full mode: bytes not yet in a segment file, from `pending_start`.
    pending: Vec<u8>,
    pending_start: u64,
    /// The terminal's primary-screen resident bytes at its last
    /// measurement, as counted in [`OutputStore::resident_total`].
    resident: u64,
    /// History rows at the last measurement of `resident`; `None` before the
    /// first one.
    measured_rows: Option<u64>,
    /// History rows grew past the re-measure step since the last
    /// measurement: the writer measures this terminal on its next wake.
    measure_due: bool,
    /// The log left the store (`OutputStore::forget`): no measurement may
    /// add to the total for it any more.
    forgotten: bool,
    /// The stored snapshot's stream offset, generation and size (written
    /// by this daemon; `None` before its first one).
    snapshot_end: Option<u64>,
    snapshot_generation: Option<Arc<str>>,
    snapshot_size: Option<(u16, u16)>,
    /// Snapshot mode: the stream offset after the last byte in the tail file
    /// (the snapshot's offset when the tail is empty).
    tail_end: Option<u64>,
    /// Snapshot mode: raw bytes in the tail file.
    tail_bytes: u64,
    /// Snapshot mode: content digest at the last stored byte.
    tail_digest: Option<u64>,
    /// Snapshot mode: the tail file was written since its last sync.
    tail_unsynced: bool,
    /// The next pass writes a snapshot whether or not the content changed
    /// (a gap in the tail, cleared history, a mode change).
    force_snapshot: bool,
    /// Snapshot mode: a flood outran the tail ([`TAIL_FLOOD_MAX_BYTES`] of it
    /// inside one compaction spacing). Its bytes are neither written to the
    /// tail nor kept in memory: the snapshot, at most once per
    /// [`TAIL_COMPACT_SPACING`], covers them. Cleared by the snapshot that
    /// ends where the stream ends.
    flooded: bool,
    /// A snapshot or tail write failed and was reported; cleared by the next
    /// success (one report per failing stretch, not one per pass).
    store_error: bool,
    /// Snapshot mode, while writes fail: no snapshot is tried before this
    /// time, and the delay doubles per failure up to [`STORE_RETRY_MAX`]
    /// (a full disk must not cost a whole replay per terminal every pass).
    retry_at: Option<Instant>,
    retry_delay: Duration,
    /// Snapshot mode: counts the stream gaps (`OutputStore::stream_gap`). A
    /// snapshot whose capture saw an older count does not hold the screen
    /// after the gap, so it does not clear the request for one.
    gaps: u64,
    /// A discontinuity requires a recovery cursor; numeric offsets alone
    /// cannot describe output written while no daemon tap existed.
    gap_pending: bool,
    recovery_epoch: Arc<str>,
    recovery_cut: Arc<Mutex<Option<Arc<RecoveryCut>>>>,
    /// Snapshot mode: the size the last capture saw and since when; a
    /// resized terminal is snapshotted once its size has held for
    /// [`RESIZE_SETTLE`] (a divider drag does not write a snapshot per pass).
    size_seen: Option<((u16, u16), Instant)>,
}

impl LogState {
    /// A log of `generation` whose stream continues at offset `start`.
    fn new(generation: Arc<str>, start: u64) -> Self {
        Self {
            generation,
            tail_start: start,
            tail: VecDeque::new(),
            dirty: false,
            snapshot_digest: None,
            snapshot_at: None,
            segment_digest: None,
            last_output: Instant::now(),
            pending: Vec::new(),
            pending_start: start,
            resident: 0,
            measured_rows: None,
            measure_due: false,
            forgotten: false,
            snapshot_end: None,
            snapshot_generation: None,
            snapshot_size: None,
            tail_end: None,
            tail_bytes: 0,
            tail_digest: None,
            tail_unsynced: false,
            force_snapshot: false,
            flooded: false,
            store_error: false,
            retry_at: None,
            retry_delay: Duration::ZERO,
            gaps: 0,
            gap_pending: false,
            recovery_epoch: Arc::from(crate::workspace_registry::new_uuid_v4()),
            recovery_cut: Arc::new(Mutex::new(None)),
            size_seen: None,
        }
    }

    /// Snapshot mode: the unwritten bytes cannot continue the tail (a gap, a
    /// failed write, a flood past the cap, a resize, an unknown privacy).
    /// They are dropped: the next snapshot is taken from the live terminal
    /// and covers their effect on the screen and its recent history, so
    /// nothing waits in memory for it.
    fn fall_back_to_snapshot(&mut self) {
        self.pending = Vec::new();
        self.pending_start = self.next_offset();
        self.tail_end = None;
        self.tail_digest = None;
        self.force_snapshot = true;
    }

    /// Snapshot mode: when the next pass must try the snapshot this log still
    /// needs (a drop asked for it, a new generation, a resize, a tail past
    /// its cap), at the earliest time one may be written: after a write
    /// backoff, after the size has settled and after the compaction spacing,
    /// never sooner than the flush interval. `None` when it needs none.
    fn snapshot_retry_in(&self) -> Option<Duration> {
        let new_generation = self.snapshot_generation.as_deref() != Some(&*self.generation);
        let resized = !new_generation
            && self.size_seen.is_some_and(|(size, _)| self.snapshot_size != Some(size));
        if !(self.force_snapshot || new_generation || resized) {
            // A tail past its cap that waits out the compaction spacing (or a
            // flood the snapshot covers): the pass after it compacts, whether
            // or not the terminal prints.
            return (self.tail_bytes >= TAIL_MAX_BYTES || self.flooded).then(|| {
                TAIL_FLUSH_INTERVAL
                    .max(self.retry_wait().unwrap_or_default())
                    .max(self.compaction_wait())
            });
        }
        let settle = self
            .size_seen
            .filter(|_| resized)
            .map_or(Duration::ZERO, |(_, since)| RESIZE_SETTLE.saturating_sub(since.elapsed()));
        Some(TAIL_FLUSH_INTERVAL.max(self.retry_wait().unwrap_or_default()).max(settle))
    }

    /// A flood in snapshot mode: drop the unwritten bytes (the snapshot, once
    /// its spacing has passed, covers them) and stop keeping new ones.
    fn start_flood_hold(&mut self) {
        self.flooded = true;
        self.pending = Vec::new();
        self.pending_start = self.next_offset();
        self.tail_end = None;
        self.tail_digest = None;
    }

    /// The time left before a tail-cap compaction may be written.
    fn compaction_wait(&self) -> Duration {
        self.snapshot_at
            .map_or(Duration::ZERO, |at| TAIL_COMPACT_SPACING.saturating_sub(at.elapsed()))
    }

    /// Record the size a capture saw; whether it has held for
    /// [`RESIZE_SETTLE`].
    fn note_size(&mut self, size: (u16, u16)) -> bool {
        match self.size_seen {
            Some((seen, since)) if seen == size => since.elapsed() >= RESIZE_SETTLE,
            _ => {
                self.size_seen = Some((size, Instant::now()));
                false
            }
        }
    }

    /// A snapshot or tail write failed: the next snapshot waits out the
    /// backoff. Returns the wait.
    fn store_failed(&mut self) -> Duration {
        self.retry_delay = (self.retry_delay * 2).clamp(STORE_RETRY_MIN, STORE_RETRY_MAX);
        self.retry_at = Some(Instant::now() + self.retry_delay);
        self.retry_delay
    }

    /// A write went through: the disk takes writes again.
    fn store_succeeded(&mut self) {
        self.store_error = false;
        self.retry_at = None;
        self.retry_delay = Duration::ZERO;
    }

    /// The time left before a snapshot may be tried again, if any.
    fn retry_wait(&self) -> Option<Duration> {
        self.retry_at
            .and_then(|at| at.checked_duration_since(Instant::now()))
            .filter(|left| !left.is_zero())
    }

    /// Drop the oldest unwritten bytes past `max`. The stored stream then has
    /// a gap: in snapshot mode the tail no longer continues and the next
    /// snapshot starts it again (full mode's segment reads report the gap).
    fn cap_pending(&mut self, max: usize) {
        if self.pending.len() <= max {
            return;
        }
        // Down to 3/4 of the cap: a flood does not move the whole buffer on
        // every pass.
        let excess = self.pending.len() - max / 4 * 3;
        self.pending.drain(..excess);
        self.pending_start += excess as u64;
        self.tail_end = None;
        self.force_snapshot = true;
    }

    fn next_offset(&self) -> u64 {
        self.tail_start + self.tail.len() as u64
    }

    /// The first byte not yet in a segment file (full mode), else the end.
    fn unflushed_start(&self) -> u64 {
        if self.pending.is_empty() { self.next_offset() } else { self.pending_start }
    }

    /// Extend a window read from the segment files with the bytes memory
    /// holds right after it, within `budget`. Nothing changes when memory
    /// does not reach back to the window's end.
    fn continue_window(&self, window: &mut OutputWindow, budget: usize) {
        let room = budget.saturating_sub(window.bytes.len());
        if room == 0 {
            return;
        }
        let rest = self.memory_window(window.next_offset, room);
        if rest.start_offset != window.next_offset || rest.bytes.is_empty() {
            return;
        }
        window.bytes.extend_from_slice(&rest.bytes);
        window.next_offset = rest.next_offset;
        window.truncated = rest.truncated;
    }

    /// Kept bytes at or after `after`, at most `budget`, from memory.
    fn memory_window(&self, after: u64, budget: usize) -> OutputWindow {
        let end = self.next_offset();
        // Unflushed bytes (full mode) can reach further back than the tail;
        // they always end at the stream end.
        let from_pending = !self.pending.is_empty()
            && self.pending_start < self.tail_start
            && self.pending_start + self.pending.len() as u64 == end;
        let source_start = if from_pending { self.pending_start } else { self.tail_start };
        let start = after.clamp(source_start, end);
        let skip = usize::try_from(start - source_start).unwrap_or(usize::MAX);
        let available = usize::try_from(end - start).unwrap_or(usize::MAX);
        let take = available.min(budget);
        let bytes = if from_pending {
            self.pending.get(skip..skip.saturating_add(take)).unwrap_or_default().to_vec()
        } else {
            self.tail.iter().skip(skip).take(take).copied().collect()
        };
        OutputWindow {
            start_offset: start,
            next_offset: start + take as u64,
            bytes,
            truncated: take < available,
        }
    }
}

/// A terminal reader's weak handle on its output log
/// ([`OutputStore::append_cached`]).
#[derive(Default)]
pub(crate) struct OutputLogCache(Mutex<std::sync::Weak<TerminalLog>>);

=======
    /// Content digest of the last snapshot written.
    snapshot_digest: Option<u64>,
    /// Stream end the last snapshot written recorded.
    snapshot_end: Option<u64>,
    /// Moves when the person clears the history: a screen captured before
    /// the clear is not written after it.
    clear_epoch: u64,
    /// Snapshot retries since the last write or output.
    retries: u8,
}

impl LogState {
    fn next_offset(&self) -> u64 {
        self.tail_start + self.tail.len() as u64
    }
}

>>>>>>> theirs
/// One terminal's output log.
pub(crate) struct TerminalLog {
    terminal_id: TerminalPublicId,
    state: Mutex<LogState>,
<<<<<<< ours
}

/// A terminal's history size, read in O(1) under its parser lock: the
/// growth signal of the scrollback budget (`memory_budget.rs`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct HistoryRows {
    /// Rows in the primary screen's scrollback.
    pub(crate) rows: u64,
    /// Rows on the screen (the smallest re-measure step).
    pub(crate) screen_rows: u64,
}

impl HistoryRows {
    /// Re-measure after history moves by 1/16 of what it held at the last
    /// measurement, at least one screen: a terminal's resident bytes are
    /// then known to within about 1/16 (Ghostty allocates history in whole
    /// pages, so a page walk per screen of rows would be wasted work), and
    /// a terminal growing from empty to its limit is measured O(log) times.
    const STEP_DIVISOR: u64 = 16;

    /// `None` on the alternate screen: its rows are not the primary
    /// screen's history the budget measures (and a full-screen program does
    /// not grow history), so it never asks for a measurement.
    pub(crate) fn of(terminal: &ghostty_vt::Terminal) -> Option<Self> {
        (terminal.active_screen() != ghostty_vt::Screen::Alternate).then(|| Self {
            rows: u64::try_from(terminal.scrollback_rows()).unwrap_or(u64::MAX),
            screen_rows: u64::from(terminal.rows()),
        })
    }

    fn moved_past_step(self, measured: Option<u64>) -> bool {
        let Some(measured) = measured else { return true };
        let step = (measured / Self::STEP_DIVISOR).max(self.screen_rows).max(1);
        self.rows.abs_diff(measured) >= step
=======
    /// Held while this terminal's snapshot file is written, and by a history
    /// clear: the clear waits for this terminal's write only.
    write: Mutex<()>,
}

impl TerminalLog {
    fn state(&self) -> MutexGuard<'_, LogState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn write_lock(&self) -> MutexGuard<'_, ()> {
        self.write.lock().unwrap_or_else(PoisonError::into_inner)
>>>>>>> theirs
    }
}

/// A window of retained output after a cursor.
#[derive(Debug)]
pub(crate) struct OutputWindow {
    pub(crate) start_offset: u64,
    pub(crate) next_offset: u64,
    pub(crate) bytes: Vec<u8>,
    /// Bytes after `next_offset` exist (the byte budget cut the window).
    pub(crate) truncated: bool,
}

/// The store. One per Mux.
pub(crate) struct OutputStore {
    /// `None` for an in-memory session (no registry directory).
    directory: Option<PathBuf>,
<<<<<<< ours
    logs: Mutex<HashMap<TerminalPublicId, Arc<TerminalLog>>>,
    writer: writer::Writer,
    full: segments::Segments,
    /// Snapshot mode: output after the snapshot goes to its tail file.
    tail: std::sync::atomic::AtomicBool,
    /// The last memory budget pass of a write pass (they run at most once per
    /// snapshot interval, not on every tail flush).
    last_enforce: Mutex<Option<Instant>>,
    snapshot_interval: Duration,
    /// The policy the writer read last (the quit pass has no settings owner
    /// handle).
    policy: Mutex<Option<PersistencePolicy>>,
    recovery_bytes: Arc<std::sync::atomic::AtomicU64>,
=======
    policy: PersistencePolicy,
    logs: Mutex<HashMap<TerminalPublicId, Arc<TerminalLog>>>,
    /// Logs of terminals that left this daemon, newest last (at most
    /// [`RETIRED_TAILS`]); reads only.
    retired: Mutex<VecDeque<Arc<TerminalLog>>>,
    writer: snapshot::Writer,
    snapshot_interval: Duration,
>>>>>>> theirs
    /// Held by each write pass: the writer thread, a checkpoint and the quit
    /// pass never write the same file at once.
    pass: Mutex<()>,
    /// A terminal runtime left: the next pass removes files of terminals
    /// that are no longer in the session.
<<<<<<< ours
    prune_pending: std::sync::atomic::AtomicBool,
    memory_budget: memory_budget::MemoryBudget,
    /// Scrollback RAM of every terminal at its last measurement (the sum of
    /// the logs' `resident`, changed only under each log's lock). Growth
    /// keeps it current (`append` marks a measurement due when a terminal's
    /// history grew), so the budget pass starts when the growth crosses the
    /// budget, not on the writer's snapshot timer (P-AUSTIN B8).
    resident_total: std::sync::atomic::AtomicU64,
    /// Above this total the next output asks the writer for a budget pass:
    /// the budget, or where the last pass had to leave the total when every
    /// terminal was at its floor (a pass would free nothing more). Set by
    /// each pass; `u64::MAX` until the writer runs.
    resident_trigger: std::sync::atomic::AtomicU64,
    /// Stream ends the snapshots recorded, by terminal: (generation, end).
    resume: Mutex<HashMap<TerminalPublicId, (String, u64)>>,
    /// Stored segment stream ends, by terminal and generation key (full
    /// mode; read once at start).
    segment_resume: Mutex<HashMap<(TerminalPublicId, String), u64>>,
    /// Terminals of incognito (ephemeral) workspaces: memory only in every
    /// mode, whatever `terminal.persistence.mode` says (design/spaces.md
    /// "Incognito": nothing kept). Kept here because the workspace's flag
    /// row goes when it closes, before its terminals' exits are recorded.
    private: Mutex<HashSet<TerminalPublicId>>,
    /// Terminals known to be normal (not incognito), so the write pass does
    /// not ask the registry again. A terminal never moves between an
    /// incognito and a normal workspace.
    public: Mutex<HashSet<TerminalPublicId>>,
    /// Snapshot mode: when the tail files written since their last sync
    /// are synced (`snapshot.rs` `sync_due_tails`); `None`: none was.
    tail_sync_due: Mutex<Option<Instant>>,
    /// Tail file fsyncs since this store was made (`snapshot.rs`).
    tail_syncs: std::sync::atomic::AtomicU64,
    /// A test's clock for [`Self::now`]; `None`: the real one.
    #[cfg(test)]
    test_clock: Mutex<Option<Instant>>,
}

impl OutputStore {
    pub(crate) fn new(registry_directory: Option<&Path>) -> Self {
=======
    prune_pending: AtomicBool,
    /// Stream ends the snapshots recorded, by terminal: (generation, end).
    resume: Mutex<HashMap<TerminalPublicId, (String, u64)>>,
}

impl OutputStore {
    /// A store for the registry in `registry_directory` (`None`: an in-memory
    /// session, which keeps output in memory only), with the mode from
    /// `CMUX_TUI_TERMINAL_PERSISTENCE`.
    pub(crate) fn new(registry_directory: Option<&Path>) -> Self {
        Self::with_policy(
            registry_directory,
            PersistencePolicy::resolve(std::env::var(PERSISTENCE_MODE_ENV).ok().as_deref()),
        )
    }

    pub(crate) fn with_policy(
        registry_directory: Option<&Path>,
        policy: PersistencePolicy,
    ) -> Self {
>>>>>>> theirs
        let snapshot_interval = std::env::var(SNAPSHOT_INTERVAL_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .map_or(SNAPSHOT_INTERVAL, Duration::from_millis);
        Self {
            directory: registry_directory.map(|directory| directory.join(STORE_DIRECTORY)),
<<<<<<< ours
            logs: Mutex::new(HashMap::new()),
            writer: writer::Writer::default(),
            full: segments::Segments::default(),
            tail: std::sync::atomic::AtomicBool::new(false),
            last_enforce: Mutex::new(None),
            snapshot_interval,
            policy: Mutex::new(None),
            recovery_bytes: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            pass: Mutex::new(()),
            prune_pending: std::sync::atomic::AtomicBool::new(false),
            memory_budget: memory_budget::MemoryBudget::default(),
            resident_total: std::sync::atomic::AtomicU64::new(0),
            resident_trigger: std::sync::atomic::AtomicU64::new(u64::MAX),
            resume: Mutex::new(HashMap::new()),
            segment_resume: Mutex::new(HashMap::new()),
            private: Mutex::new(HashSet::new()),
            public: Mutex::new(HashSet::new()),
            tail_sync_due: Mutex::new(None),
            tail_syncs: std::sync::atomic::AtomicU64::new(0),
            #[cfg(test)]
            test_clock: Mutex::new(None),
=======
            policy,
            logs: Mutex::new(HashMap::new()),
            retired: Mutex::new(VecDeque::new()),
            writer: snapshot::Writer::default(),
            snapshot_interval,
            pass: Mutex::new(()),
            prune_pending: AtomicBool::new(false),
            resume: Mutex::new(HashMap::new()),
>>>>>>> theirs
        }
    }

    pub(crate) fn directory(&self) -> Option<&Path> {
        self.directory.as_deref()
    }

<<<<<<< ours
=======
    /// Apply the mode, then start the background writer. Runs before any
    /// terminal is adopted: memory mode removes what an earlier mode left
    /// and starts no thread; snapshot mode drops the files of terminals no
    /// longer in the session, and each terminal's stream continues at the
    /// offset its snapshot recorded.
    pub(crate) fn start(&self, mux: &Arc<Mux>) -> anyhow::Result<()> {
        let Some(directory) = self.directory.as_deref() else { return Ok(()) };
        if let Ok(value) = std::env::var(PERSISTENCE_MODE_ENV)
            && PersistenceMode::parse(&value).is_none()
        {
            eprintln!(
                "cmux-tui: {PERSISTENCE_MODE_ENV}={value} is not memory or snapshot; using snapshot"
            );
        }
        eprintln!(
            "cmux-tui: terminal output store: mode {}, at most {} bytes per terminal, {} in total",
            self.policy.mode.as_str(),
            self.policy.max_bytes_per_terminal,
            self.policy.max_total_bytes
        );
        {
            let _pass = self.lock_pass();
            snapshot::prune(mux, self);
        }
        if self.memory_only() {
            return Ok(());
        }
        // A terminal without a snapshot continues the stream an older
        // daemon journaled (`terminal.output` records), so cursors from
        // before the upgrade stay meaningful.
        let mut resume = mux.legacy_terminal_stream_ends();
        resume.extend(snapshot::stream_ends(directory));
        if let Ok(live) = mux.live_terminal_public_ids() {
            resume.retain(|terminal_id, _| live.contains(terminal_id));
        }
        *self.resume.lock().unwrap_or_else(PoisonError::into_inner) = resume;
        self.writer.start(Arc::downgrade(mux))
    }

>>>>>>> theirs
    fn log(&self, terminal_id: &TerminalPublicId, generation: &Arc<str>) -> Arc<TerminalLog> {
        let mut logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(log) = logs.get(terminal_id) {
            return log.clone();
        }
<<<<<<< ours
        // A terminal this daemon re-adopted continues its stream where the
        // last snapshot or stored segment frame left it (a client's cursor
        // stays meaningful, and no stored offset is used twice). Segments
        // flush more often than snapshots, and a snapshot can be gone (the
        // total cap) while its segments stay. Both were read at start: no
        // IO here.
        let snapshot_end = self
=======
        {
            let mut retired = self.retired.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(index) = retired.iter().position(|log| log.terminal_id == *terminal_id) {
                // Output of the departed incarnation that its reader handed
                // over before it stopped joins the departed tail (bounded);
                // it does not make the terminal live again.
                if retired[index].state().generation == *generation {
                    return retired[index].clone();
                }
                // A new incarnation (a respawn) is live: its stream starts
                // at offset 0 (see `append`). A pass that ran while the log
                // was departed left its flag set; cleared, the next append
                // asks for a pass again.
                if let Some(log) = retired.remove(index) {
                    log.state().dirty = false;
                    logs.insert(terminal_id.clone(), log.clone());
                    return log;
                }
            }
        }
        // A terminal this daemon re-adopted continues its stream where the
        // last snapshot left it (a client's cursor stays meaningful).
        let start = self
>>>>>>> theirs
            .resume
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_id)
            .filter(|(resumed, _)| resumed.as_str() == generation.as_ref())
<<<<<<< ours
            .map(|(_, end)| end);
        let segment_end = {
            let mut ends = self.segment_resume.lock().unwrap_or_else(PoisonError::into_inner);
            segments::keys_of(generation)
                .into_iter()
                .filter_map(|key| ends.remove(&(terminal_id.clone(), key)))
                .max()
        };
        let start = snapshot_end.into_iter().chain(segment_end).max().unwrap_or(0);
        let log = Arc::new(TerminalLog {
            terminal_id: terminal_id.clone(),
            state: Mutex::new(LogState::new(generation.clone(), start)),
=======
            .map_or(0, |(_, end)| end);
        let log = Arc::new(TerminalLog {
            terminal_id: terminal_id.clone(),
            state: Mutex::new(LogState {
                generation: generation.clone(),
                tail_start: start,
                tail: VecDeque::new(),
                dirty: false,
                snapshot_digest: None,
                snapshot_end: None,
                clear_epoch: 0,
                retries: 0,
            }),
            write: Mutex::new(()),
>>>>>>> theirs
        });
        logs.insert(terminal_id.clone(), log.clone());
        log
    }

    /// Record output the terminal's parser accepted. Memory only: no disk
<<<<<<< ours
    /// IO and no syscall on this path (resume offsets were read at start).
    /// `history` is the terminal's history size after the parser took
    /// `bytes` (O(1) reads under the parser lock; `None` when the caller has
    /// no terminal). When the history grew by a step since the terminal's
    /// last measurement, the writer is asked to measure it
    /// (`memory_budget.rs`); this path never walks its pages.
    #[cfg(test)]
=======
    /// IO and no syscall on this path.
>>>>>>> theirs
    pub(crate) fn append(
        &self,
        terminal_id: &TerminalPublicId,
        generation: &Arc<str>,
        bytes: &[u8],
<<<<<<< ours
        history: Option<HistoryRows>,
    ) {
        if bytes.is_empty() {
            return;
        }
        let log = self.log(terminal_id, generation);
        let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        self.append_locked(state, generation, bytes, history);
    }

    /// [`OutputStore::append`] for a terminal's output reader, through the
    /// handle `cache` keeps on its log: the per-chunk path takes no lock the
    /// readers of all terminals share. The handle is weak, and a log the
    /// store forgot is looked up again, so the cache never keeps a log alive
    /// or writes into one the store dropped.
    pub(crate) fn append_cached(
        &self,
        cache: &OutputLogCache,
        terminal_id: &TerminalPublicId,
        generation: &Arc<str>,
        bytes: &[u8],
        history: Option<HistoryRows>,
=======
>>>>>>> theirs
    ) {
        if bytes.is_empty() {
            return;
        }
<<<<<<< ours
        let mut cached = cache.0.lock().unwrap_or_else(PoisonError::into_inner);
        let live = cached.upgrade().filter(|log| log.terminal_id == *terminal_id);
        if let Some(log) = live {
            let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if !state.forgotten {
                drop(cached);
                self.append_locked(state, generation, bytes, history);
                return;
            }
        }
        let log = self.log(terminal_id, generation);
        *cached = Arc::downgrade(&log);
        drop(cached);
        let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        self.append_locked(state, generation, bytes, history);
    }

    /// The body of [`OutputStore::append`] with the log's state locked.
    fn append_locked(
        &self,
        mut state: std::sync::MutexGuard<'_, LogState>,
        generation: &Arc<str>,
        bytes: &[u8],
        history: Option<HistoryRows>,
    ) {
        if let Some(history) = history
            && !state.measure_due
            && history.moved_past_step(state.measured_rows)
        {
            state.measure_due = true;
            self.writer.request_memory_pass();
        }
=======
        let log = self.log(terminal_id, generation);
        let mut state = log.state();
>>>>>>> theirs
        if state.generation != *generation {
            // A new incarnation starts a new stream at offset 0.
            state.generation = generation.clone();
            state.tail_start = 0;
            state.tail.clear();
<<<<<<< ours
            state.pending.clear();
            state.pending_start = 0;
            state.invalidate_recovery();
=======
            state.snapshot_digest = None;
            state.snapshot_end = None;
>>>>>>> theirs
        }
        let keep = bytes.len().min(OUTPUT_TAIL_BYTES);
        let skipped = (bytes.len() - keep) as u64;
        let overflow = (state.tail.len() + keep).saturating_sub(OUTPUT_TAIL_BYTES);
        let drained = overflow.min(state.tail.len());
        state.tail.drain(..drained);
        state.tail_start += overflow as u64 + skipped;
<<<<<<< ours
        state.tail.extend(bytes.get(bytes.len().saturating_sub(keep)..).unwrap_or_default());
        state.last_output = Instant::now();
        if self.tail_enabled() && !self.full.enabled() && state.flooded {
            // A flood the next snapshot covers: no copy into `pending`.
            state.pending_start = state.next_offset();
        } else if self.full.enabled() || self.tail_enabled() {
            if state.pending.is_empty() {
                state.pending_start = state.next_offset() - bytes.len() as u64;
            }
            let before = state.pending.len();
            state.pending.extend_from_slice(bytes);
            // Snapshot mode: past the cap the bytes fall back to the snapshot
            // here, not at the next pass (which a write backoff or a slow
            // write can hold off): memory stays bounded between passes.
            if self.tail_enabled() && state.pending.len() > TAIL_MAX_UNWRITTEN_BYTES {
                state.fall_back_to_snapshot();
            }
            // A flood wakes the writer once, when its unwritten bytes cross
            // the threshold, not on every chunk after it; never while a
            // snapshot-mode write backoff holds them (the writer's own
            // retry time wakes it).
            // Snapshot mode wakes at half its cap, so a flood a healthy disk
            // can take is written before `append` would drop it.
            let wake = if self.full.enabled() {
                FULL_PENDING_WAKE_BYTES
            } else {
                TAIL_MAX_UNWRITTEN_BYTES / 2
            };
            if before < wake
                && state.pending.len() >= wake
                && (self.full.enabled() || state.retry_wait().is_none())
            {
                state.dirty = true;
                drop(state);
                self.writer.mark_dirty(Duration::ZERO);
                return;
            }
        }
        if !state.dirty {
            state.dirty = true;
            drop(state);
            self.mark_dirty();
        }
    }

    /// Ask the writer for a pass after the mode's interval.
    fn mark_dirty(&self) {
        let interval = if self.full.enabled() {
            FULL_FLUSH_INTERVAL.min(self.snapshot_interval)
        } else if self.tail_enabled() {
            TAIL_FLUSH_INTERVAL.min(self.snapshot_interval)
        } else {
            self.snapshot_interval
        };
        self.writer.mark_dirty(interval);
    }

    /// Put a log back for a pass `delay` from now (a write backoff).
    fn mark_log_dirty_after(&self, log: &TerminalLog, delay: Duration) {
        log.state.lock().unwrap_or_else(PoisonError::into_inner).dirty = true;
        self.writer.mark_dirty(delay);
    }

    /// Put a log back for the next pass (full mode spaces snapshots out).
    fn mark_log_dirty(&self, log: &TerminalLog) {
        log.state.lock().unwrap_or_else(PoisonError::into_inner).dirty = true;
        self.mark_dirty();
    }

    /// The terminal's current generation and the offset after its last byte.
    pub(crate) fn stream_end(&self, terminal_id: &TerminalPublicId) -> Option<(Arc<str>, u64)> {
        let log =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id)?.clone();
        let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        Some((state.generation.clone(), state.next_offset()))
    }

    /// The current stream cursor, including a persisted snapshot/tail that has
    /// not created an in-memory log yet (the first read after host adoption).
    pub(crate) fn stream_cursor(&self, terminal_id: &TerminalPublicId) -> Option<(Arc<str>, u64)> {
        if let Some(log) =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id).cloned()
        {
            let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            return Some((state.generation.clone(), state.next_offset()));
        }
        self.resume
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(terminal_id)
            .map(|(generation, end)| (Arc::from(generation.as_str()), *end))
=======
        state.tail.extend(&bytes[bytes.len() - keep..]);
        state.retries = 0;
        if !state.dirty && !self.memory_only() {
            state.dirty = true;
            drop(state);
            self.writer.mark_dirty(self.snapshot_interval);
        }
    }

    /// The terminal's current generation and the offset after its last byte.
    pub(crate) fn stream_end(&self, terminal_id: &TerminalPublicId) -> Option<(Arc<str>, u64)> {
        let log = self.readable_log(terminal_id)?;
        let state = log.state();
        Some((state.generation.clone(), state.next_offset()))
    }

    /// The log of a terminal in this daemon, or of one that left it
    /// recently (its tail stays readable after its exit).
    fn readable_log(&self, terminal_id: &TerminalPublicId) -> Option<Arc<TerminalLog>> {
        if let Some(log) = self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id)
        {
            return Some(log.clone());
        }
        self.retired
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .iter()
            .rev()
            .find(|log| log.terminal_id == *terminal_id)
            .cloned()
>>>>>>> theirs
    }

    /// Retained output at or after `after`, at most `max_bytes` (never less
    /// than one byte when any exists). A cursor older than what is kept
<<<<<<< ours
    /// starts at the oldest kept byte. Full mode: bytes before the unflushed
    /// ones come from the segment files, read without the terminal's lock.
=======
    /// starts at the oldest kept byte. A cursor past the end can only come
    /// from an earlier daemon whose stream end was not recorded (it stopped
    /// without its quit pass): the window starts at the oldest kept byte, so
    /// `start_offset` below the cursor tells the reader to reset.
>>>>>>> theirs
    pub(crate) fn read_after(
        &self,
        terminal_id: &TerminalPublicId,
        after: u64,
        max_bytes: u64,
    ) -> Option<OutputWindow> {
<<<<<<< ours
        let log =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id)?.clone();
        let budget = usize::try_from(max_bytes.max(1)).unwrap_or(usize::MAX);
        // A flush drops bytes from memory only after their frame is written,
        // so every byte before an observed `unflushed_start` is already in a
        // segment file. A try that finds the bytes at `after` in neither
        // place saw a flush finish meanwhile; the next try's segment read
        // then has them (a pruned or cleared file is the only other cause).
        const TRIES: usize = 3;
        for attempt in 1..=TRIES {
            let (generation, end, unflushed_start) = {
                let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                (state.generation.clone(), state.next_offset(), state.unflushed_start())
            };
            if self.full.enabled()
                && after < unflushed_start
                && let Some(directory) = self.directory.as_deref()
                && let Some(mut window) =
                    segments::read_after(directory, terminal_id, &generation, after, budget)
            {
                // Memory holds every byte from the first unflushed one on
                // (and the recent tail): the window goes on from there when
                // memory reaches back to the window's end.
                let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                if state.generation != generation {
                    window.truncated |= window.next_offset < end;
                    return Some(window);
                }
                state.continue_window(&mut window, budget);
                let end = state.next_offset();
                // Still short of the end with room left while a flush
                // finished meanwhile (its bytes left memory after the
                // segment read): read again, the files now hold them.
                if window.next_offset < end
                    && window.bytes.len() < budget
                    && state.unflushed_start() != unflushed_start
                    && attempt < TRIES
                {
                    continue;
                }
                window.truncated |= window.next_offset < end;
                return Some(window);
            }
            let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if self.full.enabled()
                && after < state.tail_start
                && after < state.unflushed_start()
                && state.unflushed_start() != unflushed_start
            {
                continue;
            }
            return Some(state.memory_window(after, budget));
        }
        let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        Some(state.memory_window(after, budget))
    }

    /// The daemon's terminal was replaced from its host's snapshot (a host
    /// reconnect): bytes the host wrote while the daemon had no tap never
    /// came through [`Self::append`]. The next output read projects the
    /// replaced terminal from offset zero; this applies to every persistence
    /// mode and also creates a log for a re-adopted terminal with no tail yet.
    pub(crate) fn stream_gap(&self, terminal_id: &TerminalPublicId, generation: &Arc<str>) {
        // Re-adopted terminals may not have an in-memory log yet. Creating it
        // here consumes the persisted cursor, so an idle terminal's screen is
        // still recoverable even before its first post-adoption append.
        let log = self.log(terminal_id, generation);
        let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.generation != *generation {
            state.generation = generation.clone();
            state.tail_start = 0;
            state.tail.clear();
            state.pending.clear();
            state.pending_start = 0;
        }
        if self.tail_enabled() {
            state.fall_back_to_snapshot();
        }
        state.gaps += 1;
        state.invalidate_recovery();
        let wait = state.retry_wait();
        drop(state);
        if self.tail_enabled() {
            match wait {
                Some(wait) => self.mark_log_dirty_after(&log, wait),
                None => self.mark_log_dirty(&log),
            }
        }
    }

    /// The terminal was resized: snapshot mode asks the writer for a pass,
    /// whose capture sees the new size and (once it has held for the settle
    /// time) writes the snapshot at it, or schedules the retry. Without this,
    /// a program that prints nothing after a resize left the stored screen
    /// at the old size until its next output. Memory only: no disk work here.
    pub(crate) fn resized(&self, terminal_id: &TerminalPublicId) {
        if !self.tail_enabled() {
            return;
        }
        let Some(log) =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id).cloned()
        else {
            return;
        };
        self.mark_log_dirty(&log);
    }

    /// The person cleared this terminal's history: drop the stored output
    /// (memory tail, segment files) and write the snapshot at once.
    pub(crate) fn history_cleared(&self, terminal_id: &TerminalPublicId) {
        // A pass that already read this terminal's bytes or screen finishes
        // before the clear, so it cannot write them back afterwards.
        let _pass = self.lock_pass();
        let Some(log) =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id).cloned()
        else {
            return;
        };
        {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            let end = state.next_offset();
            state.tail.clear();
            state.tail_start = end;
            state.invalidate_recovery();
            state.pending.clear();
            state.snapshot_digest = None;
            state.snapshot_at = None;
            state.segment_digest = None;
            state.tail_end = None;
            state.tail_bytes = 0;
            state.tail_digest = None;
            state.force_snapshot = true;
            state.dirty = true;
        }
        if let Some(directory) = self.directory.as_deref() {
            segments::remove(directory, terminal_id);
            self.full.forget(directory, terminal_id);
            tail::remove(directory, terminal_id);
            // The cleared lines leave the disk now, not when the next
            // snapshot is written (which a write backoff can delay).
            snapshot::remove(directory, terminal_id);
        }
        self.writer.mark_dirty(Duration::ZERO);
    }

    /// A parked terminal mirror (surface/mirror_park.rs) is rebuilt at the
    /// configured scrollback: its budget limit is measured afresh.
    pub(crate) fn forget_scrollback_budget(&self, terminal_id: &TerminalPublicId) {
        self.memory_budget.forget(terminal_id);
    }

    /// Forget a terminal runtime that left this daemon: its memory. Its
    /// files stay while the terminal is in the session (a respawn after a
    /// lost host reads them); the next write pass removes the files of
    /// terminals that left the session.
    pub(crate) fn forget(&self, terminal_id: &TerminalPublicId) {
        self.memory_budget.forget(terminal_id);
        self.public.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
        // An incognito terminal's files (none are written; this covers one
        // marked after a write) go now, not at the next pass. It stays
        // marked: its exit can be recorded after it left the session, when
        // its workspace's flag is gone too.
        if self.private.lock().unwrap_or_else(PoisonError::into_inner).contains(terminal_id) {
            self.remove_files(terminal_id);
        }
        let removed = self.logs.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
        if let Some(log) = &removed {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.forgotten = true;
            let resident = std::mem::take(&mut state.resident);
            self.account_resident(resident, 0);
        }
        if removed.is_some() && self.directory.is_some() {
            self.prune_pending.store(true, std::sync::atomic::Ordering::Release);
            self.mark_dirty();
        }
    }

    /// The screen a respawn after a lost host starts with: in full mode the
    /// terminal rebuilt from its stored bytes (the long scrollback), else its
    /// last snapshot and the tail after it. `None` in memory mode or when
    /// nothing was written. `scrollback` is the respawned terminal's
    /// scrollback limit: a rebuild keeps as much history as it will.
    /// Memory mode: the writer removes every file at start, and a respawn
    /// that runs before it finds nothing either, since memory mode never
    /// wrote one.
    pub(crate) fn previous_screen(
        &self,
        terminal_id: &TerminalPublicId,
        scrollback: usize,
    ) -> Option<crate::workspace_registry::terminal_respawn_store::TerminalReplay> {
        let directory = self.directory.as_deref()?;
        if self.memory_only() {
            return None;
        }
        let full = self.cached_policy().is_some_and(|policy| policy.mode == PersistenceMode::Full);
        let (snapshot, generation, tail) = {
            // The writer replaces a snapshot and then removes the tail it
            // covers, both under the pass lock. Both files are read under it
            // too, so a snapshot comes with its own tail: a pass between the
            // two reads paired the old snapshot with no tail. Only the reads;
            // the rebuild runs after.
            let _pass = self.lock_pass();
            let (snapshot, generation, snapshot_end) = snapshot::read(directory, terminal_id)?;
            #[cfg(test)]
            run_between_screen_reads_for_test();
            // Snapshot mode: the output after the snapshot, from its tail.
            let tail = if full {
                Vec::new()
            } else {
                snapshot_end
                    .map(|end| tail::bytes_after(directory, terminal_id, &generation, end))
                    .unwrap_or_default()
            };
            (snapshot, generation, tail)
        };
        if full
            && let Some(rebuilt) = segments::rebuild(
                directory,
                terminal_id,
                &generation,
                snapshot.cols,
                snapshot.rows,
                scrollback,
            )
        {
            return Some(rebuilt);
        }
        Some(tail::restore(snapshot, &tail, scrollback))
    }

    /// Tests: persist `terminal` the way the writer's pass does in snapshot
    /// mode, at the default policy: its snapshot (the bounded replay the
    /// pass captures) at stream offset `snapshot_end`, then `tail`, the
    /// output after it, in the tail file.
    #[cfg(test)]
    pub(crate) fn persist_for_test(
        &self,
        terminal_id: &TerminalPublicId,
        generation: &str,
        terminal: &mut ghostty_vt::Terminal,
        snapshot_end: u64,
        tail: &[u8],
    ) -> anyhow::Result<()> {
        let directory = self
            .directory
            .as_deref()
            .ok_or_else(|| anyhow::anyhow!("the store has no directory"))?;
        let policy = PersistencePolicy::resolve(None, None, None);
        let (cols, rows) = (terminal.cols(), terminal.rows());
        let budget = snapshot::replay_budget(cols, rows, policy.max_bytes_per_terminal);
        let replay = terminal.vt_replay_bounded(budget)?.into_self_contained_bytes();
        snapshot::write(directory, terminal_id, generation, snapshot_end, cols, rows, &replay)?;
        tail::append(directory, terminal_id, generation, snapshot_end, snapshot_end, tail, false)
=======
        let log = self.readable_log(terminal_id)?;
        let budget = usize::try_from(max_bytes.max(1)).unwrap_or(usize::MAX);
        let state = log.state();
        let end = state.next_offset();
        let start = if after > end { state.tail_start } else { after.max(state.tail_start) };
        let skip = usize::try_from(start - state.tail_start).unwrap_or(usize::MAX);
        let available = usize::try_from(end - start).unwrap_or(usize::MAX);
        let take = available.min(budget);
        let bytes = state.tail.range(skip..skip + take).copied().collect();
        Some(OutputWindow {
            start_offset: start,
            next_offset: start + take as u64,
            bytes,
            truncated: take < available,
        })
    }

    /// The person cleared this terminal's history: drop the stored output
    /// and write the snapshot at once.
    pub(crate) fn history_cleared(&self, terminal_id: &TerminalPublicId) {
        let live =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id).cloned();
        // A re-adopted terminal that printed nothing in this daemon has no
        // log yet, but may have an earlier daemon's snapshot: its log starts
        // at the saved end, so the cleared snapshot replaces that file and
        // the stream keeps its offset.
        let resumed = || {
            let generation = self
                .resume
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(terminal_id)?
                .0
                .clone();
            Some(self.log(terminal_id, &Arc::from(generation)))
        };
        let Some(log) = live.or_else(resumed) else { return };
        {
            // Waits only for a write of this terminal's file that is in
            // progress. A pass that captured the screen before the clear and
            // has not written it yet sees the new epoch and skips the write;
            // one that already wrote it is followed by the pass asked for
            // below, which writes the cleared screen.
            let _write = log.write_lock();
            let mut state = log.state();
            let end = state.next_offset();
            state.tail.clear();
            state.tail_start = end;
            state.snapshot_digest = None;
            state.clear_epoch += 1;
            state.dirty = !self.memory_only();
        }
        if !self.memory_only() {
            self.writer.mark_dirty(Duration::ZERO);
        }
    }

    /// Forget a terminal runtime that left this daemon (its exit under the
    /// close policy, a close). Its tail stays readable among the
    /// [`RETIRED_TAILS`] most recent ones, in memory only, so an exit
    /// receipt still answers `terminal.output_read` (as the journaled
    /// records did until retention removed them). The next write pass
    /// removes the files of terminals that left the session, including a
    /// snapshot an earlier daemon wrote for a terminal that printed nothing
    /// in this one.
    pub(crate) fn forget(&self, terminal_id: &TerminalPublicId) {
        {
            // Under the logs lock, so an append meanwhile finds the log in
            // one of the two places.
            let mut logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(log) = logs.remove(terminal_id) {
                let mut retired = self.retired.lock().unwrap_or_else(PoisonError::into_inner);
                retired.retain(|retired| retired.terminal_id != *terminal_id);
                if retired.len() == RETIRED_TAILS {
                    retired.pop_front();
                }
                retired.push_back(log);
            }
        }
        self.resume.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
        if !self.memory_only() {
            self.prune_pending.store(true, Ordering::Release);
            self.writer.mark_dirty(self.snapshot_interval);
        }
    }

    /// Drop a terminal's live and departed tail (tests: a restarted daemon).
    #[cfg(test)]
    pub(crate) fn forget_tail_for_test(&self, terminal_id: &TerminalPublicId) {
        self.logs.lock().unwrap().remove(terminal_id);
        self.retired.lock().unwrap().retain(|log| log.terminal_id != *terminal_id);
    }

    /// A capture or write of this log's snapshot did not happen: try again
    /// with a later pass rather than wait for the terminal's next output,
    /// at most [`SNAPSHOT_RETRIES`] times in a row (new output tries again).
    fn retry_later(&self, log: &TerminalLog) {
        {
            let mut state = log.state();
            if state.retries >= SNAPSHOT_RETRIES {
                return;
            }
            state.retries += 1;
            state.dirty = true;
        }
        self.writer.mark_dirty(self.snapshot_interval);
>>>>>>> theirs
    }

    /// The logs whose terminal printed since the writer last looked; their
    /// flags are cleared.
    fn take_dirty(&self) -> Vec<Arc<TerminalLog>> {
        let logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        logs.values()
<<<<<<< ours
            .filter(|log| {
                let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                std::mem::replace(&mut state.dirty, false)
            })
=======
            .filter(|log| std::mem::replace(&mut log.state().dirty, false))
>>>>>>> theirs
            .cloned()
            .collect()
    }

    /// Final write at quit, on the caller's thread: stop the writer, then
<<<<<<< ours
    /// make every terminal's unwritten bytes durable.
    pub(crate) fn shutdown(&self, mux: &Mux) {
        if self.directory.is_none() {
            return;
        }
        self.writer.stop();
        // A terminal whose bytes since its snapshot are all in a synced tail
        // is visited too: the pass reads its screen (a digest, no snapshot)
        // and writes a snapshot only where the tail cannot carry it, a
        // terminal on the alternate screen included (quit_pass_tests.rs).
        for log in self.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if state.tail_bytes > 0 {
                state.dirty = true;
            }
        }
        self.write_now(mux);
    }

    /// Store every terminal's output now (a journal checkpoint and quit):
    /// the screen a respawn after a reboot gets is the screen at this point.
    /// Only terminals with bytes not yet durable are visited (unwritten
    /// bytes, an unsynced tail, or a pass they wait for): a quit with
    /// hundreds of terminals does work for the ones that printed, not for
    /// every terminal, while no daemon answers (quit_pass_tests.rs).
    pub(crate) fn write_now(&self, mux: &Mux) {
        if self.directory.is_none() {
            return;
        }
        for log in self.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if !state.pending.is_empty() || state.tail_unsynced || state.force_snapshot {
                state.dirty = true;
            }
        }
        let policy = self.cached_policy().unwrap_or_else(|| {
            PersistencePolicy::resolve(
                std::env::var(PERSISTENCE_MODE_ENV).ok().as_deref(),
                None,
                None,
            )
        });
        snapshot::final_pass(mux, self, policy);
    }

    /// Record `log`'s measured resident bytes (`rows`: its history rows at
    /// the measurement, `None` on the alternate screen or when the terminal
    /// is gone) and move its share
    /// of [`Self::resident_total`].
    /// Nothing changes for a forgotten log: its share already left the total.
    fn set_resident(&self, log: &TerminalLog, resident: u64, rows: Option<u64>) {
        let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.forgotten {
            return;
        }
        let previous = std::mem::replace(&mut state.resident, resident);
        // `measure_due` is cleared before the measurement read (by its
        // caller), never here: an append that raced the read keeps its ask.
        // No rows (the alternate screen, or the terminal is gone): the last
        // primary measurement stays the next growth step's base.
        if rows.is_some() {
            state.measured_rows = rows;
        }
        self.account_resident(previous, resident);
    }

    /// Move one terminal's share of [`Self::resident_total`] from `previous`
    /// to `current`. Called with that terminal's log lock held, so the total
    /// stays the sum of the logs' `resident`.
    fn account_resident(&self, previous: u64, current: u64) {
        use std::sync::atomic::Ordering;
        if current >= previous {
            self.resident_total.fetch_add(current - previous, Ordering::AcqRel);
        } else {
            let shrunk = previous - current;
            let _ =
                self.resident_total.fetch_update(Ordering::AcqRel, Ordering::Acquire, |total| {
                    Some(total.saturating_sub(shrunk))
                });
        }
    }

    /// True when the measured total is over the next pass's trigger.
    fn resident_over_trigger(&self) -> bool {
        use std::sync::atomic::Ordering;
        self.resident_total.load(Ordering::Acquire) > self.resident_trigger.load(Ordering::Acquire)
    }

    fn resident_total(&self) -> u64 {
        self.resident_total.load(std::sync::atomic::Ordering::Acquire)
    }

    fn set_resident_trigger(&self, trigger: u64) {
        self.resident_trigger.store(trigger, std::sync::atomic::Ordering::Release);
    }

    fn tail_enabled(&self) -> bool {
        self.tail.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn set_tail_enabled(&self, enabled: bool) {
        self.tail.store(enabled, std::sync::atomic::Ordering::Relaxed);
    }

    /// Whether a write pass runs the memory budget now: at most once per
    /// interval of the mode (the growth trigger covers the time between,
    /// `memory_budget.rs`).
    fn enforce_due(&self, full: bool) -> bool {
        let interval = if full {
            FULL_FLUSH_INTERVAL.min(self.snapshot_interval)
        } else {
            self.snapshot_interval
        };
        let mut last = self.last_enforce.lock().unwrap_or_else(PoisonError::into_inner);
        if last.is_some_and(|at| at.elapsed() < interval) {
            return false;
        }
        *last = Some(Instant::now());
        true
    }

    /// The time the tail sync is measured against: the real clock, or the
    /// one a test stopped and moves itself (`advance_clock`), so no test
    /// sleeps.
    fn now(&self) -> Instant {
        #[cfg(test)]
        {
            let stopped = *self.test_clock.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(now) = stopped {
                return now;
            }
        }
        Instant::now()
    }

    /// Stop [`Self::now`] (at the first call) and move it ahead by `by`.
    #[cfg(test)]
    fn advance_clock(&self, by: Duration) {
        let mut clock = self.test_clock.lock().unwrap_or_else(PoisonError::into_inner);
        *clock = Some(clock.unwrap_or_else(Instant::now) + by);
    }

    /// A tail file was written without a sync: the tails' next sync is due
    /// [`TAIL_SYNC_INTERVAL`] from now, unless one is already due.
    fn tail_written(&self) {
        let mut due = self.tail_sync_due.lock().unwrap_or_else(PoisonError::into_inner);
        if due.is_none() {
            *due = Some(self.now() + TAIL_SYNC_INTERVAL);
        }
    }

    /// How long until the tails written since their last sync are synced
    /// (zero: now); `None`: no sync is due.
    fn tail_sync_wait(&self) -> Option<Duration> {
        let due = (*self.tail_sync_due.lock().unwrap_or_else(PoisonError::into_inner))?;
        Some(due.saturating_duration_since(self.now()))
    }

    /// The logs whose tail file was written since its last sync. Their flags
    /// are cleared, and no sync is due until the next tail write.
    fn take_unsynced_tails(&self) -> Vec<Arc<TerminalLog>> {
        *self.tail_sync_due.lock().unwrap_or_else(PoisonError::into_inner) = None;
        let logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        logs.values()
            .filter(|log| {
                let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                std::mem::replace(&mut state.tail_unsynced, false)
            })
            .cloned()
            .collect()
    }

    /// One tail file was fsynced.
    fn count_tail_sync(&self) {
        self.tail_syncs.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }

    #[cfg(test)]
    fn tail_syncs(&self) -> u64 {
        self.tail_syncs.load(std::sync::atomic::Ordering::Relaxed)
    }

    fn lock_pass(&self) -> std::sync::MutexGuard<'_, ()> {
        self.pass.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn cache_policy(&self, policy: PersistencePolicy) {
        *self.policy.lock().unwrap_or_else(PoisonError::into_inner) = Some(policy);
    }

    fn cached_policy(&self) -> Option<PersistencePolicy> {
        *self.policy.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Keep terminal `terminal_id` in memory only: it belongs to an incognito
    /// workspace. Its files, if any, are removed now.
    pub(crate) fn mark_private(&self, terminal_id: &TerminalPublicId) {
        self.public.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id);
        if self.private.lock().unwrap_or_else(PoisonError::into_inner).insert(terminal_id.clone()) {
            self.remove_files(terminal_id);
        }
    }

    /// Terminal `terminal_id` is known normal (spawned outside an incognito
    /// workspace), before its registry row exists. A private mark wins.
    pub(crate) fn mark_public(&self, terminal_id: &TerminalPublicId) {
        if !self.private.lock().unwrap_or_else(PoisonError::into_inner).contains(terminal_id) {
            self.public.lock().unwrap_or_else(PoisonError::into_inner).insert(terminal_id.clone());
        }
    }

    fn remove_files(&self, terminal_id: &TerminalPublicId) {
        if let Some(directory) = self.directory.as_deref() {
            let _pass = self.lock_pass();
            snapshot::remove(directory, terminal_id);
            segments::remove(directory, terminal_id);
            self.full.forget(directory, terminal_id);
            tail::remove(directory, terminal_id);
        }
    }

    /// Whether terminal `terminal_id` is kept in memory only: it was marked
    /// private, or its workspace is incognito (it is marked then). When the
    /// registry cannot tell, it is (fail closed).
    /// Takes the workspace registry lock; see [`Self::is_private_in`].
    pub(crate) fn is_private(&self, mux: &Mux, terminal_id: &TerminalPublicId) -> bool {
        self.privacy(mux, terminal_id).unwrap_or(true)
    }

    /// [`Self::is_private`] for a caller that holds the workspace registry.
    pub(crate) fn is_private_in(
        &self,
        registry: &crate::workspace_registry::WorkspaceRegistry,
        terminal_id: &TerminalPublicId,
    ) -> bool {
        self.privacy_in(registry, terminal_id).unwrap_or(true)
    }

    /// Whether terminal `terminal_id` is private; `None` when the registry
    /// could not tell. Takes the workspace registry lock unless the answer
    /// is cached.
    fn privacy(&self, mux: &Mux, terminal_id: &TerminalPublicId) -> Option<bool> {
        if let Some(known) = self.known_privacy(terminal_id) {
            return Some(known);
        }
        let registry = mux.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        self.privacy_in(&registry, terminal_id)
    }

    fn known_privacy(&self, terminal_id: &TerminalPublicId) -> Option<bool> {
        if self.private.lock().unwrap_or_else(PoisonError::into_inner).contains(terminal_id) {
            return Some(true);
        }
        self.public
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .contains(terminal_id)
            .then_some(false)
    }

    fn privacy_in(
        &self,
        registry: &crate::workspace_registry::WorkspaceRegistry,
        terminal_id: &TerminalPublicId,
    ) -> Option<bool> {
        if let Some(known) = self.known_privacy(terminal_id) {
            return Some(known);
        }
        match registry.read_state(|connection| {
            crate::state::store::public_terminal_is_ephemeral(connection, terminal_id.as_str())
        }) {
            Ok(Some(true)) => {
                self.private
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(terminal_id.clone());
                Some(true)
            }
            Ok(Some(false)) => {
                self.public
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(terminal_id.clone());
                Some(false)
            }
            // No row (yet): not known normal, so it reads as incognito and
            // its bytes wait; asked again next time.
            Ok(None) => None,
            Err(error) => {
                eprintln!(
                    "cmux-tui: could not tell whether terminal {} is incognito; keeping it in memory: {error:#}",
                    terminal_id.as_str()
                );
                None
            }
        }
    }

    /// Whether terminal `terminal_id`'s screen may reach the disk (an exit
    /// replay, a snapshot): not in memory mode and not an incognito terminal.
    pub(crate) fn keeps_screen(&self, mux: &Mux, terminal_id: &TerminalPublicId) -> bool {
        !self.memory_only() && !self.is_private(mux, terminal_id)
    }

    /// `dirty` without the logs of private terminals, whose unflushed bytes
    /// (full mode) are dropped: they never reach a file. A terminal the
    /// registry could not place waits for the next pass with its bytes kept.
    /// Called under the pass lock.
    fn without_private(&self, mux: &Mux, dirty: Vec<Arc<TerminalLog>>) -> Vec<Arc<TerminalLog>> {
        let mut unknown = false;
        let kept = dirty
            .into_iter()
            .filter(|log| match self.privacy(mux, &log.terminal_id) {
                Some(false) => true,
                Some(true) => {
                    let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                    state.pending = Vec::new();
                    state.pending_start = state.next_offset();
                    false
                }
                None => {
                    let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                    state.dirty = true;
                    // Bounded while the registry cannot place the terminal
                    // (snapshot mode: the snapshot covers the bytes).
                    if self.tail_enabled() {
                        state.fall_back_to_snapshot();
                    } else {
                        state.cap_pending(TAIL_MAX_UNWRITTEN_BYTES);
                    }
                    unknown = true;
                    false
                }
            })
            .collect();
        if unknown {
            self.mark_dirty();
        }
        kept
    }

    /// True when `terminal.persistence.mode` is `memory`: no terminal screen
    /// may reach the disk (exit replays and close archives keep no screen).
    pub(crate) fn memory_only(&self) -> bool {
        self.directory.is_none()
            || self.cached_policy().is_some_and(|policy| policy.mode == PersistenceMode::Memory)
=======
    /// write every changed terminal once more. A caller that is unwinding
    /// from a panic only stops the writer (its locks may be poisoned).
    /// A writer that did not stop in time keeps its pass (it may be stuck in
    /// file I/O), so the final write is skipped rather than wait for it.
    pub(crate) fn shutdown(&self, mux: &Mux) {
        if self.memory_only() {
            return;
        }
        if self.writer.stop() && !std::thread::panicking() {
            self.write_now(mux);
        }
    }

    /// Write every terminal's snapshot now when its content changed or its
    /// stream moved since the last write (a journal checkpoint and quit), so
    /// a re-adopted terminal continues its stream at the current end.
    pub(crate) fn write_now(&self, mux: &Mux) {
        if self.memory_only() {
            return;
        }
        for log in self.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            log.state().dirty = true;
        }
        snapshot::write_pass(mux, self, true);
    }

    fn lock_pass(&self) -> MutexGuard<'_, ()> {
        self.pass.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// True in memory mode or without a registry directory: no terminal
    /// screen may reach the disk (exit snapshots keep no screen either).
    pub(crate) fn memory_only(&self) -> bool {
        self.directory.is_none() || self.policy.mode == PersistenceMode::Memory
>>>>>>> theirs
    }
}

#[cfg(test)]
<<<<<<< ours
thread_local! {
    /// Test seam: runs once on this thread inside [`OutputStore::previous_screen`],
    /// after it read the snapshot and before it reads the tail.
    pub(crate) static BETWEEN_SCREEN_READS_FOR_TEST: std::cell::RefCell<Option<Box<dyn FnOnce()>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn run_between_screen_reads_for_test() {
    let hook = BETWEEN_SCREEN_READS_FOR_TEST.with(|slot| slot.borrow_mut().take());
    if let Some(hook) = hook {
        hook();
=======
mod tests {
    use super::*;

    fn terminal() -> TerminalPublicId {
        TerminalPublicId::parse("term_00000000000000000000000000000091").unwrap()
    }

    #[test]
    fn the_tail_keeps_the_newest_bytes_and_reads_resume_by_offset() {
        let store = OutputStore::with_policy(None, PersistencePolicy::resolve(Some("memory")));
        let generation: Arc<str> = Arc::from("generation-one");
        let terminal = terminal();
        store.append(&terminal, &generation, b"first ");
        store.append(&terminal, &generation, b"second");
        assert_eq!(store.stream_end(&terminal), Some((generation.clone(), 12)));

        let window = store.read_after(&terminal, 0, 1 << 20).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (0, 12));
        assert_eq!(window.bytes, b"first second");
        assert!(!window.truncated);
        let window = store.read_after(&terminal, 6, 3).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (6, 9));
        assert_eq!(window.bytes, b"sec");
        assert!(window.truncated);

        // More than the tail holds: the oldest bytes go, offsets keep counting.
        store.append(&terminal, &generation, &vec![b'x'; OUTPUT_TAIL_BYTES]);
        let end = 12 + OUTPUT_TAIL_BYTES as u64;
        let window = store.read_after(&terminal, 0, u64::MAX).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (12, end));
        assert!(window.bytes.iter().all(|byte| *byte == b'x'));

        // A new incarnation starts a new stream at offset 0.
        let next: Arc<str> = Arc::from("generation-two");
        store.append(&terminal, &next, b"fresh");
        assert_eq!(store.stream_end(&terminal), Some((next.clone(), 5)));

        store.history_cleared(&terminal);
        let window = store.read_after(&terminal, 0, 1 << 20).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (5, 5));
        assert!(window.bytes.is_empty());

        // A terminal that left the daemon stays readable. Output its reader
        // hands over after that (before the runtime stops) joins that tail;
        // it does not bring the terminal back among the live ones.
        store.append(&terminal, &next, b" tail");
        store.forget(&terminal);
        store.append(&terminal, &next, b" late");
        assert!(store.logs.lock().unwrap().is_empty(), "late output revived a departed log");
        let window = store.read_after(&terminal, 5, 1 << 20).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (5, 15));
        assert_eq!(window.bytes, b" tail late");
        // A new incarnation of the terminal (a respawn) is live again.
        let respawned: Arc<str> = Arc::from("generation-three");
        store.append(&terminal, &respawned, b"again");
        assert_eq!(store.stream_end(&terminal), Some((respawned, 5)));
        assert_eq!(store.logs.lock().unwrap().len(), 1);
    }

    /// A clear of a re-adopted terminal that printed nothing yet still
    /// rewrites the snapshot an earlier daemon left, at the saved offset.
    #[test]
    fn a_clear_before_any_output_replaces_the_earlier_snapshot() {
        let directory = std::env::temp_dir().join(format!(
            "cmux-output-store-clear-adopted-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let store = OutputStore::with_policy(
            Some(&directory),
            PersistencePolicy::resolve(Some("snapshot")),
        );
        let terminal = terminal();
        store
            .resume
            .lock()
            .unwrap()
            .insert(terminal.clone(), ("generation-one".to_string(), 1_234));
        store.history_cleared(&terminal);
        assert_eq!(store.stream_end(&terminal), Some((Arc::from("generation-one"), 1_234)));
        assert!(store.writer.pass_due(), "the clear asked for no pass");
        assert_eq!(store.take_dirty().len(), 1);
    }

    /// A departed log that becomes live again (a respawn) asks for a pass on
    /// its next output, also when the pass its last output asked for ran
    /// while it was departed.
    #[test]
    fn a_respawned_terminal_schedules_its_snapshot() {
        let directory = std::env::temp_dir().join(format!(
            "cmux-output-store-respawn-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let store = OutputStore::with_policy(
            Some(&directory),
            PersistencePolicy::resolve(Some("snapshot")),
        );
        let terminal = terminal();
        store.append(&terminal, &Arc::from("generation-one"), b"before the exit");
        assert!(store.writer.pass_due());
        store.forget(&terminal);
        // The writer runs that pass; the departed log is not among the dirty.
        store.writer.take_due_for_test();
        assert!(store.take_dirty().is_empty());

        store.append(&terminal, &Arc::from("generation-two"), b"respawned");
        assert!(store.writer.pass_due(), "the respawned terminal's output asked for no pass");
        assert_eq!(store.take_dirty().len(), 1);
    }

    /// A cursor past the end (a daemon that stopped before it recorded the
    /// end, or an earlier stream) starts at the oldest kept byte, below the
    /// cursor, so the client sees the reset.
    #[test]
    fn a_cursor_past_the_end_restarts_at_the_oldest_kept_byte() {
        let store = OutputStore::with_policy(None, PersistencePolicy::resolve(Some("memory")));
        let generation: Arc<str> = Arc::from("generation-one");
        let terminal = terminal();
        store.append(&terminal, &generation, b"new output");
        let window = store.read_after(&terminal, 1_000, 1 << 20).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (0, 10));
        assert_eq!(window.bytes, b"new output");
        // At the end exactly: empty and complete, as before.
        let window = store.read_after(&terminal, 10, 1 << 20).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (10, 10));
        assert!(window.bytes.is_empty() && !window.truncated);
    }

    /// Departed terminals' tails are bounded: the oldest go first.
    #[test]
    fn departed_tails_are_bounded() {
        let store = OutputStore::with_policy(None, PersistencePolicy::resolve(Some("memory")));
        let generation: Arc<str> = Arc::from("generation-one");
        let terminals = (0..=RETIRED_TAILS)
            .map(|index| {
                TerminalPublicId::parse(format!("term_{:032x}", 0x100 + index))
                    .expect("terminal id")
            })
            .collect::<Vec<_>>();
        for terminal in &terminals {
            store.append(terminal, &generation, b"output");
            store.forget(terminal);
        }
        assert!(store.stream_end(&terminals[0]).is_none(), "the oldest tail was kept");
        assert!(terminals[1..].iter().all(|terminal| store.stream_end(terminal).is_some()));
        // Late output of a departed terminal joins its kept tail.
        store.append(&terminals[1], &generation, b"!");
        assert_eq!(store.stream_end(&terminals[1]), Some((generation, 7)));
    }

    /// A terminal re-adopted from an earlier daemon has a snapshot file and
    /// a resume entry but may print nothing in this one: forgetting it still
    /// asks for the prune that removes its file.
    #[test]
    fn forgetting_a_terminal_that_printed_nothing_prunes_its_files() {
        let directory = std::env::temp_dir()
            .join(format!("cmux-output-store-forget-{}", crate::workspace_registry::new_uuid_v4()));
        let store = OutputStore::with_policy(
            Some(&directory),
            PersistencePolicy::resolve(Some("snapshot")),
        );
        let terminal = terminal();
        store
            .resume
            .lock()
            .unwrap()
            .insert(terminal.clone(), ("generation-one".to_string(), 1_234));
        store.forget(&terminal);
        assert!(store.prune_pending.load(Ordering::Acquire));
        assert!(store.resume.lock().unwrap().is_empty());
    }

    /// A history clear waits for this terminal's own snapshot write only,
    /// not for a write pass over every terminal.
    #[test]
    fn a_history_clear_does_not_wait_for_a_write_pass() {
        let directory = std::env::temp_dir()
            .join(format!("cmux-output-store-clear-{}", crate::workspace_registry::new_uuid_v4()));
        let store = OutputStore::with_policy(
            Some(&directory),
            PersistencePolicy::resolve(Some("snapshot")),
        );
        let generation: Arc<str> = Arc::from("generation-one");
        let terminal = terminal();
        store.append(&terminal, &generation, b"before the clear");
        let log = store.logs.lock().unwrap().get(&terminal).cloned().unwrap();
        let epoch = log.state().clear_epoch;
        // A pass in progress (another terminal's slow write) holds this.
        let _pass = store.lock_pass();
        store.history_cleared(&terminal);
        let state = log.state();
        assert_eq!(state.clear_epoch, epoch + 1, "a pass's earlier capture must not be written");
        assert!(state.dirty && state.tail.is_empty() && state.snapshot_digest.is_none());
        assert_eq!(state.next_offset(), 16);
    }

    #[cfg(unix)]
    fn persistent_mux(name: &str) -> (Arc<Mux>, PathBuf) {
        let root = std::env::temp_dir()
            .join(format!("cmux-output-store-{name}-{}", crate::workspace_registry::new_uuid_v4()));
        let mux = Mux::open_persistent(name, crate::SurfaceOptions::default(), &root).unwrap();
        (mux, root)
    }

    /// Cursor-only output moves the stream end but not the content digest.
    /// A periodic pass writes nothing for it; a checkpoint (and quit) pass
    /// records the new end, so a re-adopted terminal continues from it.
    #[cfg(unix)]
    #[test]
    fn a_checkpoint_records_the_stream_end_of_cursor_only_output() {
        const TERMINAL: &str = "00000000000040008000000000000093";
        const INCARNATION: &str = "10000000000040008000000000000093";
        let (mux, root) = persistent_mux("watermark");
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let surface_id =
            mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
        let surface = mux.surface(surface_id).unwrap();
        let terminal = mux.terminal_resource_id_for_test(TERMINAL);
        let generation: Arc<str> = Arc::from(INCARNATION);
        let print = |bytes: &[u8]| {
            surface.apply_stream_output_for_test(bytes).unwrap();
            mux.output_store.append(&terminal, &generation, bytes);
        };
        let directory = mux.output_store.directory().unwrap().to_path_buf();
        let recorded = || snapshot::stream_ends(&directory).get(&terminal).cloned();

        print(b"some text\r\n");
        mux.output_store.write_now(&mux);
        assert_eq!(recorded(), Some((INCARNATION.to_string(), 11)));

        let cursor: &[u8] = b"\x1b[1;1H\x1b[?25h";
        print(cursor);
        snapshot::write_pass(&mux, &mux.output_store, false);
        assert_eq!(recorded(), Some((INCARNATION.to_string(), 11)), "a periodic pass rewrote");
        mux.output_store.write_now(&mux);
        let end = 11 + cursor.len() as u64;
        assert_eq!(recorded(), Some((INCARNATION.to_string(), end)));

        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(root);
    }

    /// A snapshot write that failed is retried by a later pass even when
    /// the terminal prints nothing more.
    #[cfg(unix)]
    #[test]
    fn a_failed_snapshot_write_is_retried_without_new_output() {
        const TERMINAL: &str = "00000000000040008000000000000094";
        const INCARNATION: &str = "10000000000040008000000000000094";
        let (mux, root) = persistent_mux("retry");
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let surface_id =
            mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
        let surface = mux.surface(surface_id).unwrap();
        let terminal = mux.terminal_resource_id_for_test(TERMINAL);
        let printed: &[u8] = b"retried text\r\n";
        surface.apply_stream_output_for_test(printed).unwrap();
        mux.output_store.append(&terminal, &Arc::from(INCARNATION), printed);
        let directory = mux.output_store.directory().unwrap().to_path_buf();
        // A directory that is not empty where the file goes: the write fails.
        let target = directory.join(format!("{}.snap", terminal.as_str()));
        std::fs::create_dir_all(target.join("occupied")).unwrap();
        snapshot::write_pass(&mux, &mux.output_store, false);
        assert!(!snapshot::stream_ends(&directory).contains_key(&terminal));

        std::fs::remove_dir_all(&target).unwrap();
        snapshot::write_pass(&mux, &mux.output_store, false);
        assert_eq!(
            snapshot::stream_ends(&directory).get(&terminal),
            Some(&(INCARNATION.to_string(), printed.len() as u64))
        );

        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(root);
    }

    /// A writer stuck in file I/O keeps the pass: stop gives up after its
    /// timeout, says so (also at a later stop), and shutdown then skips the
    /// final pass instead of waiting for that writer again.
    #[cfg(unix)]
    #[test]
    fn shutdown_skips_the_final_pass_when_the_writer_does_not_stop() {
        let (mux, root) = persistent_mux("writer-stuck");
        let store = &mux.output_store;
        let pass = store.lock_pass();
        store.writer.mark_dirty(Duration::ZERO);
        // The writer took the due pass; it now waits for `pass` inside it.
        let deadline = std::time::Instant::now() + Duration::from_secs(10);
        while store.writer.pass_due() {
            assert!(std::time::Instant::now() < deadline, "the writer never started its pass");
            std::thread::yield_now();
        }
        assert!(!store.writer.stop(), "a stuck writer reported that it stopped");
        assert!(!store.writer.stop(), "a later stop forgot the detached writer");
        // Returns at once: a final pass would wait for `pass`, held here.
        store.shutdown(&mux);
        drop(pass);
        mux.shutdown();
        drop(mux);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_mode_defaults_to_snapshot() {
        assert_eq!(PersistencePolicy::resolve(None).mode, PersistenceMode::Snapshot);
        assert_eq!(PersistencePolicy::resolve(Some("full")).mode, PersistenceMode::Snapshot);
        let memory = PersistencePolicy::resolve(Some("memory"));
        assert_eq!((memory.mode, memory.max_total_bytes), (PersistenceMode::Memory, 0));
>>>>>>> theirs
    }
}
