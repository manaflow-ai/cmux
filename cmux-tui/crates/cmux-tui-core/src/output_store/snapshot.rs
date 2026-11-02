//! Snapshot files of the output store: one per terminal, the screen plus
//! about [`super::SNAPSHOT_HISTORY_LINES`] recent lines as a VT replay,
//! gzip-compressed, replaced atomically (temporary file, fsync, rename).
//!
//! A terminal's snapshot is written only when its content changed: the
//! writer compares a digest of the visible text, the size, the active
//! screen, the history epoch (which moves when rows enter or leave the
//! scrollback) and the cursor position with the digest of the last write. A
//! program that redraws its cursor in place or repaints the same frame
//! changes none of them, so it writes nothing. The writer thread sleeps until a terminal prints, then
//! waits out the mode's interval, so an idle session wakes nothing.
//!
//! In snapshot mode the output after a snapshot goes to the terminal's tail
//! file each [`super::TAIL_FLUSH_INTERVAL`] (`tail.rs`), and a snapshot is
//! written at most once per [`super::SNAPSHOT_INTERVAL`] while the content
//! changes, at once for a terminal this daemon has no snapshot of (a new
//! generation), after a resize, when the tail passes its cap, and at quit.
//! The snapshot records the stream offset its screen ends at, read under
//! the parser lock with no parsed chunk in flight, so the tail continues it
//! byte for byte; then the tail file goes.
//!
//! File: `<terminal id>.snap` =
//! `CMUXSNAP1\n` + one JSON line (`generation`, `stream_end`, `cols`, `rows`,
//! `written_at_ms`) + gzip of the replay bytes.

use std::fs;
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;

use super::{OutputStore, PersistenceMode, PersistencePolicy, SNAPSHOT_HISTORY_LINES, TerminalLog};
use crate::Mux;
use crate::resource::TerminalPublicId;
use crate::workspace_registry::terminal_respawn_store::TerminalReplay;

const MAGIC: &[u8] = b"CMUXSNAP1\n";
const SUFFIX: &str = "snap";
/// The largest uncompressed replay one snapshot holds.
pub(crate) const MAX_SNAPSHOT_REPLAY_BYTES: usize = 4 * 1024 * 1024;
/// The smallest replay budget, so a narrow terminal still keeps its lines.
const MIN_SNAPSHOT_REPLAY_BYTES: usize = 256 * 1024;
/// A snapshot file larger than this is not read back (corrupt or foreign).
const MAX_SNAPSHOT_FILE_BYTES: u64 = 16 * 1024 * 1024;

#[derive(Default)]
struct WriterState {
    /// When the pending changes are due; `None` while nothing changed.
    due: Option<Instant>,
    /// A terminal's history grew by a step: its measurement (and a budget
    /// pass when the total is over the trigger) is due now
    /// (`memory_budget.rs`), apart from `due`.
    memory_due: bool,
    stop: bool,
}

/// The background writer: one thread, woken by the first output after a
/// write and by stop.
#[derive(Default)]
pub(super) struct Writer {
    state: Arc<(Mutex<WriterState>, Condvar)>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
}

impl Writer {
    pub(super) fn start(&self, mux: Weak<Mux>) -> anyhow::Result<()> {
        let state = self.state.clone();
        let thread = std::thread::Builder::new()
            .name("mux-output-store-writer".into())
            .spawn(move || run(&mux, &state))?;
        *self.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
        Ok(())
    }

    /// A terminal printed after the writer last looked at it: a pass is due
    /// `interval` from now, unless one is due sooner.
    pub(super) fn mark_dirty(&self, interval: Duration) {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
        let due = Instant::now() + interval;
        if state.due.is_none_or(|current| due < current) {
            state.due = Some(due);
            changed.notify_all();
        }
    }

    /// A terminal's history grew by a step: measure it at once. Requests
    /// coalesce until the writer wakes, so a flood asks for one pass at a
    /// time.
    pub(super) fn request_memory_pass(&self) {
        let (lock, changed) = &*self.state;
        let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
        if !state.memory_due {
            state.memory_due = true;
            changed.notify_all();
        }
    }

