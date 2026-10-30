//! Full-mode segment files: every output byte a terminal printed, outside
//! the journal, in append-only compressed files per terminal.
//!
//! `<store>/<terminal id>/<generation key>-<first offset>.seg` holds frames:
//! `start offset (u64 LE) | compressed length (u32 LE) | raw length (u32 LE)
//! | gzip`. The writer appends one frame per terminal per flush (every few
//! seconds and at quit, never an fsync per write) and starts a new file past
//! [`SEGMENT_FILE_BYTES`]. A frame cut by a crash is ignored when read.
//!
//! A flush whose terminal content did not change since the previous stored
//! frame (the same digest the snapshot writer uses: a cursor redraw or a
//! repaint of the same frame) keeps its bytes in memory, up to
//! [`UNCHANGED_FLUSH_BYTES`], and writes them with the next change or at
//! quit. The files hold every byte in order, and an idle terminal writes
//! almost nothing.
//!
//! Caps: per terminal (`terminal.persistence.maxBytesPerTerminal`, default
//! 100 MB) and in total (`terminal.persistence.maxTotalBytes`, default
//! 2 GB). Past a cap the oldest files go first.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, PoisonError};

use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;

use super::{OutputWindow, PersistencePolicy, TerminalLog};
use crate::resource::TerminalPublicId;

const SUFFIX: &str = "seg";
/// A segment file is closed and a new one started past this size.
const SEGMENT_FILE_BYTES: u64 = 8 * 1024 * 1024;
const FRAME_HEADER_BYTES: usize = 16;
/// Unchanged-content bytes a terminal holds before they are written anyway.
const UNCHANGED_FLUSH_BYTES: usize = 1024 * 1024;
/// The largest raw frame a reader accepts (a flush is at most a few MB).
const MAX_FRAME_RAW_BYTES: u32 = 64 * 1024 * 1024;

/// Whether full mode collects bytes (set by the writer from the policy).
#[derive(Default)]
pub(crate) struct Segments {
    enabled: AtomicBool,
    /// Segment files this daemon last appended to, with the length it left:
    /// a file of that length ends with a whole frame (no header walk).
    verified: std::sync::Mutex<std::collections::HashMap<PathBuf, u64>>,
}

impl Segments {
    pub(crate) fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    pub(crate) fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::Relaxed);
    }
}

fn generation_key(generation: &str) -> String {
    // A stable digest (std's hasher may change between Rust releases, and
    // file names must outlive a daemon upgrade).
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(generation.as_bytes());
    digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect()
}

fn terminal_directory(directory: &Path, terminal_id: &TerminalPublicId) -> PathBuf {
    directory.join(terminal_id.as_str())
}

/// The segment files of one generation, oldest first: (first offset, path).
fn generation_files(terminal_directory: &Path, generation: &str) -> Vec<(u64, PathBuf)> {
    let key = generation_key(generation);
    let Ok(entries) = fs::read_dir(terminal_directory) else { return Vec::new() };
    let mut files = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let stem = path.file_stem()?.to_str()?.to_owned();
            if path.extension()? != SUFFIX {
                return None;
            }
            let (file_key, start) = stem.split_once('-')?;
            (file_key == key).then_some(())?;
            Some((start.parse::<u64>().ok()?, path))
        })
        .collect::<Vec<_>>();
    files.sort();
    files
}

