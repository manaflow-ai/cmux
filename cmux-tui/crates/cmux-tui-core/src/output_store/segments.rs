//! Full-mode segment files: every output byte a terminal printed, outside
//! the journal, in append-only compressed files per terminal.
//!
//! `<store>/<terminal id>/<generation key>-<first offset>.seg` holds frames:
//! `start offset (u64 LE) | compressed length (u32 LE) | raw length (u32 LE)
//! | gzip`. The writer appends one frame per terminal per flush (every few
//! seconds and at quit, never an fsync per write) and starts a new file past
//! [`SEGMENT_FILE_BYTES`]. A frame cut by a crash is ignored when read. A
//! newest file that cannot be checked is left as it is; when it holds the
//! new file's name, the new one is `<key>-<first offset>-<n>.seg`.
//!
//! A flush whose terminal content did not change since the previous stored
//! frame (the same digest the snapshot writer uses: a cursor redraw or a
//! repaint of the same frame) keeps its bytes in memory, up to
//! [`UNCHANGED_FLUSH_BYTES`], and writes them with the next change or at
//! quit. The files hold every byte in order, and an idle terminal writes
//! almost nothing.
//!
//! A frame that cannot be written stays in memory and is retried on the next
//! pass, up to [`MAX_UNWRITTEN_BYTES`] per terminal; past it the oldest
//! unwritten bytes are dropped and a read reports the gap.
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
/// Bytes a terminal keeps in memory while its segment writes fail: the
/// newest are kept for the retry, older ones are dropped (a reported gap).
const MAX_UNWRITTEN_BYTES: usize = SEGMENT_FILE_BYTES as usize;

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

/// The key files were named with before the stable digest (std's hasher):
/// read only, so a daemon upgrade still finds the segments it stored.
fn legacy_generation_key(generation: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    generation.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

fn terminal_directory(directory: &Path, terminal_id: &TerminalPublicId) -> PathBuf {
    directory.join(terminal_id.as_str())
}

/// A segment file name: `<key>-<first offset>.seg`, or
/// `<key>-<first offset>-<n>.seg` for the n-th file started at the same
/// offset beside one that could not be used. Returns (key, first offset, n).
fn parse_file_name(path: &Path) -> Option<(&str, u64, u32)> {
    if path.extension()? != SUFFIX {
        return None;
    }
    let (key, rest) = path.file_stem()?.to_str()?.split_once('-')?;
    let (start, n) = match rest.split_once('-') {
        Some((start, n)) => (start, n.parse::<u32>().ok()?),
        None => (rest, 0),
    };
    Some((key, start.parse::<u64>().ok()?, n))
}

/// The segment files of one generation, oldest first: (first offset, path).
fn generation_files(terminal_directory: &Path, generation: &str) -> Vec<(u64, PathBuf)> {
    let keys = keys_of(generation);
    let Ok(entries) = fs::read_dir(terminal_directory) else { return Vec::new() };
    let mut files = entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let (file_key, start, n) = parse_file_name(&path)?;
            keys.iter().any(|key| key == file_key).then_some(())?;
            Some(((start, n), path))
        })
        .collect::<Vec<_>>();
    files.sort();
    files.into_iter().map(|((start, _), path)| (start, path)).collect()
}

/// Files a frame may be started in beside unusable ones at its offset.
const MAX_SIBLING_FILES: u32 = 64;

/// A name for a new file whose first frame starts at `start` that no entry
/// of the folder has (an unusable file may hold the plain name).
fn new_file_path(terminal_directory: &Path, generation: &str, start: u64) -> Option<PathBuf> {
    let key = generation_key(generation);
    (0..MAX_SIBLING_FILES)
        .map(|n| {
            let name = if n == 0 {
                format!("{key}-{start:020}.{SUFFIX}")
            } else {
                format!("{key}-{start:020}-{n}.{SUFFIX}")
            };
            terminal_directory.join(name)
        })
        .find(|path| {
            fs::symlink_metadata(path)
                .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
        })
}

