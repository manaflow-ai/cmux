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
//! The capture holds the terminal's parser lock for one digest (the visible
//! text) and, when the content changed, one bounded replay of at most
//! [`MAX_SNAPSHOT_REPLAY_BYTES`]; the PTY reader of that terminal waits for
//! it. `snapshot_capture_holds_the_terminal_lock_briefly` measures that
//! hold and prints it in the test log.
//!
//! File: `<terminal id>.snap` =
//! `CMUXSNAP1\n` + one JSON line (`generation`, `stream_end`, `cols`,
//! `rows`, `written_at_ms`) + gzip of the replay bytes.

use std::fs;
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak, mpsc};
use std::time::{Duration, Instant};

use flate2::Compression;
use flate2::write::GzEncoder;

use super::{OutputStore, PersistenceMode, SNAPSHOT_HISTORY_LINES};
use crate::Mux;
use crate::resource::TerminalPublicId;

const MAGIC: &[u8] = b"CMUXSNAP1\n";
const SUFFIX: &str = "snap";
/// The largest uncompressed replay one snapshot holds.
pub(crate) const MAX_SNAPSHOT_REPLAY_BYTES: usize = 4 * 1024 * 1024;
/// The smallest replay budget, so a narrow terminal still keeps its lines.
const MIN_SNAPSHOT_REPLAY_BYTES: usize = 256 * 1024;

#[derive(Default)]
struct WriterState {
    /// When the pending changes are due; `None` while nothing changed.
    due: Option<Instant>,
    stop: bool,
}

/// How long stop waits for the writer to finish a pass it is in (a pass can
/// stall on file I/O); after that the writer stays detached.
const STOP_TIMEOUT: Duration = Duration::from_secs(5);

/// The writer thread and the channel that closes when it returns or unwinds.
struct WriterThread {
    handle: std::thread::JoinHandle<()>,
    finished: mpsc::Receiver<()>,
}

/// The background writer: one thread, woken by the first output after a
/// write and by stop.
#[derive(Default)]
pub(super) struct Writer {
    state: Arc<(Mutex<WriterState>, Condvar)>,
    thread: Mutex<Option<WriterThread>>,
}

impl Writer {
    pub(super) fn start(&self, mux: Weak<Mux>) -> anyhow::Result<()> {
        let state = self.state.clone();
        let (finished_tx, finished) = mpsc::channel::<()>();
        let handle = std::thread::Builder::new().name("mux-output-store-writer".into()).spawn(
            move || {
                // Dropped on return and on unwind, so stop sees the end.
                let _finished = finished_tx;
                run(&mux, &state);
            },
        )?;
        *self.thread.lock().unwrap_or_else(PoisonError::into_inner) =
            Some(WriterThread { handle, finished });
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

    pub(super) fn stop(&self) {
        {
            let (lock, changed) = &*self.state;
            lock.lock().unwrap_or_else(PoisonError::into_inner).stop = true;
            changed.notify_all();
        }
        let Some(thread) = self.thread.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            return;
        };
        // The writer can hold the last Mux handle, so the Mux may drop (and
        // stop the writer) on the writer thread itself.
        if thread.handle.thread().id() == std::thread::current().id() {
            return;
        }
        match thread.finished.recv_timeout(STOP_TIMEOUT) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                // The thread has returned or unwound: this join is bounded.
                let _ = thread.handle.join();
            }
            Err(mpsc::RecvTimeoutError::Timeout) => eprintln!(
                "cmux-tui: output store writer did not stop within {} ms; it stays detached",
                STOP_TIMEOUT.as_millis()
            ),
        }
    }
}

fn run(mux: &Weak<Mux>, state: &(Mutex<WriterState>, Condvar)) {
    let (lock, changed) = state;
    loop {
        {
            let mut guard = lock.lock().unwrap_or_else(PoisonError::into_inner);
            loop {
                if guard.stop {
                    return;
                }
                match guard.due {
                    None => guard = changed.wait(guard).unwrap_or_else(PoisonError::into_inner),
                    Some(due) => {
                        let now = Instant::now();
                        if now >= due {
                            guard.due = None;
                            break;
                        }
                        guard = changed
                            .wait_timeout(guard, due - now)
                            .unwrap_or_else(PoisonError::into_inner)
                            .0;
                    }
                }
            }
        }
        let Some(mux) = mux.upgrade() else { return };
        write_pass(&mux, &mux.output_store);
    }
}

/// A terminal's screen as a VT replay.
pub(super) struct Replay {
    pub(super) cols: u16,
    pub(super) rows: u16,
    pub(super) bytes: Vec<u8>,
}

