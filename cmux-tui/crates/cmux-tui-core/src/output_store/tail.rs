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
//! terminal per pass (write(2) only; an fsync at most every
//! [`super::TAIL_SYNC_INTERVAL`]). A snapshot is the compaction: it records
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
/// when absent. `sync`: fsync the file after the write.
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

/// Fsync a tail written without one.
pub(super) fn sync(directory: &Path, terminal_id: &TerminalPublicId) {
    if let Ok(file) = fs::File::open(path(directory, terminal_id)) {
        let _ = file.sync_data();
    }
}

/// (generation, snapshot offset it continues, frames) of a tail file.
fn read_file(file: &Path) -> Option<(String, u64, Vec<(u64, Vec<u8>)>)> {
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

/// The snapshot `snapshot` (stream offset `snapshot_end`) with the tail
/// bytes after it: the screen the terminal had at the end of its tail, as a
/// bounded replay that fits a respawn seed. The snapshot alone when no tail
/// continues it.
pub(super) fn restore(
    directory: &Path,
    terminal_id: &TerminalPublicId,
    generation: &str,
    snapshot_end: Option<u64>,
    snapshot: TerminalReplay,
) -> TerminalReplay {
    let Some(snapshot_end) = snapshot_end else { return snapshot };
    let tail = bytes_after(directory, terminal_id, generation, snapshot_end);
    if tail.is_empty() {
        return snapshot;
    }
    rebuild(&snapshot, &tail).unwrap_or(snapshot)
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
mod tests {
    use super::*;

    fn directory(name: &str) -> PathBuf {
        let stamp =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
        let directory = std::env::temp_dir()
            .join(format!("cmux-output-tail-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        directory
    }

    fn id() -> TerminalPublicId {
        TerminalPublicId::parse("term_0123456789abcdef0123456789abcdef").unwrap()
    }

    #[test]
    fn tail_bytes_continue_the_snapshot_offset_and_stop_at_a_gap_or_cut_frame() {
        let directory = directory("gap");
        let id = id();
        append(&directory, &id, "g1", 100, 100, b"abc", false).unwrap();
        append(&directory, &id, "g1", 100, 103, b"def", true).unwrap();
        // A gap: offset 109 does not follow 106.
        append(&directory, &id, "g1", 100, 109, b"zzz", false).unwrap();
        assert_eq!(bytes_after(&directory, &id, "g1", 100), b"abcdef");
        assert_eq!(bytes_after(&directory, &id, "g1", 102), b"cdef");
        assert!(bytes_after(&directory, &id, "g2", 100).is_empty(), "another generation");
        assert!(bytes_after(&directory, &id, "g1", 99).is_empty(), "a gap before the tail");
        // A cut last frame (a crash mid-write) ends the read; earlier frames stay.
        remove(&directory, &id);
        append(&directory, &id, "g1", 0, 0, b"one", false).unwrap();
        append(&directory, &id, "g1", 0, 3, b"two", false).unwrap();
        let file = path(&directory, &id);
        let len = fs::metadata(&file).unwrap().len();
        fs::OpenOptions::new().write(true).open(&file).unwrap().set_len(len - 2).unwrap();
        assert_eq!(bytes_after(&directory, &id, "g1", 0), b"one");
        assert_eq!(stream_ends(&directory).get(&id), Some(&("g1".to_string(), 3)));
        let _ = fs::remove_dir_all(&directory);
    }

    #[test]
    fn restore_writes_the_tail_over_the_snapshot_screen() {
        let directory = directory("restore");
        let id = id();
        let mut source = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
        source.vt_write(b"first\r\nsecond\r\n");
        let snapshot = TerminalReplay {
            cols: 40,
            rows: 5,
            bytes: source.vt_replay_bounded(1 << 20).unwrap().into_self_contained_bytes(),
        };
        let tail = b"third\r\nfourth\r\nfifth\r\nsixth\r\n";
        append(&directory, &id, "g", 15, 15, tail, false).unwrap();
        source.vt_write(tail);
        let restored = restore(&directory, &id, "g", Some(15), snapshot);
        let mut rebuilt = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
        rebuilt.vt_write(&restored.bytes);
        assert_eq!(rebuilt.plain_text().unwrap(), source.plain_text().unwrap());
        let _ = fs::remove_dir_all(&directory);
    }

    /// Failure-mode table, "unreplayable screen": a tail that ends inside a
    /// Kitty upload too large to replay still restores the text before it.
    #[test]
    fn a_tail_that_ends_inside_an_oversized_upload_still_restores_its_text() {
        let directory = directory("upload");
        let id = id();
        let mut source = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
        source.vt_write(b"first\r\n");
        let snapshot = TerminalReplay {
            cols: 40,
            rows: 5,
            bytes: source.vt_replay_bounded(1 << 20).unwrap().into_self_contained_bytes(),
        };
        let mut tail = b"after-snapshot\r\n".to_vec();
        // Chunks of a multipart upload past what a replay can hold, never ended.
        let chunk = vec![b'A'; 1 << 20];
        for _ in 0..16 {
            tail.extend_from_slice(b"\x1b_Ga=t,f=100,m=1;");
            tail.extend_from_slice(&chunk);
            tail.extend_from_slice(b"\x1b\\");
        }
        append(&directory, &id, "g", 7, 7, &tail, false).unwrap();
        let restored = restore(&directory, &id, "g", Some(7), snapshot);
        let mut rebuilt = ghostty_vt::Terminal::new(40, 5, 1_000_000, Default::default()).unwrap();
        rebuilt.vt_write(&restored.bytes);
        let text = rebuilt.plain_text().unwrap();
        let _ = fs::remove_dir_all(&directory);
        assert!(text.contains("after-snapshot"), "the tail's text was dropped: {text:?}");
    }
}
