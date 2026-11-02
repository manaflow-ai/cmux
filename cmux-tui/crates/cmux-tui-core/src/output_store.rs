//! The terminal output store: where terminal output lives, outside the
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
//!     shell with the snapshot plus its tail: at most the last
//!     [`TAIL_FLUSH_INTERVAL`] of output is lost (REOPEN-F3).
//!   - `full`: the snapshot plus every output byte in per-terminal
//!     compressed segment files (see `output_store/segments.rs`).
//!
//! The append path (each PTY read) only copies bytes into memory under a
//! per-terminal lock. Disk work happens on one background writer thread
//! that sleeps until a terminal has new output, then waits out the interval,
//! so an idle session wakes nothing.

mod memory_budget;
pub(crate) mod segments;
pub(crate) mod snapshot;
mod tail;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use crate::Mux;
use crate::resource::TerminalPublicId;

/// `cmux-next.json` key: `memory`, `snapshot` (default) or `full`.
pub(crate) const PERSISTENCE_MODE_SETTING: &str = "terminal.persistence.mode";
/// `cmux-next.json` key: disk cap per terminal in bytes (mode default when unset).
pub(crate) const PERSISTENCE_MAX_PER_TERMINAL_SETTING: &str =
    "terminal.persistence.maxBytesPerTerminal";
/// `cmux-next.json` key: disk cap across terminals in bytes (mode default when unset).
pub(crate) const PERSISTENCE_MAX_TOTAL_SETTING: &str = "terminal.persistence.maxTotalBytes";
/// Process override of the mode (tests, and a way out when the settings file
/// cannot be read). Same values as the setting.
const PERSISTENCE_MODE_ENV: &str = "CMUX_TUI_TERMINAL_PERSISTENCE";
/// Test-only shorter snapshot interval in milliseconds.
const SNAPSHOT_INTERVAL_ENV: &str = "CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS";

/// The longest a changed terminal waits before its snapshot is written.
pub(crate) const SNAPSHOT_INTERVAL: Duration = Duration::from_secs(30);
/// Full mode: how long new output waits before it goes to a segment file.
pub(crate) const FULL_FLUSH_INTERVAL: Duration = Duration::from_secs(3);
/// Snapshot mode: how long new output waits before it goes to the tail
/// file. The most output a kill of the daemon and its hosts loses.
pub(crate) const TAIL_FLUSH_INTERVAL: Duration = Duration::from_millis(100);
/// Snapshot mode: a tail file written since is fsynced at most this often
/// (the most an OS crash adds to [`TAIL_FLUSH_INTERVAL`]).
pub(crate) const TAIL_SYNC_INTERVAL: Duration = Duration::from_secs(1);
/// Snapshot mode: tail bytes past which the next pass writes a snapshot
/// (the compaction), so a restore replays at most this much over it.
const TAIL_MAX_BYTES: u64 = 1024 * 1024;
/// Snapshot mode: bytes of unchanged content (cursor redraws) a terminal
/// keeps in memory instead of the tail; past it a snapshot replaces them.
const TAIL_IDLE_BYTES: usize = 1024 * 1024;
/// Snapshot mode: unwritten tail bytes one terminal keeps while its writes
/// fail; past it the oldest go and the next snapshot starts the tail again.
const TAIL_MAX_UNWRITTEN_BYTES: usize = 8 * 1024 * 1024;
/// Snapshot mode keeps the screen plus about this many recent lines.
pub(crate) const SNAPSHOT_HISTORY_LINES: usize = 2_000;
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
const STORE_DIRECTORY: &str = "terminal-output";

/// What the store keeps on disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PersistenceMode {
    Memory,
    Snapshot,
    Full,
}

impl PersistenceMode {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "memory" => Some(Self::Memory),
            "snapshot" => Some(Self::Snapshot),
            "full" => Some(Self::Full),
            _ => None,
        }
    }

    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::Snapshot => "snapshot",
            Self::Full => "full",
        }
    }
}

