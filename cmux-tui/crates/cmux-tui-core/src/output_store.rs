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
}

impl TerminalLog {
    fn state(&self) -> MutexGuard<'_, LogState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
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
        *self.resume.lock().unwrap_or_else(PoisonError::into_inner) =
            snapshot::stream_ends(directory);
        self.writer.start(Arc::downgrade(mux))
    }

    fn log(&self, terminal_id: &TerminalPublicId, generation: &Arc<str>) -> Arc<TerminalLog> {
        let mut logs = self.logs.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(log) = logs.get(terminal_id) {
            return log.clone();
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
            }),
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
        }
        let keep = bytes.len().min(OUTPUT_TAIL_BYTES);
        let skipped = (bytes.len() - keep) as u64;
        let overflow = (state.tail.len() + keep).saturating_sub(OUTPUT_TAIL_BYTES);
        let drained = overflow.min(state.tail.len());
        state.tail.drain(..drained);
        state.tail_start += overflow as u64 + skipped;
        state.tail.extend(&bytes[bytes.len() - keep..]);
        if !state.dirty && !self.memory_only() {
            state.dirty = true;
            drop(state);
            self.writer.mark_dirty(self.snapshot_interval);
        }
    }

    /// The terminal's current generation and the offset after its last byte.
    pub(crate) fn stream_end(&self, terminal_id: &TerminalPublicId) -> Option<(Arc<str>, u64)> {
        let log =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id)?.clone();
        let state = log.state();
        Some((state.generation.clone(), state.next_offset()))
    }

    /// Retained output at or after `after`, at most `max_bytes` (never less
    /// than one byte when any exists). A cursor older than what is kept
    /// starts at the oldest kept byte.
    pub(crate) fn read_after(
        &self,
        terminal_id: &TerminalPublicId,
        after: u64,
        max_bytes: u64,
    ) -> Option<OutputWindow> {
        let log =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id)?.clone();
        let budget = usize::try_from(max_bytes.max(1)).unwrap_or(usize::MAX);
        let state = log.state();
        let end = state.next_offset();
        let start = after.clamp(state.tail_start, end);
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
        // A pass that already read this terminal's screen finishes before
        // the clear, so it cannot write it back afterwards.
        let _pass = self.lock_pass();
        let Some(log) =
            self.logs.lock().unwrap_or_else(PoisonError::into_inner).get(terminal_id).cloned()
        else {
            return;
        };
        {
            let mut state = log.state();
            let end = state.next_offset();
            state.tail.clear();
            state.tail_start = end;
            state.snapshot_digest = None;
            state.dirty = !self.memory_only();
        }
        if !self.memory_only() {
            self.writer.mark_dirty(Duration::ZERO);
        }
    }

    /// Forget a terminal runtime that left this daemon: its memory. The next
    /// write pass removes the files of terminals that left the session.
    pub(crate) fn forget(&self, terminal_id: &TerminalPublicId) {
        if self.logs.lock().unwrap_or_else(PoisonError::into_inner).remove(terminal_id).is_some()
            && !self.memory_only()
        {
            self.prune_pending.store(true, Ordering::Release);
            self.writer.mark_dirty(self.snapshot_interval);
        }
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
    pub(crate) fn shutdown(&self, mux: &Mux) {
        if self.memory_only() {
            return;
        }
        self.writer.stop();
        if !std::thread::panicking() {
            self.write_now(mux);
        }
    }

    /// Write every terminal's snapshot now when its content changed (a
    /// journal checkpoint and quit).
    pub(crate) fn write_now(&self, mux: &Mux) {
        if self.memory_only() {
            return;
        }
        for log in self.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            log.state().dirty = true;
        }
        snapshot::write_pass(mux, self);
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
        assert_eq!(store.stream_end(&terminal), Some((next, 5)));

        store.history_cleared(&terminal);
        let window = store.read_after(&terminal, 0, 1 << 20).unwrap();
        assert_eq!((window.start_offset, window.next_offset), (5, 5));
        assert!(window.bytes.is_empty());

        store.forget(&terminal);
        assert!(store.stream_end(&terminal).is_none());
    }

    #[test]
    fn the_mode_defaults_to_snapshot() {
        assert_eq!(PersistencePolicy::resolve(None).mode, PersistenceMode::Snapshot);
        assert_eq!(PersistencePolicy::resolve(Some("full")).mode, PersistenceMode::Snapshot);
        let memory = PersistencePolicy::resolve(Some("memory"));
        assert_eq!((memory.mode, memory.max_total_bytes), (PersistenceMode::Memory, 0));
    }
}