/// Append the pending bytes of each log as one frame (content-changed logs
/// only, `digests` from the snapshot writer), then apply the caps.
pub(super) fn flush_logs(
    segments: &Segments,
    directory: &Path,
    logs: &[(Arc<TerminalLog>, Option<u64>)],
    policy: PersistencePolicy,
    quitting: bool,
) {
    let mut wrote = false;
    for (log, digest) in logs {
        let (generation, start, bytes) = {
            let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
            if state.pending.is_empty() {
                continue;
            }
            // Redraws of unchanged content (a blinking or moving cursor)
            // wait in memory until a change, quit or
            // [`UNCHANGED_FLUSH_BYTES`]: an idle terminal writes almost
            // nothing, and the files still hold every byte in order.
            let unchanged = digest.is_some() && *digest == state.segment_digest;
            if unchanged && !quitting && state.pending.len() < UNCHANGED_FLUSH_BYTES {
                continue;
            }
            let bytes = std::mem::take(&mut state.pending);
            state.segment_digest = *digest;
            (state.generation.clone(), state.pending_start, bytes)
        };
        let terminal_directory = terminal_directory(directory, &log.terminal_id);
        match append_frame(segments, &terminal_directory, &generation, start, &bytes) {
            Ok(()) => wrote = true,
            Err(error) => eprintln!(
                "cmux-tui: terminal {} output segment was not written: {error:#}",
                log.terminal_id
            ),
        }
        enforce_terminal_cap(&terminal_directory, policy.max_bytes_per_terminal);
    }
    if wrote {
        enforce_total_cap(directory, policy.max_total_bytes);
    }
}

fn append_frame(
    segments: &Segments,
    terminal_directory: &Path,
    generation: &str,
    start: u64,
    bytes: &[u8],
) -> anyhow::Result<()> {
    fs::create_dir_all(terminal_directory)?;
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(bytes)?;
    let compressed = encoder.finish()?;
    let mut verified = segments.verified.lock().unwrap_or_else(PoisonError::into_inner);
    // Append to the newest file while it is small. A file this daemon did
    // not leave at its current length (an earlier run, a crash) is checked
    // once: a cut frame at its end is cut off, so the frames written after
    // it stay readable.
    let newest = generation_files(terminal_directory, generation).pop();
    let file = match newest {
        Some((file_start, path)) => {
            let len = fs::metadata(&path)?.len();
            if len < SEGMENT_FILE_BYTES {
                // A file that cannot be checked (open or read error) is left
                // as it is, and the frame goes to a new file.
                let checked = if verified.get(&path) == Some(&len) {
                    Some(len)
                } else {
                    frame_extent(&path, file_start).map(|(whole, _)| whole)
                };
                match checked {
                    Some(whole) => {
                        if whole < len {
                            fs::OpenOptions::new().write(true).open(&path)?.set_len(whole)?;
                        }
                        path
                    }
                    None => terminal_directory
                        .join(format!("{}-{start:020}.{SUFFIX}", generation_key(generation))),
                }
            } else {
                terminal_directory
                    .join(format!("{}-{start:020}.{SUFFIX}", generation_key(generation)))
            }
        }
        None => {
            terminal_directory.join(format!("{}-{start:020}.{SUFFIX}", generation_key(generation)))
        }
    };
    let mut frame = Vec::with_capacity(FRAME_HEADER_BYTES + compressed.len());
    frame.extend_from_slice(&start.to_le_bytes());
    frame.extend_from_slice(&u32::try_from(compressed.len())?.to_le_bytes());
    frame.extend_from_slice(&u32::try_from(bytes.len())?.to_le_bytes());
    frame.extend_from_slice(&compressed);
    let mut handle = fs::OpenOptions::new().create(true).append(true).open(&file)?;
    handle.write_all(&frame)?;
    let len = handle.metadata()?.len();
    verified.retain(|path, _| path.parent() != Some(terminal_directory));
    verified.insert(file, len);
    Ok(())
}

/// Frames of a segment file in order: (start offset, raw bytes). Stops at a
/// cut or corrupt frame.
fn frames(path: &Path) -> Vec<(u64, Vec<u8>)> {
    let Ok(contents) = fs::read(path) else { return Vec::new() };
    let mut out = Vec::new();
    let mut at = 0;
    use crate::terminal_host_protocol::{wire_u32, wire_u64};
    while contents.len().saturating_sub(at) >= FRAME_HEADER_BYTES {
        let (Some(start), Some(compressed), Some(raw)) =
            (wire_u64(&contents, at), wire_u32(&contents, at + 8), wire_u32(&contents, at + 12))
        else {
            break;
        };
        let body = at + FRAME_HEADER_BYTES;
        let Some(end) = body.checked_add(compressed as usize).filter(|end| *end <= contents.len())
        else {
            break;
        };
        if raw > MAX_FRAME_RAW_BYTES {
            break;
        }
        let mut bytes = Vec::with_capacity(raw as usize);
        let Some(frame) = contents.get(body..end) else { break };
        if GzDecoder::new(frame).take(u64::from(raw) + 1).read_to_end(&mut bytes).is_err()
            || bytes.len() != raw as usize
        {
            break;
        }
        out.push((start, bytes));
        at = end;
    }
    out
}