/// The effective persistence settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PersistencePolicy {
    pub(crate) mode: PersistenceMode,
    /// Full mode: segment bytes per terminal. Snapshot mode: the largest
    /// uncompressed replay one snapshot may hold.
    pub(crate) max_bytes_per_terminal: u64,
    pub(crate) max_total_bytes: u64,
    /// Total scrollback RAM across terminals
    /// (`terminal.scrollback.maxTotalMemoryBytes`).
    pub(crate) memory_total_bytes: u64,
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
            };
        }
        let max_total_bytes = total.unwrap_or(default_total).max(MIN_CAP_BYTES);
        let max_bytes_per_terminal =
            per_terminal.unwrap_or(default_per_terminal).max(MIN_CAP_BYTES).min(max_total_bytes);
        Self { mode, max_bytes_per_terminal, max_total_bytes, memory_total_bytes }
    }

    /// The policy from the environment override, else the settings owner.
    pub(crate) fn current(mux: &Arc<Mux>) -> Self {
        let env_mode = std::env::var(PERSISTENCE_MODE_ENV).ok();
        let (mode, per_terminal, total, memory) = mux.with_settings(|state| {
            let value = |key: &str| {
                state.get(&cmux_config::Target::Key(key.to_string())).row.and_then(|row| row.value)
            };
            (
                value(PERSISTENCE_MODE_SETTING).and_then(|value| value.as_str().map(str::to_owned)),
                value(PERSISTENCE_MAX_PER_TERMINAL_SETTING).as_ref().and_then(byte_count),
                value(PERSISTENCE_MAX_TOTAL_SETTING).as_ref().and_then(byte_count),
                value(memory_budget::MEMORY_TOTAL_SETTING).as_ref().and_then(byte_count),
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

/// One terminal's place in its output stream and its in-memory tail.
struct LogState {
    generation: Arc<str>,
    /// Stream offset of `tail[0]`.
    tail_start: u64,
    tail: VecDeque<u8>,
    /// Output arrived since the snapshot writer last looked.
    dirty: bool,
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
    /// Bytes of the tail file and of the last snapshot file on disk.
    tail_file_bytes: u64,
    snapshot_file_bytes: u64,
    /// Snapshot mode: content digest at the last stored byte.
    tail_digest: Option<u64>,
    /// Snapshot mode: when the tail file was last fsynced, and whether a
    /// write followed.
    tail_synced_at: Option<Instant>,
    tail_unsynced: bool,
    /// The next pass writes a snapshot whether or not the content changed
    /// (a gap in the tail, cleared history, a mode change).
    force_snapshot: bool,
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
            tail_file_bytes: 0,
            snapshot_file_bytes: 0,
            tail_digest: None,
            tail_synced_at: None,
            tail_unsynced: false,
            force_snapshot: false,
        }
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

/// One terminal's output log.
pub(crate) struct TerminalLog {
    terminal_id: TerminalPublicId,
    state: Mutex<LogState>,
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
    logs: Mutex<HashMap<TerminalPublicId, Arc<TerminalLog>>>,
    writer: snapshot::Writer,
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
    /// Held by each write pass: the writer thread, a checkpoint and the quit
    /// pass never write the same file at once.
    pass: Mutex<()>,
    /// A terminal runtime left: the next pass removes files of terminals
    /// that are no longer in the session.
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
}

impl OutputStore {
    pub(crate) fn new(registry_directory: Option<&Path>) -> Self {
        let snapshot_interval = std::env::var(SNAPSHOT_INTERVAL_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .map_or(SNAPSHOT_INTERVAL, Duration::from_millis);
        Self {
            directory: registry_directory.map(|directory| directory.join(STORE_DIRECTORY)),
            logs: Mutex::new(HashMap::new()),
            writer: snapshot::Writer::default(),
            full: segments::Segments::default(),
            tail: std::sync::atomic::AtomicBool::new(false),
            last_enforce: Mutex::new(None),
            snapshot_interval,
            policy: Mutex::new(None),
            pass: Mutex::new(()),
            prune_pending: std::sync::atomic::AtomicBool::new(false),
            memory_budget: memory_budget::MemoryBudget::default(),
            resident_total: std::sync::atomic::AtomicU64::new(0),
            resident_trigger: std::sync::atomic::AtomicU64::new(u64::MAX),
            resume: Mutex::new(HashMap::new()),
            segment_resume: Mutex::new(HashMap::new()),
            private: Mutex::new(HashSet::new()),
            public: Mutex::new(HashSet::new()),
        }
    }

    pub(crate) fn directory(&self) -> Option<&Path> {
        self.directory.as_deref()
    }

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

    fn log(&self, terminal_id: &TerminalPublicId, generation: &Arc<str>) -> Arc<TerminalLog> {
        let mut logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(log) = logs.get(terminal_id) {
            return log.clone();
        }
        // A terminal this daemon re-adopted continues its stream where the
        // last snapshot or stored segment frame left it (a client's cursor
        // stays meaningful, and no stored offset is used twice). Segments
        // flush more often than snapshots, and a snapshot can be gone (the
        // total cap) while its segments stay. Both were read at start: no
        // IO here.
        let snapshot_end = self
            .resume
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_id)
            .filter(|(resumed, _)| resumed.as_str() == generation.as_ref())
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
        });
        logs.insert(terminal_id.clone(), log.clone());
        log
    }

    /// Record output the terminal's parser accepted. Memory only: no disk
    /// IO and no syscall on this path (resume offsets were read at start).
    /// `history` is the terminal's history size after the parser took
    /// `bytes` (O(1) reads under the parser lock; `None` when the caller has
    /// no terminal). When the history grew by a step since the terminal's
    /// last measurement, the writer is asked to measure it
    /// (`memory_budget.rs`); this path never walks its pages.
    pub(crate) fn append(
        &self,
        terminal_id: &TerminalPublicId,
        generation: &Arc<str>,
        bytes: &[u8],
        history: Option<HistoryRows>,
    ) {
        if bytes.is_empty() {
            return;
        }
        let log = self.log(terminal_id, generation);
        let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(history) = history
            && !state.measure_due
            && history.moved_past_step(state.measured_rows)
        {
            state.measure_due = true;
            self.writer.request_memory_pass();
        }
        if state.generation != *generation {
            // A new incarnation starts a new stream at offset 0.
            state.generation = generation.clone();
            state.tail_start = 0;
            state.tail.clear();
            state.pending.clear();
            state.pending_start = 0;
        }
        let keep = bytes.len().min(OUTPUT_TAIL_BYTES);
        let skipped = (bytes.len() - keep) as u64;
        let overflow = (state.tail.len() + keep).saturating_sub(OUTPUT_TAIL_BYTES);
        let drained = overflow.min(state.tail.len());
        state.tail.drain(..drained);
        state.tail_start += overflow as u64 + skipped;
        state.tail.extend(bytes.get(bytes.len().saturating_sub(keep)..).unwrap_or_default());
        state.last_output = Instant::now();
        if self.full.enabled() || self.tail_enabled() {
            if state.pending.is_empty() {
                state.pending_start = state.next_offset() - bytes.len() as u64;
            }
            state.pending.extend_from_slice(bytes);
            if state.pending.len() >= FULL_PENDING_WAKE_BYTES {
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

    /// Retained output at or after `after`, at most `max_bytes` (never less
    /// than one byte when any exists). A cursor older than what is kept
    /// starts at the oldest kept byte. Full mode: bytes before the unflushed
    /// ones come from the segment files, read without the terminal's lock.
    pub(crate) fn read_after(
        &self,
        terminal_id: &TerminalPublicId,
        after: u64,
        max_bytes: u64,
    ) -> Option<OutputWindow> {
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
            state.pending.clear();
            state.snapshot_digest = None;
            state.snapshot_at = None;
            state.segment_digest = None;
            state.tail_end = None;
            state.tail_bytes = 0;
            state.tail_file_bytes = 0;
            state.tail_digest = None;
            state.force_snapshot = true;
            state.dirty = true;
        }
        if let Some(directory) = self.directory.as_deref() {
            segments::remove(directory, terminal_id);
            tail::remove(directory, terminal_id);
        }
        self.writer.mark_dirty(Duration::ZERO);
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
    /// last snapshot. `None` in memory mode or when nothing was written.
    /// Memory mode: the writer removes every file at start, and a respawn
    /// that runs before it finds nothing either, since memory mode never
    /// wrote one.
    pub(crate) fn previous_screen(
        &self,
        terminal_id: &TerminalPublicId,
    ) -> Option<crate::workspace_registry::terminal_respawn_store::TerminalReplay> {
        let directory = self.directory.as_deref()?;
        if self.memory_only() {
            return None;
        }
        let (snapshot, generation, snapshot_end) = snapshot::read(directory, terminal_id)?;
        if self.cached_policy().is_some_and(|policy| policy.mode == PersistenceMode::Full)
            && let Some(rebuilt) =
                segments::rebuild(directory, terminal_id, &generation, snapshot.cols, snapshot.rows)
        {
            return Some(rebuilt);
        }
        // Snapshot mode: the output after the snapshot, from its tail.
        Some(tail::restore(directory, terminal_id, &generation, snapshot_end, snapshot))
    }

    /// The logs whose terminal printed since the writer last looked; their
    /// flags are cleared.
    fn take_dirty(&self) -> Vec<Arc<TerminalLog>> {
        let logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        logs.values()
            .filter(|log| {
                let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                std::mem::replace(&mut state.dirty, false)
            })
            .cloned()
            .collect()
    }

    /// Final write at quit, on the caller's thread: stop the writer, then
    /// write every changed terminal once more.
    pub(crate) fn shutdown(&self, mux: &Mux) {
        if self.directory.is_none() {
            return;
        }
        self.writer.stop();
        self.write_now(mux);
    }

    /// Write every terminal's snapshot now when its content changed (a
    /// journal checkpoint and quit): the screen a respawn after a reboot
    /// gets is the screen at this point.
    pub(crate) fn write_now(&self, mux: &Mux) {
        if self.directory.is_none() {
            return;
        }
        for log in self.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            log.state.lock().unwrap_or_else(PoisonError::into_inner).dirty = true;
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
                    log.state.lock().unwrap_or_else(PoisonError::into_inner).dirty = true;
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
    }
}