/// What one capture under the terminal's parser lock produced.
pub(super) struct Captured {
    pub(super) digest: u64,
    /// `None` when the content is unchanged since `previous`.
    pub(super) replay: Option<Replay>,
}

/// Write the snapshot of every terminal that printed since the last pass and
/// whose content changed; then keep the directory under its cap.
pub(super) fn write_pass(mux: &Mux, store: &OutputStore) {
    let Some(directory) = store.directory() else { return };
    let policy = store.policy;
    let _pass = store.lock_pass();
    let dirty = store.take_dirty();
    let prune_pending = store.prune_pending.swap(false, std::sync::atomic::Ordering::AcqRel);
    if prune_pending || policy.mode == PersistenceMode::Memory {
        prune(mux, store);
    }
    if policy.mode == PersistenceMode::Memory {
        return;
    }
    let mut wrote = false;
    for log in dirty {
        let Some(surface) = mux.output_store_terminal(&log.terminal_id) else { continue };
        let previous = log.state().snapshot_digest;
        let captured = surface.try_with_terminal(|terminal| {
            capture(terminal, previous, policy.max_bytes_per_terminal)
        });
        let Ok(Some(Captured { digest, replay: Some(replay) })) = captured else { continue };
        let (generation, stream_end) = {
            let state = log.state();
            (state.generation.clone(), state.next_offset())
        };
        match write(directory, &log.terminal_id, &generation, stream_end, &replay) {
            Ok(()) => {
                log.state().snapshot_digest = Some(digest);
                wrote = true;
            }
            Err(error) => eprintln!(
                "cmux-tui: terminal {} output snapshot was not written: {error:#}",
                log.terminal_id
            ),
        }
    }
    if wrote {
        enforce_total(directory, SUFFIX, policy.max_total_bytes);
    }
}

/// The capture the writer runs under the terminal's parser lock: the content
/// digest, and the bounded replay when the digest differs from `previous`.
pub(super) fn capture(
    terminal: &mut ghostty_vt::Terminal,
    previous: Option<u64>,
    max_per_terminal: u64,
) -> Option<Captured> {
    let digest = content_digest(terminal)?;
    if previous == Some(digest) {
        return Some(Captured { digest, replay: None });
    }
    let (cols, rows) = (terminal.cols(), terminal.rows());
    let budget = replay_budget(cols, rows, max_per_terminal);
    let bytes = terminal.vt_replay_bounded(budget).ok()?.into_self_contained_bytes();
    Some(Captured { digest, replay: Some(Replay { cols, rows, bytes }) })
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

fn path(directory: &Path, terminal_id: &TerminalPublicId) -> PathBuf {
    directory.join(format!("{}.{SUFFIX}", terminal_id.as_str()))
}

fn write(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    stream_end: u64,
    replay: &Replay,
) -> anyhow::Result<()> {
    fs::create_dir_all(directory)?;
    let header = serde_json::json!({
        "generation": generation,
        "stream_end": stream_end,
        "cols": replay.cols,
        "rows": replay.rows,
        "written_at_ms": crate::workspace_registry::unix_epoch_ms().unwrap_or(0),
    });
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(&replay.bytes)?;
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
            let generation = header["generation"].as_str()?.to_owned();
            let end = header["stream_end"].as_u64()?;
            Some((terminal_id, (generation, end)))
        })
        .collect()
}

/// Remove files the mode does not allow: everything in memory mode, and
/// the files of terminals that are no longer in the session otherwise.
pub(super) fn prune(mux: &Mux, store: &OutputStore) {
    let Some(directory) = store.directory() else { return };
    let Ok(entries) = fs::read_dir(directory) else { return };
    if store.policy.mode == PersistenceMode::Memory {
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
                 CMUX_TUI_TERMINAL_PERSISTENCE is memory"
            );
        }
        return;
    }
    let Ok(live) = mux.live_terminal_public_ids() else { return };
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
}