    pub(super) fn stop(&self) {
        {
            let (lock, changed) = &*self.state;
            lock.lock().unwrap_or_else(PoisonError::into_inner).stop = true;
            changed.notify_all();
        }
        if let Some(thread) = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take() {
            // The writer can hold the last Mux handle, so the Mux may drop
            // (and stop the writer) on the writer thread itself.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}

fn run(mux: &Weak<Mux>, state: &(Mutex<WriterState>, Condvar)) {
    let (lock, changed) = state;
    loop {
        let memory_only = {
            let mut guard = lock.lock().unwrap_or_else(PoisonError::into_inner);
            loop {
                if guard.stop {
                    return;
                }
                // A due snapshot pass goes first (it measures too), so a
                // stream of measurement requests never starves snapshots.
                if guard.due.is_some_and(|due| Instant::now() >= due) {
                    guard.due = None;
                    guard.memory_due = false;
                    break false;
                }
                if std::mem::take(&mut guard.memory_due) {
                    break true;
                }
                match guard.due {
                    None => guard = changed.wait(guard).unwrap_or_else(PoisonError::into_inner),
                    Some(due) => {
                        let now = Instant::now();
                        if now >= due {
                            guard.due = None;
                            break false;
                        }
                        guard = changed
                            .wait_timeout(guard, due - now)
                            .unwrap_or_else(PoisonError::into_inner)
                            .0;
                    }
                }
            }
        };
        let Some(mux) = mux.upgrade() else { return };
        if memory_only {
            memory_pass(&mux, &mux.output_store);
        } else {
            write_pass(&mux, &mux.output_store);
        }
    }
}

/// Between write passes: measure the terminals whose history grew, and run
/// the budget pass when the total is over its trigger; the snapshots keep
/// their own interval.
fn memory_pass(mux: &Arc<Mux>, store: &OutputStore) {
    let policy = store.cached_policy().unwrap_or_else(|| PersistencePolicy::current(mux));
    let _pass = store.lock_pass();
    super::memory_budget::measure_due(mux, store, policy.memory_total_bytes);
}

/// Write the snapshot of every terminal that printed since the last pass and
/// whose content changed (full mode: also its new bytes as a segment frame);
/// then keep the directory under its caps.
pub(super) fn write_pass(mux: &Arc<Mux>, store: &OutputStore) {
    let policy = PersistencePolicy::current(mux);
    let previous = store.cached_policy();
    store.cache_policy(policy);
    if previous.is_some_and(|previous| previous.mode != policy.mode) {
        // The mode changed at runtime: drop what the new mode does not keep,
        // and start each terminal's files again from a snapshot.
        eprintln!("cmux-tui: terminal output store: mode {}", policy.mode.as_str());
        store.prune_pending.store(true, std::sync::atomic::Ordering::Release);
        for log in store.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.force_snapshot = true;
            state.tail_end = None;
            state.dirty = true;
        }
    }
    write_pass_at(mux, store, policy, false);
}

/// [`write_pass`] at quit: full mode writes a due snapshot at once.
pub(super) fn final_pass(mux: &Mux, store: &OutputStore, policy: PersistencePolicy) {
    write_pass_at(mux, store, policy, true);
}

fn write_pass_at(mux: &Mux, store: &OutputStore, policy: PersistencePolicy, quitting: bool) {
    let Some(directory) = store.directory() else { return };
    let _pass = store.lock_pass();
    let full = policy.mode == PersistenceMode::Full;
    let tail = policy.mode == PersistenceMode::Snapshot;
    store.full.set_enabled(full);
    store.set_tail_enabled(tail);
    if !full {
        for log in store.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if !tail {
                // Unflushed bytes belong to full mode and the tail only.
                state.pending = Vec::new();
                state.pending_start = state.next_offset();
            }
            // The files miss this stretch: back in full mode, the first
            // flush writes whatever the screen shows.
            state.segment_digest = None;
        }
        // Segment files go once full mode is off: their stored ends must not
        // place a terminal's stream later (Full -> other -> Full).
        store.segment_resume.lock().unwrap_or_else(PoisonError::into_inner).clear();
    }
    let dirty = store.without_private(mux, store.take_dirty());
    let prune_pending = store.prune_pending.swap(false, std::sync::atomic::Ordering::AcqRel);
    if !dirty.is_empty() && store.enforce_due(full) {
        // Memory grows only when terminals print.
        super::memory_budget::enforce(mux, store, policy.memory_total_bytes);
    }
    if policy.mode == PersistenceMode::Memory {
        if !dirty.is_empty() || prune_pending {
            prune(mux, store, policy);
        }
        return;
    }
    if prune_pending {
        prune(mux, store, policy);
    }
    let mut wrote = false;
    let mut digests = Vec::with_capacity(dirty.len());
    for log in dirty {
        let Some(surface) = mux.terminal_resource_surface(&log.terminal_id) else {
            digests.push((log, None));
            continue;
        };
        let plan = Plan::of(&log, store.snapshot_interval);
        // Snapshot mode while writes fail: a terminal whose tail does not
        // continue needs a snapshot, and none is tried before the backoff
        // ends. Its bytes wait in memory, bounded.
        if tail
            && !quitting
            && !plan.tail_continues
            && let Some(wait) = plan.retry_wait
        {
            log.state
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .cap_pending(super::TAIL_MAX_UNWRITTEN_BYTES);
            store.mark_log_dirty_after(&log, wait);
            digests.push((log, None));
            continue;
        }
        let mut attempt = 0;
        let captured = loop {
            attempt += 1;
            let captured = surface.try_with_terminal(|terminal| {
                let digest = content_digest(terminal)?;
                let size = (terminal.cols(), terminal.rows());
                // A chunk the reader parsed but has not handed to the store
                // yet (an odd journal capture epoch; the reader flips it under
                // this lock) puts the screen ahead of the stream end: the
                // digest then names no stored byte, and a snapshot would
                // replay that chunk twice with the tail.
                let settled =
                    surface.terminal_journal_capture_epoch().is_some_and(|epoch| epoch & 1 == 0);
                let (generation, end) = {
                    let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                    (state.generation.clone(), state.next_offset())
                };
                let seen = Seen { digest, settled, end, size: Some(size) };
                if !plan.wants_snapshot(digest, size, full, tail, quitting) {
                    return Some((seen, size, Capture::None));
                }
                if !settled {
                    return Some((seen, size, Capture::Busy));
                }
                let budget = replay_budget(size.0, size.1, policy.max_bytes_per_terminal);
                let replay = terminal.vt_replay_bounded(budget).ok()?.into_self_contained_bytes();
                Some((seen, size, Capture::Snapshot { replay, generation, stream_end: end }))
            });
            // The reader hands its chunk over right after it releases the
            // parser lock: a short wait usually finds the terminal settled.
            if attempt < BUSY_ATTEMPTS && matches!(captured, Ok(Some((_, _, Capture::Busy)))) {
                std::thread::sleep(BUSY_RETRY);
                continue;
            }
            break captured;
        };
        let Ok(Some((seen, size, capture))) = captured else {
            digests.push((log, None));
            continue;
        };
        let digest = seen.digest;
        let changed = plan.snapshot_digest != Some(digest);
        match capture {
            Capture::Snapshot { replay, generation, stream_end } => {
                match write(
                    directory,
                    &log.terminal_id,
                    &generation,
                    stream_end,
                    size.0,
                    size.1,
                    &replay,
                ) {
                    Ok(()) => {
                        wrote = true;
                        log.state.lock().unwrap_or_else(PoisonError::into_inner).store_succeeded();
                        snapshot_written(
                            directory,
                            &log,
                            tail,
                            digest,
                            size,
                            &generation,
                            stream_end,
                        );
                    }
                    Err(error) => {
                        report_store_error(&log, "output snapshot", &error);
                        if tail {
                            // One backoff step per pass: a failing append
                            // in flush_tail does not double it again.
                            log.state.lock().unwrap_or_else(PoisonError::into_inner).store_failed();
                            flush_tail(store, directory, &log, seen, quitting);
                        }
                    }
                }
            }
            Capture::Busy => {
                store.mark_log_dirty(&log);
                if tail {
                    flush_tail(store, directory, &log, seen, quitting);
                }
            }
            Capture::None => {
                if full && changed {
                    // Full mode writes at most one snapshot per interval.
                    store.mark_log_dirty(&log);
                }
                if tail {
                    flush_tail(store, directory, &log, seen, quitting);
                }
            }
        }
        digests.push((log, Some(digest)));
    }
    // A failed segment write tries again at the next flush, output or not
    // (a terminal gone idle still gets its bytes stored).
    if full && super::segments::flush_logs(&store.full, directory, &digests, policy, quitting) {
        store.writer.mark_dirty(super::FULL_FLUSH_INTERVAL);
    }
    if wrote {
        enforce_total(directory, SUFFIX, snapshot_total_cap(policy));
    }
}

/// Tries of one terminal's capture while a parsed chunk is in flight.
const BUSY_ATTEMPTS: usize = 4;
const BUSY_RETRY: Duration = Duration::from_millis(1);

/// What a capture saw under the parser lock: the content digest, whether no
/// parsed chunk was in flight, and the stream end then. The digest names
/// the stored bytes up to `end` only when `settled`.
#[derive(Clone, Copy)]
struct Seen {
    digest: u64,
    settled: bool,
    end: u64,
    /// The terminal's size at the capture (`None`: not read).
    size: Option<(u16, u16)>,
}

/// Print a store write error once until the next success (a disk that keeps
/// failing would print it on every pass).
fn report_store_error(log: &TerminalLog, what: &str, error: &anyhow::Error) {
    let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
    if !std::mem::replace(&mut state.store_error, true) {
        eprintln!("cmux-tui: terminal {} {what} was not written: {error:#}", log.terminal_id);
    }
}

/// What one log asks of a pass, read under its lock before the capture.
struct Plan {
    generation: Arc<str>,
    snapshot_digest: Option<u64>,
    snapshot_generation: Option<Arc<str>>,
    snapshot_size: Option<(u16, u16)>,
    interval_due: bool,
    force: bool,
    tail_bytes: u64,
    pending: usize,
    /// The tail file continues the stored snapshot up to the unwritten bytes.
    tail_continues: bool,
    /// Snapshot mode: the time left in a write backoff.
    retry_wait: Option<Duration>,
}

impl Plan {
    fn of(log: &TerminalLog, interval: Duration) -> Self {
        let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        Self {
            generation: state.generation.clone(),
            snapshot_digest: state.snapshot_digest,
            snapshot_generation: state.snapshot_generation.clone(),
            snapshot_size: state.snapshot_size,
            interval_due: state.snapshot_at.is_none_or(|at| at.elapsed() >= interval),
            force: state.force_snapshot,
            tail_bytes: state.tail_bytes,
            pending: state.pending.len(),
            tail_continues: state.snapshot_generation.as_deref() == Some(&*state.generation)
                && state.tail_end == Some(state.pending_start),
            retry_wait: state.retry_wait(),
        }
    }

