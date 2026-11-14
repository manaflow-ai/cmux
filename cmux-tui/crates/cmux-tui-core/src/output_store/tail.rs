//! Snapshot mode's tail journal: the output a terminal printed after its
//! last snapshot, so a kill of the daemon and every terminal host (REOPEN-F3)
//! loses only the last [`super::TAIL_FLUSH_INTERVAL`] of output, whether or
//! not the output stopped (and bytes that changed no stored content; see
//! `output_store.rs`).
//!
//! File: `<terminal id>.tail` = `CMUXTAIL1\n` + one JSON line (`generation`,
//! `start`: the stream offset of the snapshot it continues) + frames in the
//! segment format (`start offset (u64 LE) | compressed length (u32 LE) | raw
//! length (u32 LE) | gzip`). The writer appends one frame per changed
//! terminal per pass (write(2) only; the tails written since their last
//! sync are synced together every [`super::TAIL_SYNC_INTERVAL`], and each
//! at quit). A snapshot is the compaction: it records
//! its stream offset, and the tail file goes once the snapshot is in place.
//! A frame cut by a crash ends the read.
//!
//! Restore: the snapshot's replay, then the tail's bytes from exactly the
//! snapshot's offset (a gap or another generation: the snapshot alone),
//! written into a scratch terminal of the snapshot's size, replayed bounded.

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;

use crate::resource::TerminalPublicId;
use crate::workspace_registry::terminal_respawn_store::TerminalReplay;

const MAGIC: &[u8] = b"CMUXTAIL1\n";
pub(super) const SUFFIX: &str = "tail";
const FRAME_HEADER_BYTES: usize = 16;
/// A tail file larger than this is not read back (corrupt or foreign).
const MAX_TAIL_FILE_BYTES: u64 = 64 * 1024 * 1024;
/// The largest raw frame a reader accepts.
const MAX_FRAME_RAW_BYTES: u32 = 64 * 1024 * 1024;
/// `CAN` (aborts a control string) and a final Kitty chunk (ends a chunked
/// upload): what a restore writes when its screen ends inside an upload.
const UNFINISHED_UPLOAD_END: &[u8] = b"\x18\x1b_Gm=0;\x1b\\";
/// Scrollback of the scratch terminal a restore rebuilds in.
const REBUILD_SCROLLBACK_BYTES: usize = 10_000_000;

pub(super) fn path(directory: &Path, terminal_id: &TerminalPublicId) -> PathBuf {
    directory.join(format!("{}.{SUFFIX}", terminal_id.as_str()))
}

/// Remove terminal `terminal_id`'s tail (a snapshot covers it, the terminal
/// is incognito, or its history was cleared).
pub(super) fn remove(directory: &Path, terminal_id: &TerminalPublicId) {
    let _ = fs::remove_file(path(directory, terminal_id));
}

/// Append `bytes` (stream offsets `start..`) to the tail that continues the
/// snapshot at `base` of `generation`; the file is created with its header
/// when absent. `sync`: fsync the file after the write (the quit pass).
pub(super) fn append(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    base: u64,
    start: u64,
    bytes: &[u8],
    sync: bool,
) -> anyhow::Result<()> {
    fs::create_dir_all(directory)?;
    let target = path(directory, terminal_id);
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    encoder.write_all(bytes)?;
    let compressed = encoder.finish()?;
    let mut frame = Vec::with_capacity(FRAME_HEADER_BYTES + compressed.len());
    frame.extend_from_slice(&start.to_le_bytes());
    frame.extend_from_slice(&u32::try_from(compressed.len())?.to_le_bytes());
    frame.extend_from_slice(&u32::try_from(bytes.len())?.to_le_bytes());
    frame.extend_from_slice(&compressed);
    let mut file = fs::OpenOptions::new().create(true).append(true).open(&target)?;
    if file.metadata()?.len() == 0 {
        let header = serde_json::json!({"generation": generation, "start": base});
        let mut head = MAGIC.to_vec();
        serde_json::to_writer(&mut head, &header)?;
        head.push(b'\n');
        file.write_all(&head)?;
    }
    file.write_all(&frame)?;
    if sync {
        file.sync_data()?;
    }
    Ok(())
}

