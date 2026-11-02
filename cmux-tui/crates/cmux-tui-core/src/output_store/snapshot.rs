//! Snapshot files of the output store: one per terminal, the screen plus
//! about [`super::SNAPSHOT_HISTORY_LINES`] recent lines as a VT replay,
//! gzip-compressed, replaced atomically (temporary file, fsync, rename).
//!
//! A terminal's snapshot is written only when its content changed: the
//! writer compares a digest of the visible text, the size, the active
//! screen and the history epoch (which moves when rows enter or leave the
//! scrollback) with the digest of the last write. A program that only
//! redraws its cursor or repaints the same frame changes none of them, so it
//! writes nothing. The writer thread sleeps until a terminal prints, then
//! waits out the interval, so a changed terminal is written at most once per
//! interval and an idle session wakes nothing.
//!
//! File: `<terminal id>.snap` =
//! `CMUXSNAP1\n` + one JSON line (`generation`, `cols`, `rows`,
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

use super::{OutputStore, PersistenceMode, PersistencePolicy, SNAPSHOT_HISTORY_LINES};
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
        // The mode changed at runtime: drop what the new mode does not keep.
        eprintln!("cmux-tui: terminal output store: mode {}", policy.mode.as_str());
        store.prune_pending.store(true, std::sync::atomic::Ordering::Release);
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
    store.full.set_enabled(full);
    if !full {
        // Unflushed bytes belong to full mode only.
        for log in store.logs.lock().unwrap_or_else(PoisonError::into_inner).values() {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.pending = Vec::new();
            state.pending_start = state.next_offset();
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
    if !dirty.is_empty() {
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
        let (previous, snapshot_due) = {
            let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            let due = quitting
                || !full
                || state.snapshot_at.is_none_or(|at| at.elapsed() >= store.snapshot_interval);
            (state.snapshot_digest, due)
        };
        let captured = surface.try_with_terminal(|terminal| {
            let digest = content_digest(terminal)?;
            if previous == Some(digest) || !snapshot_due {
                return Some((digest, None));
            }
            let (cols, rows) = (terminal.cols(), terminal.rows());
            let budget = replay_budget(cols, rows, policy.max_bytes_per_terminal);
            let replay = terminal.vt_replay_bounded(budget).ok()?.into_self_contained_bytes();
            Some((digest, Some((cols, rows, replay))))
        });
        let Ok(Some((digest, replay))) = captured else {
            digests.push((log, None));
            continue;
        };
        if previous != Some(digest) && !snapshot_due {
            // Full mode writes at most one snapshot per interval.
            store.mark_log_dirty(&log);
        }
        if let Some((cols, rows, replay)) = replay {
            let (generation, stream_end) = {
                let state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                (state.generation.clone(), state.next_offset())
            };
            match write(directory, &log.terminal_id, &generation, stream_end, cols, rows, &replay) {
                Ok(()) => {
                    let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
                    state.snapshot_digest = Some(digest);
                    state.snapshot_at = Some(Instant::now());
                    wrote = true;
                }
                Err(error) => eprintln!(
                    "cmux-tui: terminal {} output snapshot was not written: {error:#}",
                    log.terminal_id
                ),
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

/// Snapshots share the disk cap; in full mode they get a slice of it.
fn snapshot_total_cap(policy: PersistencePolicy) -> u64 {
    match policy.mode {
        PersistenceMode::Full => {
            policy.max_total_bytes.min(super::SNAPSHOT_DEFAULT_MAX_TOTAL_BYTES)
        }
        _ => policy.max_total_bytes,
    }
}

/// Text, size, screen and history epoch: what a cursor redraw does not move.
fn content_digest(terminal: &mut ghostty_vt::Terminal) -> Option<u64> {
    let text = terminal.viewport_text().ok()?;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    terminal.cols().hash(&mut hasher);
    terminal.rows().hash(&mut hasher);
    (terminal.active_screen() == ghostty_vt::Screen::Primary).hash(&mut hasher);
    terminal.history_epoch().hash(&mut hasher);
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

/// The terminal's last snapshot and the generation it belongs to, `None`
/// when absent or unreadable.
pub(super) fn read(
    directory: &Path,
    terminal_id: &TerminalPublicId,
) -> Option<(TerminalReplay, String)> {
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
    Some((
        TerminalReplay {
            cols: u16::try_from(header.get("cols")?.as_u64()?).ok()?,
            rows: u16::try_from(header.get("rows")?.as_u64()?).ok()?,
            bytes,
        },
        generation,
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