    /// Whether this pass writes the terminal's snapshot.
    fn wants_snapshot(
        &self,
        digest: u64,
        size: (u16, u16),
        full: bool,
        tail: bool,
        quitting: bool,
    ) -> bool {
        let changed = self.snapshot_digest != Some(digest);
        if !tail {
            // Full mode: at most once per interval, at once at quit.
            return changed && (quitting || !full || self.interval_due);
        }
        // Snapshot mode: the tail continues only a snapshot of this
        // generation and size that this daemon wrote; it is compacted at the
        // interval, when it grows past its cap, when unchanged redraws pile
        // up in memory, and at quit. Never during a write backoff, except
        // at quit and at a journal checkpoint (`write_now`, at most every
        // checkpoint interval): the last or a rare chance.
        if self.retry_wait.is_some() && !quitting {
            return false;
        }
        self.force
            || self.snapshot_generation.as_deref() != Some(&*self.generation)
            || self.snapshot_size != Some(size)
            || (changed && self.interval_due)
            || self.tail_bytes >= super::TAIL_MAX_BYTES
            || self.pending >= super::TAIL_IDLE_BYTES
            || (quitting && (changed || self.pending > 0 || self.tail_bytes > 0))
    }
}

/// The result of one log's capture under its parser lock.
enum Capture {
    /// No snapshot is due.
    None,
    /// A snapshot is due, but a parsed chunk is not in the store yet.
    Busy,
    Snapshot {
        replay: Vec<u8>,
        generation: Arc<str>,
        stream_end: u64,
    },
}

/// The snapshot at `stream_end` is in place: record it, and in snapshot mode
/// drop the tail it covers (the file, then the unwritten bytes before it).
fn snapshot_written(
    directory: &Path,
    log: &TerminalLog,
    tail: bool,
    digest: u64,
    size: (u16, u16),
    generation: &Arc<str>,
    stream_end: u64,
) {
    let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
    state.snapshot_digest = Some(digest);
    state.snapshot_at = Some(Instant::now());
    if state.generation != *generation {
        // A new incarnation started meanwhile: its own snapshot comes next.
        return;
    }
    state.snapshot_end = Some(stream_end);
    state.snapshot_generation = Some(generation.clone());
    state.snapshot_size = Some(size);
    state.force_snapshot = false;
    // The snapshot covers a tail file (one left from snapshot mode too).
    super::tail::remove(directory, &log.terminal_id);
    if !tail {
        return;
    }
    let covered = usize::try_from(stream_end.saturating_sub(state.pending_start))
        .unwrap_or(usize::MAX)
        .min(state.pending.len());
    state.pending.drain(..covered);
    state.pending_start += covered as u64;
    state.tail_end = Some(stream_end);
    state.tail_bytes = 0;
    state.tail_digest = Some(digest);
    state.tail_unsynced = false;
}

/// Snapshot mode: append the terminal's unwritten bytes to its tail, unless
/// they only redraw content already stored (the digest the capture saw is
/// the one of the last stored byte: cursor redraws of an idle TUI wait in
/// memory, up to [`super::TAIL_IDLE_BYTES`], then a snapshot replaces them),
/// and fsync the tail at most every [`super::TAIL_SYNC_INTERVAL`].
fn flush_tail(
    store: &OutputStore,
    directory: &Path,
    log: &TerminalLog,
    seen: Seen,
    quitting: bool,
) {
    let job = {
        let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        let sync_due =
            state.tail_synced_at.is_none_or(|at| at.elapsed() >= super::TAIL_SYNC_INTERVAL);
        if state.pending.is_empty() || (state.tail_digest == Some(seen.digest) && !quitting) {
            // Everything is stored and the capture saw exactly it: its
            // digest names the stored content, so the next redraw waits.
            if state.pending.is_empty() && seen.settled && seen.end == state.pending_start {
                state.tail_digest = Some(seen.digest);
            }
            // Held bytes stay bounded while snapshots cannot be written.
            state.cap_pending(super::TAIL_MAX_UNWRITTEN_BYTES);
            if state.tail_unsynced {
                if sync_due {
                    state.tail_unsynced = false;
                    state.tail_synced_at = Some(Instant::now());
                    drop(state);
                    super::tail::sync(directory, &log.terminal_id);
                } else {
                    drop(state);
                    store.mark_log_dirty(log);
                }
            }
            return;
        }
        // The tail continues a snapshot of this generation and size only (a
        // resize while snapshots fail must not replay new output at the old
        // size), up to the hard cap.
        let continues = state.snapshot_generation.as_deref() == Some(&*state.generation)
            && state.tail_end == Some(state.pending_start)
            && seen.size.is_none_or(|size| state.snapshot_size == Some(size))
            && state.tail_bytes < super::TAIL_HARD_MAX_BYTES;
        let Some(base) = state.snapshot_end.filter(|_| continues) else {
            // The bytes do not continue the stored snapshot: the next pass
            // writes one (it covers them). Bounded while snapshot writes
            // fail: the snapshot holds the screen, not these bytes.
            state.force_snapshot = true;
            state.cap_pending(super::TAIL_MAX_UNWRITTEN_BYTES);
            let wait = state.retry_wait();
            drop(state);
            match wait {
                Some(wait) => store.mark_log_dirty_after(log, wait),
                None => store.mark_log_dirty(log),
            }
            return;
        };
        (state.generation.clone(), base, state.pending_start, state.pending.clone(), sync_due)
    };
    let (generation, base, start, bytes, sync) = job;
    let result =
        super::tail::append(directory, &log.terminal_id, &generation, base, start, &bytes, sync);
    let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
    let ours = state.generation == generation
        && state.pending_start == start
        && state.pending.len() >= bytes.len();
    match result {
        Ok(()) if ours => {
            // The append went through; a snapshot backoff stays until a
            // snapshot is written (a nearly full disk can take small appends
            // and refuse a whole replay).
            state.store_error = false;
            state.pending.drain(..bytes.len());
            state.pending_start = start + bytes.len() as u64;
            state.tail_end = Some(state.pending_start);
            state.tail_bytes += bytes.len() as u64;
            // The digest names these bytes only when the capture saw exactly
            // them: a chunk in flight, or bytes that came after the capture,
            // must not be taken for redraws of stored content.
            let exact = seen.settled && seen.end == state.pending_start;
            state.tail_digest = exact.then_some(seen.digest);
            let more = !state.pending.is_empty() || !exact;
            if sync {
                state.tail_synced_at = Some(Instant::now());
                state.tail_unsynced = false;
            } else {
                state.tail_unsynced = true;
            }
            drop(state);
            if more || !sync {
                store.mark_log_dirty(log);
            }
        }
        Ok(()) => {
            // A new generation or a clear replaced the bytes meanwhile.
            state.force_snapshot = true;
            drop(state);
            store.mark_log_dirty(log);
        }
        Err(error) => {
            // A failed append can leave a cut frame, which ends every read of
            // the file: nothing more goes behind it. The next snapshot
            // starts the tail again; the bytes wait for it, bounded.
            state.tail_end = None;
            state.tail_digest = None;
            state.force_snapshot = true;
            state.cap_pending(super::TAIL_MAX_UNWRITTEN_BYTES);
            // One backoff step per pass (the snapshot write may have taken it).
            let wait = state.retry_wait().unwrap_or_else(|| state.store_failed());
            drop(state);
            report_store_error(log, "output tail", &error);
            store.mark_log_dirty_after(log, wait);
        }
    }
}

/// Snapshots share the disk cap; in full mode they get a slice of it.
fn snapshot_total_cap(policy: PersistencePolicy) -> u64 {
    match policy.mode {
        PersistenceMode::Full => {
            policy.max_total_bytes.min(super::SNAPSHOT_DEFAULT_MAX_TOTAL_BYTES)
        }
        _ => policy.max_total_bytes,
    }
}

/// Text, size, screen, history epoch and cursor position: what a cursor
/// redrawn in place does not move.
fn content_digest(terminal: &mut ghostty_vt::Terminal) -> Option<u64> {
    let text = terminal.viewport_text().ok()?;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    terminal.cols().hash(&mut hasher);
    terminal.rows().hash(&mut hasher);
    (terminal.active_screen() == ghostty_vt::Screen::Primary).hash(&mut hasher);
    terminal.history_epoch().hash(&mut hasher);
    // A cursor that moved is content to restore; one redrawn in place is not.
    terminal.cursor_position().hash(&mut hasher);
    text.hash(&mut hasher);
    Some(hasher.finish())
}

/// Bytes for the screen plus about [`SNAPSHOT_HISTORY_LINES`] lines (a VT
/// replay is bounded in bytes; it keeps the newest rows that fit).
fn replay_budget(cols: u16, rows: u16, max_per_terminal: u64) -> usize {
    let lines = SNAPSHOT_HISTORY_LINES + usize::from(rows);
    let estimate = lines.saturating_mul(usize::from(cols).max(1)).saturating_mul(3);
    let cap = usize::try_from(max_per_terminal)
        .unwrap_or(MAX_SNAPSHOT_REPLAY_BYTES)
        .min(MAX_SNAPSHOT_REPLAY_BYTES);
    estimate.clamp(MIN_SNAPSHOT_REPLAY_BYTES.min(cap), cap)
}

/// Remove terminal `terminal_id`'s snapshot (an incognito terminal).
pub(super) fn remove(directory: &Path, terminal_id: &TerminalPublicId) {
    let _ = fs::remove_file(path(directory, terminal_id));
}

fn path(directory: &Path, terminal_id: &TerminalPublicId) -> PathBuf {
    directory.join(format!("{}.{SUFFIX}", terminal_id.as_str()))
}

fn write(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    stream_end: u64,
    cols: u16,
    rows: u16,
    replay: &[u8],
) -> anyhow::Result<()> {
    fs::create_dir_all(directory)?;
    let header = serde_json::json!({
        "generation": generation,
        "stream_end": stream_end,
        "cols": cols,
        "rows": rows,
        "written_at_ms": crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
    });
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(replay)?;
    let compressed = encoder.finish()?;
    let target = path(directory, terminal_id);
    let staged = target.with_extension(format!("{SUFFIX}.tmp"));
    {
        let mut file = fs::File::create(&staged)?;
        file.write_all(MAGIC)?;
        serde_json::to_writer(&mut file, &header)?;
        file.write_all(b"\n")?;
        file.write_all(&compressed)?;
        file.sync_all()?;
    }
    fs::rename(&staged, &target)?;
    Ok(())
}

/// The header line of a snapshot file (it is short; the replay follows).
fn read_header(file: &Path) -> Option<serde_json::Value> {
    let mut reader = std::io::BufReader::new(fs::File::open(file).ok()?);
    let mut magic = [0_u8; MAGIC.len()];
    reader.read_exact(&mut magic).ok()?;
    (magic == MAGIC).then_some(())?;
    let mut line = Vec::new();
    std::io::BufRead::read_until(&mut (&mut reader).take(4096), b'\n', &mut line).ok()?;
    serde_json::from_slice(line.strip_suffix(b"\n")?).ok()
}

/// The stream end each snapshot recorded, by terminal: (generation, end).
pub(super) fn stream_ends(
    directory: &Path,
) -> std::collections::HashMap<TerminalPublicId, (String, u64)> {
    let Ok(entries) = fs::read_dir(directory) else { return Default::default() };
    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            (path.extension()? == SUFFIX).then_some(())?;
            let terminal_id = TerminalPublicId::parse(path.file_stem()?.to_str()?).ok()?;
            let header = read_header(&path)?;
            let generation = header.get("generation")?.as_str()?.to_owned();
            let end = header.get("stream_end")?.as_u64()?;
            Some((terminal_id, (generation, end)))
        })
        .collect()
}