/// Stored output of `generation` at or after `after`, at most `budget`
/// bytes. `None` when nothing stored reaches past `after`.
pub(super) fn read_after(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    after: u64,
    budget: usize,
) -> Option<OutputWindow> {
    let files = generation_files(&terminal_directory(directory, terminal_id), generation);
    // The last file that starts at or before the cursor, and every later one.
    let first = files.iter().rposition(|(start, _)| *start <= after).unwrap_or(0);
    let mut window: Option<OutputWindow> = None;
    'files: for (_, path) in files.get(first..).unwrap_or_default() {
        for (start, bytes) in frames(path) {
            let end = start + bytes.len() as u64;
            if end <= after {
                continue;
            }
            if let Some(window) = window.as_mut() {
                if end <= window.next_offset {
                    // Already in the window (an overlapping older frame).
                    continue;
                }
                if start > window.next_offset {
                    // A gap (bytes lost in a crash): the window ends before
                    // it, and the next read starts after it.
                    window.truncated = true;
                    break 'files;
                }
            }
            let window = window.get_or_insert_with(|| OutputWindow {
                start_offset: start.max(after),
                next_offset: start.max(after),
                bytes: Vec::new(),
                truncated: false,
            });
            let room = budget.saturating_sub(window.bytes.len());
            if room == 0 {
                window.truncated = true;
                break 'files;
            }
            // Bytes before the window's end (or the cursor) are skipped.
            let skip =
                usize::try_from(window.next_offset.saturating_sub(start)).unwrap_or(usize::MAX);
            let piece = bytes.get(skip..).unwrap_or_default();
            let take = piece.len().min(room);
            window.bytes.extend_from_slice(piece.get(..take).unwrap_or(piece));
            window.next_offset = start + (skip.min(bytes.len()) + take) as u64;
            if take < piece.len() {
                window.truncated = true;
                break 'files;
            }
        }
    }
    window
}

/// The frames of a segment file read from their headers only (seeks, no
/// decompression): (bytes of whole frames, offset after the last frame).
/// A cut frame (a crash during a write) ends the walk.
fn frame_extent(path: &Path, file_start: u64) -> Option<(u64, u64)> {
    use crate::terminal_host_protocol::{wire_u32, wire_u64};
    use std::io::{Seek, SeekFrom};
    let mut file = fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let mut at = 0_u64;
    let mut end = file_start;
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    while len - at >= FRAME_HEADER_BYTES as u64 {
        file.seek(SeekFrom::Start(at)).ok()?;
        file.read_exact(&mut header).ok()?;
        let start = wire_u64(&header, 0)?;
        let compressed = u64::from(wire_u32(&header, 8)?);
        let raw = wire_u32(&header, 12)?;
        let next = at + FRAME_HEADER_BYTES as u64 + compressed;
        if next > len || raw > MAX_FRAME_RAW_BYTES {
            break;
        }
        end = end.max(start.checked_add(u64::from(raw))?);
        at = next;
    }
    Some((at, end))
}

/// The stored stream end of every terminal and generation key (newest file
/// of each generation, frame headers only): read once at start.
pub(super) fn all_stream_ends(
    directory: &Path,
) -> std::collections::HashMap<(TerminalPublicId, String), u64> {
    let mut ends = std::collections::HashMap::new();
    let Ok(entries) = fs::read_dir(directory) else { return ends };
    for entry in entries.flatten() {
        let path = entry.path();
        let Some(terminal_id) = path
            .is_dir()
            .then(|| path.file_name()?.to_str().and_then(|name| TerminalPublicId::parse(name).ok()))
            .flatten()
        else {
            continue;
        };
        let Ok(files) = fs::read_dir(&path) else { continue };
        let mut newest = std::collections::HashMap::<String, (u64, PathBuf)>::new();
        for file in files.flatten().map(|file| file.path()) {
            let Some((key, start)) = file
                .file_stem()
                .and_then(|stem| stem.to_str())
                .filter(|_| file.extension().is_some_and(|extension| extension == SUFFIX))
                .and_then(|stem| stem.split_once('-'))
                .and_then(|(key, start)| Some((key.to_owned(), start.parse::<u64>().ok()?)))
            else {
                continue;
            };
            if newest.get(&key).is_none_or(|(current, _)| start > *current) {
                newest.insert(key, (start, file));
            }
        }
        for (key, (start, file)) in newest {
            let end = frame_extent(&file, start).map_or(start, |(_, end)| end);
            ends.insert((terminal_id.clone(), key), end);
        }
    }
    ends
}

