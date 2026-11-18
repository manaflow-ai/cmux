//! The terminal output store: where terminal output lives, outside the
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
//!
//! The append path (each PTY read) only copies bytes into memory under a
//! per-terminal lock. Disk work happens on one background writer thread
//! that sleeps until a terminal has new output, then waits out the interval,
//! so an idle session wakes nothing.

pub(crate) mod snapshot;

use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use crate::Mux;
use crate::resource::TerminalPublicId;

/// Process setting of the mode: `memory` or `snapshot` (the default).
const PERSISTENCE_MODE_ENV: &str = "CMUX_TUI_TERMINAL_PERSISTENCE";
/// Test-only shorter snapshot interval in milliseconds.
const SNAPSHOT_INTERVAL_ENV: &str = "CMUX_TUI_TEST_OUTPUT_SNAPSHOT_INTERVAL_MS";

/// The longest a changed terminal waits before its snapshot is written.
pub(crate) const SNAPSHOT_INTERVAL: Duration = Duration::from_secs(30);
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

/// What the store keeps on disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PersistenceMode {
    Memory,
    Snapshot,
}

impl PersistenceMode {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "memory" => Some(Self::Memory),
            "snapshot" => Some(Self::Snapshot),
            _ => None,
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Memory => "memory",
            Self::Snapshot => "snapshot",
        }
    }
}

/// The effective persistence settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct PersistencePolicy {
    pub(crate) mode: PersistenceMode,
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

/// One terminal's place in its output stream and its in-memory tail.
struct LogState {
    generation: Arc<str>,
    /// Stream offset of `tail[0]`.
    tail_start: u64,
    tail: VecDeque<u8>,
    /// Output arrived since the snapshot writer last looked.
    dirty: bool,
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

/// One terminal's output log.
pub(crate) struct TerminalLog {
    terminal_id: TerminalPublicId,
    state: Mutex<LogState>,
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
    policy: PersistencePolicy,
    logs: Mutex<HashMap<TerminalPublicId, Arc<TerminalLog>>>,
    /// Logs of terminals that left this daemon, newest last (at most
    /// [`RETIRED_TAILS`]); reads only.
    retired: Mutex<VecDeque<Arc<TerminalLog>>>,
    writer: snapshot::Writer,
    snapshot_interval: Duration,
    /// Held by each write pass: the writer thread, a checkpoint and the quit
    /// pass never write the same file at once.
    pass: Mutex<()>,
    /// A terminal runtime left: the next pass removes files of terminals
    /// that are no longer in the session.
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
        let snapshot_interval = std::env::var(SNAPSHOT_INTERVAL_ENV)
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
            .map_or(SNAPSHOT_INTERVAL, Duration::from_millis);
        Self {
            directory: registry_directory.map(|directory| directory.join(STORE_DIRECTORY)),
            policy,
            logs: Mutex::new(HashMap::new()),
            retired: Mutex::new(VecDeque::new()),
            writer: snapshot::Writer::default(),
            snapshot_interval,
            pass: Mutex::new(()),
            prune_pending: AtomicBool::new(false),
            resume: Mutex::new(HashMap::new()),
        }
    }

    pub(crate) fn directory(&self) -> Option<&Path> {
        self.directory.as_deref()
    }

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

    fn log(&self, terminal_id: &TerminalPublicId, generation: &Arc<str>) -> Arc<TerminalLog> {
        let mut logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(log) = logs.get(terminal_id) {
            return log.clone();
        }
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
            .resume
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_id)
            .filter(|(resumed, _)| resumed.as_str() == generation.as_ref())
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
        });
        logs.insert(terminal_id.clone(), log.clone());
        log
    }

    /// Record output the terminal's parser accepted. Memory only: no disk
    /// IO and no syscall on this path.
    pub(crate) fn append(
        &self,
        terminal_id: &TerminalPublicId,
        generation: &Arc<str>,
        bytes: &[u8],
    ) {
        if bytes.is_empty() {
            return;
        }
        let log = self.log(terminal_id, generation);
        let mut state = log.state();
        if state.generation != *generation {
            // A new incarnation starts a new stream at offset 0.
            state.generation = generation.clone();
            state.tail_start = 0;
            state.tail.clear();
            state.snapshot_digest = None;
            state.snapshot_end = None;
        }
        let keep = bytes.len().min(OUTPUT_TAIL_BYTES);
        let skipped = (bytes.len() - keep) as u64;
        let overflow = (state.tail.len() + keep).saturating_sub(OUTPUT_TAIL_BYTES);
        let drained = overflow.min(state.tail.len());
        state.tail.drain(..drained);
        state.tail_start += overflow as u64 + skipped;
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
    }

    /// Retained output at or after `after`, at most `max_bytes` (never less
    /// than one byte when any exists). A cursor older than what is kept
    /// starts at the oldest kept byte. A cursor past the end can only come
    /// from an earlier daemon whose stream end was not recorded (it stopped
    /// without its quit pass): the window starts at the oldest kept byte, so
    /// `start_offset` below the cursor tells the reader to reset.
    pub(crate) fn read_after(
        &self,
        terminal_id: &TerminalPublicId,
        after: u64,
        max_bytes: u64,
    ) -> Option<OutputWindow> {
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
    }

    /// The logs whose terminal printed since the writer last looked; their
    /// flags are cleared.
    fn take_dirty(&self) -> Vec<Arc<TerminalLog>> {
        let logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        logs.values()
            .filter(|log| std::mem::replace(&mut log.state().dirty, false))
            .cloned()
            .collect()
    }

    /// Final write at quit, on the caller's thread: stop the writer, then
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
    }
}

#[cfg(test)]
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
    }
}