/// Fsync a tail written without one (the quit pass; F_FULLFSYNC on macOS).
pub(super) fn sync(directory: &Path, terminal_id: &TerminalPublicId) {
    if let Ok(file) = fs::File::open(path(directory, terminal_id)) {
        let _ = file.sync_data();
    }
}

/// The sync of a tail written without one while the daemon runs, every
/// [`super::TAIL_SYNC_INTERVAL`]; whether a file was synced. On macOS it is
/// F_BARRIERFSYNC, not the F_FULLFSYNC of [`sync`]: the file's bytes go to
/// the drive, in order before later writes, and the drive's cache is not
/// flushed (0.5 ms against 3.9 ms on a Mac mini,
/// `terminal_host_runtime/sys/unix/barrier_sync.rs`). A power loss can so
/// take back output the drive still held in its cache; terminal output is
/// not structure, and the registry's WAL runs the same way
/// (`workspace_registry/wal_durability.rs`). It falls back to the full sync
/// where the file system refuses the barrier; fdatasync elsewhere.
pub(super) fn sync_ordered(directory: &Path, terminal_id: &TerminalPublicId) -> bool {
    let Ok(file) = fs::File::open(path(directory, terminal_id)) else { return false };
    #[cfg(target_os = "macos")]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: fcntl on a descriptor this File owns, with no pointer
        // argument.
        if unsafe { libc::fcntl(file.as_raw_fd(), libc::F_BARRIERFSYNC) } != -1 {
            return true;
        }
    }
    file.sync_data().is_ok()
}

/// One tail frame: its stream offset and raw bytes.
type Frame = (u64, Vec<u8>);

/// (generation, snapshot offset it continues, frames) of a tail file.
fn read_file(file: &Path) -> Option<(String, u64, Vec<Frame>)> {
    if fs::metadata(file).ok()?.len() > MAX_TAIL_FILE_BYTES {
        return None;
    }
    let contents = fs::read(file).ok()?;
    let rest = contents.strip_prefix(MAGIC)?;
    let newline = rest.iter().position(|byte| *byte == b'\n')?;
    let header: serde_json::Value = serde_json::from_slice(rest.get(..newline)?).ok()?;
    let generation = header.get("generation")?.as_str()?.to_owned();
    let base = header.get("start")?.as_u64()?;
    let body = rest.get(newline + 1..)?;
    use crate::terminal_host_protocol::{wire_u32, wire_u64};
    let mut frames = Vec::new();
    let mut at = 0_usize;
    while body.len().saturating_sub(at) >= FRAME_HEADER_BYTES {
        let (Some(start), Some(compressed), Some(raw)) =
            (wire_u64(body, at), wire_u32(body, at + 8), wire_u32(body, at + 12))
        else {
            break;
        };
        let begin = at + FRAME_HEADER_BYTES;
        let Some(end) = begin.checked_add(compressed as usize).filter(|end| *end <= body.len())
        else {
            break;
        };
        if raw > MAX_FRAME_RAW_BYTES {
            break;
        }
        let mut bytes = Vec::with_capacity(raw as usize);
        let Some(frame) = body.get(begin..end) else { break };
        if GzDecoder::new(frame).take(u64::from(raw) + 1).read_to_end(&mut bytes).is_err()
            || bytes.len() != raw as usize
        {
            break;
        }
        frames.push((start, bytes));
        at = end;
    }
    Some((generation, base, frames))
}