/// The terminal's last snapshot, the generation it belongs to and the stream
/// offset it ends at (`None` in a file written before it was recorded),
/// `None` when absent or unreadable.
pub(super) fn read(
    directory: &Path,
    terminal_id: &TerminalPublicId,
) -> Option<(TerminalReplay, String, Option<u64>)> {
    let file = path(directory, terminal_id);
    if fs::metadata(&file).ok()?.len() > MAX_SNAPSHOT_FILE_BYTES {
        return None;
    }
    let contents = fs::read(&file).ok()?;
    let rest = contents.strip_prefix(MAGIC)?;
    let newline = rest.iter().position(|byte| *byte == b'\n')?;
    let (header, body) = rest.split_at_checked(newline)?;
    let header: serde_json::Value = serde_json::from_slice(header).ok()?;
    let mut bytes = Vec::new();
    GzDecoder::new(body.get(1..)?)
        .take(MAX_SNAPSHOT_REPLAY_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.is_empty() || bytes.len() > MAX_SNAPSHOT_REPLAY_BYTES {
        return None;
    }
    let generation = header.get("generation")?.as_str()?.to_owned();
    let stream_end = header.get("stream_end").and_then(serde_json::Value::as_u64);
    Some((
        TerminalReplay {
            cols: u16::try_from(header.get("cols")?.as_u64()?).ok()?,
            rows: u16::try_from(header.get("rows")?.as_u64()?).ok()?,
            bytes,
        },
        generation,
        stream_end,
    ))
}

/// Remove files the policy does not allow: everything in memory mode, and
/// the files of terminals that are no longer in the session otherwise.
pub(super) fn prune(mux: &Mux, store: &OutputStore, policy: PersistencePolicy) {
    let Some(directory) = store.directory() else { return };
    let Ok(entries) = fs::read_dir(directory) else { return };
    if policy.mode == PersistenceMode::Memory {
        let mut removed = 0_usize;
        for entry in entries.flatten() {
            let path = entry.path();
            let result =
                if path.is_dir() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) };
            removed += usize::from(result.is_ok());
        }
        if removed > 0 {
            eprintln!(
                "cmux-tui: terminal output store removed {removed} file(s): \
                 terminal.persistence.mode is memory"
            );
        }
        return;
    }
    let live = mux
        .workspace_registry
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .live_terminal_public_ids();
    let Ok(live) = live else { return };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        let id = name.split('.').next().unwrap_or_default();
        let Ok(terminal_id) = TerminalPublicId::parse(id) else { continue };
        if live.contains(&terminal_id) {
            continue;
        }
        let path = entry.path();
        let _ = if path.is_dir() { fs::remove_dir_all(&path) } else { fs::remove_file(&path) };
    }
    if policy.mode != PersistenceMode::Full {
        super::segments::remove_all(directory);
    }
}

/// Delete the oldest files with `suffix` until their total is at most `cap`.
pub(super) fn enforce_total(directory: &Path, suffix: &str, cap: u64) {
    let Ok(entries) = fs::read_dir(directory) else { return };
    let mut files = entries
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|extension| extension == suffix))
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            Some((metadata.modified().ok()?, metadata.len(), entry.path()))
        })
        .collect::<Vec<_>>();
    let mut total = files.iter().map(|(_, len, _)| len).sum::<u64>();
    if total <= cap {
        return;
    }
    files.sort();
    for (_, len, path) in files {
        if total <= cap {
            break;
        }
        if fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

#[cfg(test)]
#[path = "snapshot_tests.rs"]
mod tests;