/// Delete the oldest files with `suffix` until their total is at most `cap`.
fn enforce_total(directory: &Path, suffix: &str, cap: u64) {
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
mod tests {

    use flate2::read::GzDecoder;
    use ghostty_vt::{Callbacks, Terminal};

    use super::*;

    /// The replay of a snapshot file and its header.
    fn read_snapshot(file: &Path) -> (serde_json::Value, Vec<u8>) {
        let contents = fs::read(file).unwrap();
        let rest = contents.strip_prefix(MAGIC).unwrap();
        let newline = rest.iter().position(|byte| *byte == b'\n').unwrap();
        let header = serde_json::from_slice(&rest[..newline]).unwrap();
        let mut bytes = Vec::new();
        GzDecoder::new(&rest[newline + 1..]).read_to_end(&mut bytes).unwrap();
        (header, bytes)
    }

    /// A terminal that printed `lines` colored lines.
    fn printed_terminal(cols: u16, rows: u16, lines: usize) -> Terminal {
        let mut terminal = Terminal::new(cols, rows, 64 * 1024 * 1024, Callbacks::default())
            .expect("terminal for the snapshot test");
        let mut output = Vec::new();
        for line in 0..lines {
            write!(
                output,
                "\x1b[3{}mline {line:06} \x1b[0m{}\r\n",
                line % 8,
                "lorem ipsum dolor sit amet ".repeat(usize::from(cols) / 32)
            )
            .unwrap();
        }
        terminal.vt_write(&output);
        terminal
    }

    /// The writer's capture holds one terminal's parser lock (the PTY reader
    /// of that terminal waits for it). This measures that hold for the
    /// largest snapshot a terminal produces (the screen plus 2,000 lines,
    /// bounded at 4 MiB) and prints it to the unbuffered stderr, so the CI
    /// log shows the numbers next to the passing test. A content digest
    /// that did not change only costs the visible text.
    #[test]
    fn snapshot_capture_holds_the_terminal_lock_briefly() {
        const RUNS: usize = 5;
        for (cols, rows) in [(120_u16, 40_u16), (240, 70)] {
            let mut terminal = printed_terminal(cols, rows, 10_000);
            let mut changed = Duration::ZERO;
            let mut unchanged = Duration::ZERO;
            let mut replay_bytes = 0;
            for _ in 0..RUNS {
                let started = Instant::now();
                let captured =
                    capture(&mut terminal, None, MAX_SNAPSHOT_REPLAY_BYTES as u64).unwrap();
                changed = changed.max(started.elapsed());
                let replay = captured.replay.expect("a changed terminal has a replay");
                assert!(
                    !replay.bytes.is_empty() && replay.bytes.len() <= MAX_SNAPSHOT_REPLAY_BYTES
                );
                replay_bytes = replay.bytes.len();

                let started = Instant::now();
                let again = capture(&mut terminal, Some(captured.digest), u64::MAX).unwrap();
                unchanged = unchanged.max(started.elapsed());
                assert_eq!(again.digest, captured.digest);
                assert!(again.replay.is_none(), "unchanged content captured a replay");
            }
            let _ = writeln!(
                std::io::stderr(),
                "output-store snapshot lock hold {cols}x{rows}, 10000 lines printed: \
                 changed content (digest + {replay_bytes}-byte replay) max {:.2} ms, \
                 unchanged content (digest only) max {:.2} ms, over {RUNS} runs",
                changed.as_secs_f64() * 1000.0,
                unchanged.as_secs_f64() * 1000.0,
            );
        }
    }

    /// A cursor redraw changes nothing the digest covers; printed text does.
    #[test]
    fn a_cursor_redraw_keeps_the_digest_and_new_text_changes_it() {
        let mut terminal = printed_terminal(80, 24, 30);
        let digest = content_digest(&mut terminal).unwrap();
        terminal.vt_write(b"\x1b[?2026h\x1b[39m\x1b[49m\x1b[0m\x1b[20;3H\x1b[?25h\x1b[?2026l");
        assert_eq!(content_digest(&mut terminal), Some(digest));
        terminal.vt_write(b"new text");
        assert_ne!(content_digest(&mut terminal), Some(digest));
    }

    #[test]
    fn snapshot_files_round_trip_their_stream_end() {
        let directory = std::env::temp_dir().join(format!(
            "cmux-output-store-snapshot-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let terminal_id = TerminalPublicId::parse("term_00000000000000000000000000000092").unwrap();
        let mut terminal = printed_terminal(80, 24, 30);
        let replay =
            capture(&mut terminal, None, MAX_SNAPSHOT_REPLAY_BYTES as u64).unwrap().replay.unwrap();
        write(&directory, &terminal_id, "generation-one", 1234, &replay).unwrap();

        let ends = stream_ends(&directory);
        assert_eq!(ends.get(&terminal_id), Some(&("generation-one".to_string(), 1234)));
        let (header, bytes) = read_snapshot(&path(&directory, &terminal_id));
        assert_eq!((header["cols"].as_u64(), header["rows"].as_u64()), (Some(80), Some(24)));
        assert_eq!(bytes, replay.bytes);

        let mut replayed = Terminal::new(80, 24, 64 * 1024 * 1024, Callbacks::default()).unwrap();
        replayed.vt_write(&bytes);
        assert!(replayed.viewport_text().unwrap().contains("line 000029"));
        fs::remove_dir_all(directory).unwrap();
    }
}