/// The tail's bytes of `generation` from exactly stream offset `from`, in
/// order, up to the first gap. Empty when there is no such tail.
pub(super) fn bytes_after(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    from: u64,
) -> Vec<u8> {
    let Some((tail_generation, _, frames)) = read_file(&path(directory, terminal_id)) else {
        return Vec::new();
    };
    if tail_generation != generation {
        return Vec::new();
    }
    let mut cursor = from;
    let mut out = Vec::new();
    for (start, bytes) in frames {
        let end = start.saturating_add(bytes.len() as u64);
        if end <= cursor {
            continue;
        }
        if start > cursor {
            // A gap: nothing after it continues the restored stream.
            break;
        }
        let skip = usize::try_from(cursor - start).unwrap_or(usize::MAX);
        out.extend_from_slice(bytes.get(skip..).unwrap_or_default());
        cursor = end;
    }
    out
}

/// The stream end each tail recorded, by terminal: (generation, end), from
/// the frame headers (no decompression; read once at start).
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
            let (generation, base, end) = header_extent(&path)?;
            Some((terminal_id, (generation, base.max(end))))
        })
        .collect()
}

/// (generation, snapshot offset, largest frame end) of a tail file from its
/// header and frame headers. A cut frame ends the walk.
fn header_extent(file: &Path) -> Option<(String, u64, u64)> {
    if fs::metadata(file).ok()?.len() > MAX_TAIL_FILE_BYTES {
        return None;
    }
    let contents = fs::read(file).ok()?;
    let rest = contents.strip_prefix(MAGIC)?;
    let newline = rest.iter().position(|byte| *byte == b'\n')?;
    let header: serde_json::Value = serde_json::from_slice(rest.get(..newline)?).ok()?;
    let generation = header.get("generation")?.as_str()?.to_owned();
    let base = header.get("start")?.as_u64()?;
    let body = rest.get(newline + 1..)?;
    use crate::terminal_host_protocol::{wire_u32, wire_u64};
    let mut at = 0_usize;
    let mut end = base;
    while body.len().saturating_sub(at) >= FRAME_HEADER_BYTES {
        let (Some(start), Some(compressed), Some(raw)) =
            (wire_u64(body, at), wire_u32(body, at + 8), wire_u32(body, at + 12))
        else {
            break;
        };
        let Some(next) = (at + FRAME_HEADER_BYTES)
            .checked_add(compressed as usize)
            .filter(|next| *next <= body.len())
        else {
            break;
        };
        if raw > MAX_FRAME_RAW_BYTES {
            break;
        }
        end = end.max(start.saturating_add(u64::from(raw)));
        at = next;
    }
    Some((generation, base, end))
}

/// The snapshot `snapshot` with `tail`, the tail bytes after its end
/// ([`bytes_after`]): the screen the terminal had at the end of its tail, as
/// a bounded replay that fits a respawn seed. The snapshot alone when no tail
/// continues it.
pub(super) fn restore(snapshot: TerminalReplay, tail: &[u8]) -> TerminalReplay {
    if tail.is_empty() {
        return snapshot;
    }
    rebuild(&snapshot, tail).unwrap_or(snapshot)
}

fn rebuild(snapshot: &TerminalReplay, tail: &[u8]) -> Option<TerminalReplay> {
    let (cols, rows) = (snapshot.cols.max(1), snapshot.rows.max(1));
    let mut terminal = ghostty_vt::Terminal::new(
        cols,
        rows,
        REBUILD_SCROLLBACK_BYTES,
        ghostty_vt::Callbacks::default(),
    )
    .ok()?;
    terminal.vt_write(&snapshot.bytes);
    terminal.vt_write(tail);
    // Room for the respawn's marker line and mode reset.
    let budget = crate::surface::VT_REPLAY_MAX_BYTES.saturating_sub(64 * 1024);
    let replay = match terminal.vt_replay_bounded(budget) {
        Ok(replay) => replay,
        Err(_) => {
            // The tail ends inside an upload too large to replay (the lost
            // program never ended it): abort the control string and end the
            // upload; the screen's text stays, the half-sent image goes.
            terminal.vt_write(UNFINISHED_UPLOAD_END);
            terminal.vt_replay_bounded(budget).ok()?
        }
    };
    let bytes = replay.into_self_contained_bytes();
    Some(TerminalReplay { cols, rows, bytes })
}

#[cfg(test)]
mod tests;