/// The generation key of segment file names.
pub(super) fn key_of(generation: &str) -> String {
    generation_key(generation)
}

/// Raw bytes a rebuild replays at most (the newest frames).
const REBUILD_MAX_RAW_BYTES: usize = 64 * 1024 * 1024;
/// Scrollback of the rebuild terminal (Ghostty's default limit).
const REBUILD_SCROLLBACK_BYTES: usize = 10_000_000;

/// The terminal of `generation` rebuilt from its stored frames (the newest
/// [`REBUILD_MAX_RAW_BYTES`]) as a VT replay that fits a respawn seed.
pub(super) fn rebuild(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    cols: u16,
    rows: u16,
) -> Option<crate::workspace_registry::terminal_respawn_store::TerminalReplay> {
    let files = generation_files(&terminal_directory(directory, terminal_id), generation);
    let mut newest = Vec::new();
    let mut total = 0_usize;
    'files: for (_, path) in files.iter().rev() {
        for (_, bytes) in frames(path).into_iter().rev() {
            total += bytes.len();
            newest.push(bytes);
            if total >= REBUILD_MAX_RAW_BYTES {
                break 'files;
            }
        }
    }
    if newest.is_empty() {
        return None;
    }
    let mut terminal = ghostty_vt::Terminal::new(
        cols.max(1),
        rows.max(1),
        REBUILD_SCROLLBACK_BYTES,
        ghostty_vt::Callbacks::default(),
    )
    .ok()?;
    for bytes in newest.iter().rev() {
        terminal.vt_write(bytes);
    }
    // Room for the respawn's marker line and mode reset.
    let budget = crate::surface::VT_REPLAY_MAX_BYTES.saturating_sub(64 * 1024);
    let bytes = terminal.vt_replay_bounded(budget).ok()?.into_self_contained_bytes();
    Some(crate::workspace_registry::terminal_respawn_store::TerminalReplay { cols, rows, bytes })
}

fn segment_files(directory: &Path) -> Vec<(std::time::SystemTime, u64, PathBuf)> {
    let Ok(entries) = fs::read_dir(directory) else { return Vec::new() };
    entries
        .flatten()
        .filter(|entry| entry.path().extension().is_some_and(|extension| extension == SUFFIX))
        .filter_map(|entry| {
            let metadata = entry.metadata().ok()?;
            Some((metadata.modified().ok()?, metadata.len(), entry.path()))
        })
        .collect()
}

fn delete_oldest(mut files: Vec<(std::time::SystemTime, u64, PathBuf)>, cap: u64) {
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

fn enforce_terminal_cap(terminal_directory: &Path, cap: u64) {
    delete_oldest(segment_files(terminal_directory), cap);
}

fn enforce_total_cap(directory: &Path, cap: u64) {
    let Ok(entries) = fs::read_dir(directory) else { return };
    let files = entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .flat_map(|entry| segment_files(&entry.path()))
        .collect::<Vec<_>>();
    delete_oldest(files, cap);
}

/// Remove one terminal's segments.
pub(super) fn remove(directory: &Path, terminal_id: &TerminalPublicId) {
    let _ = fs::remove_dir_all(terminal_directory(directory, terminal_id));
}

/// Remove every terminal's segments (the mode is no longer `full`).
pub(super) fn remove_all(directory: &Path) {
    let Ok(entries) = fs::read_dir(directory) else { return };
    for entry in entries.flatten() {
        if entry.path().is_dir() {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}