/// Append the pending bytes of each log as one frame (content-changed logs
/// only, `digests` from the snapshot writer), then apply the caps. Returns
/// whether a write failed (those logs are dirty again: the caller schedules
/// another pass).
pub(super) fn flush_logs(
    segments: &Segments,
    directory: &Path,
    logs: &[(Arc<TerminalLog>, Option<u64>)],
    policy: PersistencePolicy,
    quitting: bool,
) -> bool {
    let mut wrote = false;
    let mut failed = false;
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
            // A copy: the bytes stay readable from memory until the frame
            // that holds them is in the file (a read never sees them in
            // neither place).
            let bytes = state.pending.clone();
            state.segment_digest = *digest;
            (state.generation.clone(), state.pending_start, bytes)
        };
        let terminal_directory = terminal_directory(directory, &log.terminal_id);
        let written = match append_frame(segments, &terminal_directory, &generation, start, &bytes)
        {
            Ok(()) => true,
            Err(error) => {
                eprintln!(
                    "cmux-tui: terminal {} output segment was not written: {error:#}",
                    log.terminal_id
                );
                false
            }
        };
        wrote |= written;
        let mut state = log.state.lock().unwrap_or_else(PoisonError::into_inner);
        // A new generation, a mode change or a clear replaced the bytes
        // meanwhile: nothing here is ours to drop.
        let ours = state.generation == generation
            && state.pending_start == start
            && state.pending.len() >= bytes.len();
        if ours && written {
            // Only written bytes leave memory: every byte before
            // `unflushed_start` is in a segment file (read_after relies on it).
            state.pending.drain(..bytes.len());
            state.pending_start = start + bytes.len() as u64;
        } else if ours {
            // Not written (a full disk, an IO error): the next pass tries
            // again, changed content or not. Memory stays bounded on
            // purpose (a busy terminal on a full disk must not grow the
            // daemon without limit): past MAX_UNWRITTEN_BYTES the oldest
            // unwritten bytes go, and a read reports the gap (the window
            // ends truncated and the next one starts after it).
            state.segment_digest = None;
            state.dirty = true;
            failed = true;
            let excess = state.pending.len().saturating_sub(MAX_UNWRITTEN_BYTES);
            if excess > 0 {
                state.pending.drain(..excess);
                state.pending_start += excess as u64;
                eprintln!(
                    "cmux-tui: terminal {} dropped {excess} output bytes that could not be stored",
                    log.terminal_id
                );
            }
        }
        drop(state);
        enforce_terminal_cap(&terminal_directory, policy.max_bytes_per_terminal);
    }
    if wrote {
        enforce_total_cap(directory, policy.max_total_bytes);
    }
    failed
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
    // A file that cannot be checked (a stat, open or read error) or that
    // holds a whole frame that does not decode is left as it is, and the
    // frame goes to a new file: a read stops at an undecodable frame in its
    // file, so frames appended after it would never be read.
    let reusable = newest.and_then(|(_, path)| {
        let len = fs::metadata(&path).ok()?.len();
        if len >= SEGMENT_FILE_BYTES {
            return None;
        }
        let whole =
            if verified.get(&path) == Some(&len) { len } else { whole_decodable_frames(&path)? };
        Some((path, len, whole))
    });
    let file = match reusable {
        Some((path, len, whole)) => {
            if whole < len {
                fs::OpenOptions::new().write(true).open(&path)?.set_len(whole)?;
            }
            path
        }
        None => new_file_path(terminal_directory, generation, start)
            .ok_or_else(|| anyhow::anyhow!("no free segment file name at offset {start}"))?,
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
///
/// Every file of the generation takes part, not only those named at or
/// after the cursor: a file named earlier can hold bytes after it (an older
/// daemon resumed behind, so files overlap). Frames are taken in stream
/// order from their headers, and only the frames the window needs are
/// decompressed. A cursor in a range no file holds starts at the next stored
/// byte (`start_offset` says where), as a memory read starts at the oldest
/// kept byte; a gap after the window's first byte ends the window as
/// truncated, and the next read starts after it.
pub(super) fn read_after(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    after: u64,
    budget: usize,
) -> Option<OutputWindow> {
    let files = generation_files(&terminal_directory(directory, terminal_id), generation);
    // (header, file index, place in its file) of every frame past the cursor.
    let mut headers = Vec::new();
    for (index, (_, path)) in files.iter().enumerate() {
        let Some((frames, _)) = frame_headers(path) else { continue };
        headers.extend(
            frames
                .into_iter()
                .enumerate()
                .filter(|(_, header)| header.end > after)
                .map(|(place, header)| (header, index, place)),
        );
    }
    headers.sort_by_key(|(header, index, place)| (header.start, *index, *place));
    // Per file: the open handle, and the first frame that failed to decode
    // (that frame and the ones after it in the file are not read).
    let mut open: Vec<Option<fs::File>> = files.iter().map(|_| None).collect();
    let mut broken: Vec<Option<usize>> = vec![None; files.len()];
    let mut window: Option<OutputWindow> = None;
    // The end of the stored bytes no frame could give (a body that does not
    // decode, and the frames after it in its file).
    let mut lost = 0_u64;
    for (header, index, place) in headers {
        if broken.get(index).copied().flatten().is_some_and(|at| place >= at) {
            lost = lost.max(header.end);
            continue;
        }
        if let Some(window) = window.as_mut() {
            if header.end <= window.next_offset {
                // Already in the window (an overlapping older frame).
                continue;
            }
            if header.start > window.next_offset {
                // A gap (bytes lost in a crash or pruned): no later frame
                // starts earlier, so the window ends before it, and the next
                // read starts after it.
                window.truncated = true;
                break;
            }
        }
        let Some(bytes) = files
            .get(index)
            .zip(open.get_mut(index))
            .and_then(|((_, path), handle)| read_frame(path, handle, &header))
        else {
            if let Some(at) = broken.get_mut(index) {
                *at = Some(place);
            }
            lost = lost.max(header.end);
            continue;
        };
        let start = header.start;
        let window = window.get_or_insert_with(|| OutputWindow {
            start_offset: start.max(after),
            next_offset: start.max(after),
            bytes: Vec::new(),
            truncated: false,
        });
        let room = budget.saturating_sub(window.bytes.len());
        if room == 0 {
            window.truncated = true;
            break;
        }
        // Bytes before the window's end (or the cursor) are skipped.
        let skip = usize::try_from(window.next_offset.saturating_sub(start)).unwrap_or(usize::MAX);
        let piece = bytes.get(skip..).unwrap_or_default();
        let take = piece.len().min(room);
        window.bytes.extend_from_slice(piece.get(..take).unwrap_or(piece));
        window.next_offset = start + (skip.min(bytes.len()) + take) as u64;
        if take < piece.len() {
            window.truncated = true;
            break;
        }
    }
    // Stored bytes after the window that no other file gave: the read is
    // not complete (a later read may find them once rewritten, or not).
    if let Some(window) = window.as_mut()
        && lost > window.next_offset
    {
        window.truncated = true;
    }
    window
}

/// One frame's header and where its body sits in the file.
struct FrameHeader {
    start: u64,
    /// `start` plus the raw length.
    end: u64,
    raw: u32,
    body: u64,
    compressed: u64,
}

/// The frames of a segment file read from their headers only (seeks, no
/// decompression), in file order, and the bytes of whole frames. A cut
/// frame (a crash during a write) ends the walk.
fn frame_headers(path: &Path) -> Option<(Vec<FrameHeader>, u64)> {
    use crate::terminal_host_protocol::{wire_u32, wire_u64};
    use std::io::{Seek, SeekFrom};
    let mut file = fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    let mut at = 0_u64;
    let mut frames = Vec::new();
    let mut header = [0_u8; FRAME_HEADER_BYTES];
    while len - at >= FRAME_HEADER_BYTES as u64 {
        file.seek(SeekFrom::Start(at)).ok()?;
        file.read_exact(&mut header).ok()?;
        let start = wire_u64(&header, 0)?;
        let compressed = u64::from(wire_u32(&header, 8)?);
        let raw = wire_u32(&header, 12)?;
        let body = at + FRAME_HEADER_BYTES as u64;
        let next = body + compressed;
        if next > len || raw > MAX_FRAME_RAW_BYTES {
            break;
        }
        let end = start.checked_add(u64::from(raw))?;
        frames.push(FrameHeader { start, end, raw, body, compressed });
        at = next;
    }
    Some((frames, at))
}

/// One frame's raw bytes (`None` when its body cannot be read or does not
/// decompress to its raw length). `handle` keeps the file open between
/// frames.
fn read_frame(path: &Path, handle: &mut Option<fs::File>, header: &FrameHeader) -> Option<Vec<u8>> {
    use std::io::{Seek, SeekFrom};
    if handle.is_none() {
        *handle = Some(fs::File::open(path).ok()?);
    }
    let file = handle.as_mut()?;
    file.seek(SeekFrom::Start(header.body)).ok()?;
    let mut compressed = vec![0_u8; usize::try_from(header.compressed).ok()?];
    file.read_exact(&mut compressed).ok()?;
    let mut bytes = Vec::with_capacity(header.raw as usize);
    GzDecoder::new(compressed.as_slice())
        .take(u64::from(header.raw) + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() == header.raw as usize).then_some(bytes)
}

/// The bytes of whole frames of a segment file when every whole frame
/// decodes to its raw length (a cut frame at the end is not counted), else
/// `None`: frames appended after an undecodable one would be unreadable.
fn whole_decodable_frames(path: &Path) -> Option<u64> {
    let (frames, whole) = frame_headers(path)?;
    let mut handle = None;
    frames.iter().all(|header| read_frame(path, &mut handle, header).is_some()).then_some(whole)
}

/// (bytes of whole frames, offset after the last frame) of a segment file,
/// from its frame headers.
fn frame_extent(path: &Path, file_start: u64) -> Option<(u64, u64)> {
    let (frames, whole) = frame_headers(path)?;
    Some((whole, frames.iter().map(|frame| frame.end).fold(file_start, u64::max)))
}

/// The stored stream end of every terminal and generation key (frame
/// headers only): read once at start.
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
        // The end is the largest frame end in any of the key's files (frame
        // headers only): the file that starts last need not end last.
        let mut key_ends = std::collections::HashMap::<String, u64>::new();
        for file in files.flatten().map(|file| file.path()) {
            let Some((key, start, _)) = parse_file_name(&file) else { continue };
            let end = frame_extent(&file, start).map_or(start, |(_, end)| end);
            let known = key_ends.entry(key.to_owned()).or_insert(end);
            *known = (*known).max(end);
        }
        for (key, end) in key_ends {
            ends.insert((terminal_id.clone(), key), end);
        }
    }
    ends
}

/// Every key a generation's files may be named with (current, legacy).
pub(super) fn keys_of(generation: &str) -> [String; 2] {
    [generation_key(generation), legacy_generation_key(generation)]
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

#[cfg(test)]
#[path = "segments_tests.rs"]
mod tests;
