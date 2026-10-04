//! GHOSTSNP terminal snapshots from the libghostty-vt snapshot encoder
//! (`include/ghostty/vt/snapshot.h`).
//!
//! A snapshot is a 10-byte envelope (`"GHOSTSNP"` + `u16` version) followed
//! by CRC32C-protected records: TERMINAL, per-screen SCREEN + PAGE records,
//! CONTINUATION, READY, then per-screen HISTORY + PAGE records (newest first)
//! and FINISH. The READY prefix is enough to render and resume the terminal;
//! history follows it.
//!
//! libghostty-vt encodes the complete snapshot only. The READY phase stops the
//! encoder from its writer callback as soon as the READY record is complete,
//! so a READY snapshot costs the active screens, not the scrollback.

use std::ffi::c_void;
use std::sync::OnceLock;

use crate::terminal::Terminal;
use crate::{Error, Result, check, sys};

/// Bytes in the envelope: 8-byte magic plus the `u16` format version.
pub const SNAPSHOT_ENVELOPE_LEN: usize = 10;
/// Bytes in a record header: `u16` tag, `u32` payload length, `u32` CRC32C.
pub const SNAPSHOT_RECORD_HEADER_LEN: usize = 10;
const SNAPSHOT_MAGIC: &[u8; 8] = b"GHOSTSNP";

/// Record tags of snapshot format version 1 (`src/terminal/snapshot/record.zig`).
pub mod tag {
    pub const TERMINAL: u16 = 1;
    pub const SCREEN: u16 = 2;
    pub const PAGE: u16 = 3;
    pub const HISTORY: u16 = 4;
    pub const READY: u16 = 5;
    pub const FINISH: u16 = 6;
    pub const CONTINUATION: u16 = 7;
}

/// Which part of a snapshot to encode. Matches the surface-side phases of
/// ghostty-next (`GHOSTTY_SURFACE_SNAPSHOT_READY = 0`, `COMPLETE = 2`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SnapshotPhase {
    /// Envelope through the READY record.
    Ready,
    /// The complete snapshot through FINISH.
    Complete,
}

/// One record inside an encoded snapshot.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SnapshotRecord<'a> {
    pub tag: u16,
    /// Header and payload, exactly as encoded (CRC intact).
    pub bytes: &'a [u8],
}

impl SnapshotRecord<'_> {
    pub fn payload(&self) -> &[u8] {
        &self.bytes[SNAPSHOT_RECORD_HEADER_LEN..]
    }
}

/// Iterate the records of a snapshot (after the envelope). Stops at the first
/// incomplete record, so a READY prefix iterates through READY.
pub fn snapshot_records(snapshot: &[u8]) -> impl Iterator<Item = SnapshotRecord<'_>> {
    let mut at = if snapshot.len() >= SNAPSHOT_ENVELOPE_LEN { SNAPSHOT_ENVELOPE_LEN } else { 0 };
    let valid = snapshot.len() >= SNAPSHOT_ENVELOPE_LEN && &snapshot[..8] == SNAPSHOT_MAGIC;
    std::iter::from_fn(move || {
        if !valid {
            return None;
        }
        let end = record_end(snapshot, at)?;
        let record = SnapshotRecord {
            tag: u16::from_le_bytes([snapshot[at], snapshot[at + 1]]),
            bytes: &snapshot[at..end],
        };
        at = end;
        Some(record)
    })
}

fn record_end(bytes: &[u8], at: usize) -> Option<usize> {
    let header = bytes.get(at..at.checked_add(SNAPSHOT_RECORD_HEADER_LEN)?)?;
    let payload_len = u32::from_le_bytes([header[2], header[3], header[4], header[5]]) as usize;
    let end = at.checked_add(SNAPSHOT_RECORD_HEADER_LEN)?.checked_add(payload_len)?;
    (end <= bytes.len()).then_some(end)
}

/// The format version in a snapshot envelope.
pub fn snapshot_envelope_version(snapshot: &[u8]) -> Option<u16> {
    (snapshot.len() >= SNAPSHOT_ENVELOPE_LEN && &snapshot[..8] == SNAPSHOT_MAGIC)
        .then(|| u16::from_le_bytes([snapshot[8], snapshot[9]]))
}

/// Byte length of the READY prefix of a snapshot (envelope through READY).
pub fn snapshot_ready_len(snapshot: &[u8]) -> Option<usize> {
    let mut end = SNAPSHOT_ENVELOPE_LEN;
    for record in snapshot_records(snapshot) {
        end += record.bytes.len();
        if record.tag == tag::READY {
            return Some(end);
        }
    }
    None
}

/// The bytes the idle digest hashes: for each SCREEN, PAGE and CONTINUATION
/// record of a READY prefix, in order, its `u16` tag, `u32` payload length
/// and payload, with the SCREEN history extent (payload bytes 4..12) zeroed.
/// A viewer that restored READY (with or without history pages, with any
/// scrollback budget) reproduces these bytes when its screens match the
/// host's. The TERMINAL record is excluded: it carries per-device values
/// (scrollback limits, cell pixel size).
pub fn snapshot_digest_input(ready: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(ready.len());
    for record in snapshot_records(ready) {
        if !matches!(record.tag, tag::SCREEN | tag::PAGE | tag::CONTINUATION) {
            continue;
        }
        let payload = record.payload();
        out.extend_from_slice(&record.tag.to_le_bytes());
        out.extend_from_slice(&(payload.len() as u32).to_le_bytes());
        let start = out.len();
        out.extend_from_slice(payload);
        if record.tag == tag::SCREEN && payload.len() >= 12 {
            out[start + 4..start + 12].fill(0);
        }
    }
    out
}

/// The GHOSTSNP version this libghostty-vt writes. Read once from the
/// envelope of a 1x1 terminal's snapshot (the C API has no version getter).
pub fn snapshot_version() -> u16 {
    static VERSION: OnceLock<u16> = OnceLock::new();
    *VERSION.get_or_init(|| {
        let mut raw: sys::GhosttyTerminal = std::ptr::null_mut();
        if check(unsafe { sys::ghostty_terminal_new(std::ptr::null(), &mut raw, 1, 1) }).is_err() {
            return 0;
        }
        let bytes = encode_raw(raw, SnapshotPhase::Ready);
        unsafe { sys::ghostty_terminal_free(raw) };
        bytes.ok().and_then(|bytes| snapshot_envelope_version(&bytes)).unwrap_or(0)
    })
}

struct SnapshotSink {
    bytes: Vec<u8>,
    stop_after_ready: bool,
    scanned: usize,
    ready_end: Option<usize>,
}

impl SnapshotSink {
    fn advance(&mut self) {
        if self.scanned == 0 {
            if self.bytes.len() < SNAPSHOT_ENVELOPE_LEN {
                return;
            }
            self.scanned = SNAPSHOT_ENVELOPE_LEN;
        }
        while self.ready_end.is_none() {
            let Some(end) = record_end(&self.bytes, self.scanned) else { return };
            if u16::from_le_bytes([self.bytes[self.scanned], self.bytes[self.scanned + 1]])
                == tag::READY
            {
                self.ready_end = Some(end);
            }
            self.scanned = end;
        }
    }
}

unsafe extern "C" fn snapshot_sink_write(
    userdata: *mut c_void,
    data: *const u8,
    len: usize,
) -> bool {
    let sink = unsafe { &mut *(userdata as *mut SnapshotSink) };
    if len > 0 {
        sink.bytes.extend_from_slice(unsafe { std::slice::from_raw_parts(data, len) });
    }
    if !sink.stop_after_ready {
        return true;
    }
    sink.advance();
    // Returning false stops the encoder once READY is complete. The encoder
    // then reports GHOSTTY_IO_ERROR, which `encode_raw` treats as success.
    sink.ready_end.is_none()
}

fn encode_raw(raw: sys::GhosttyTerminal, phase: SnapshotPhase) -> Result<Vec<u8>> {
    let mut sink = SnapshotSink {
        bytes: Vec::new(),
        stop_after_ready: phase == SnapshotPhase::Ready,
        scanned: 0,
        ready_end: None,
    };
    let writer = sys::GhosttyWriter {
        write: Some(snapshot_sink_write),
        userdata: (&mut sink as *mut SnapshotSink).cast(),
    };
    let result = unsafe { sys::ghostty_snapshot_encode(raw, writer) };
    match phase {
        SnapshotPhase::Ready => {
            sink.advance();
            let Some(end) = sink.ready_end else {
                check(result)?;
                return Err(Error::InvalidValue);
            };
            sink.bytes.truncate(end);
            Ok(sink.bytes)
        }
        SnapshotPhase::Complete => {
            check(result)?;
            Ok(sink.bytes)
        }
    }
}

/// Restore a COMPLETE snapshot into a fresh terminal (the viewer side after
/// READY plus every HISTORY page) and encode that terminal's READY snapshot.
/// The result equals the source terminal's READY when the restore is
/// lossless. (A READY-only restore differs by design: its SCREEN records
/// declare the history extent the source had, while the restored terminal
/// holds no history until HISTORY pages arrive.)
pub fn reencode_ready(complete: &[u8]) -> Result<Vec<u8>> {
    let mut decoder: sys::GhosttySnapshotDecoder = std::ptr::null_mut();
    check(unsafe {
        sys::ghostty_snapshot_decoder_new_buf(
            std::ptr::null(),
            &mut decoder,
            complete.as_ptr(),
            complete.len(),
        )
    })?;
    let retain = true;
    let mut restored: sys::GhosttyTerminal = std::ptr::null_mut();
    let result = check(unsafe {
        sys::ghostty_snapshot_decoder_set(
            decoder,
            sys::GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
            (&retain as *const bool).cast(),
        )
    })
    .and_then(|()| check(unsafe { sys::ghostty_snapshot_decoder_decode(decoder, &mut restored) }))
    .and_then(|()| encode_raw(restored, SnapshotPhase::Ready));
    unsafe {
        sys::ghostty_snapshot_decoder_free(decoder);
        sys::ghostty_terminal_free(restored);
    }
    result
}

/// One HISTORY page of the primary screen with the rows it covers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SnapshotHistoryPage {
    /// The PAGE record exactly as encoded (header, payload, CRC).
    pub record: Vec<u8>,
    /// Screen row (0 = oldest retained row) of the page's first row.
    pub first_row: u64,
    pub rows: u16,
}

/// Split the primary screen's HISTORY pages out of a complete snapshot,
/// newest first, with the screen rows each page covers. History pages cover
/// exactly the rows above the first SCREEN page, so the newest one ends at
/// the sum of all history page rows.
pub fn primary_history_pages(complete: &[u8]) -> Result<Vec<SnapshotHistoryPage>> {
    let mut records = snapshot_records(complete);
    let mut saw_ready = false;
    for record in records.by_ref() {
        if record.tag == tag::READY {
            saw_ready = true;
            break;
        }
    }
    if !saw_ready {
        return Err(Error::InvalidValue);
    }
    let mut pages: Vec<(Vec<u8>, u16)> = Vec::new();
    // The primary screen's HISTORY record comes first (TERMINAL declares the
    // primary screen first); stop at the next HISTORY or FINISH.
    let Some(history) = records.next() else { return Err(Error::InvalidValue) };
    if history.tag != tag::HISTORY || history.payload().len() < 6 {
        return Err(Error::InvalidValue);
    }
    let payload = history.payload();
    let page_count = u32::from_le_bytes([payload[2], payload[3], payload[4], payload[5]]) as usize;
    for _ in 0..page_count {
        let Some(page) = records.next() else { return Err(Error::InvalidValue) };
        if page.tag != tag::PAGE || page.payload().len() < 4 {
            return Err(Error::InvalidValue);
        }
        let rows = u16::from_le_bytes([page.payload()[2], page.payload()[3]]);
        pages.push((page.bytes.to_vec(), rows));
    }
    let total: u64 = pages.iter().map(|(_, rows)| u64::from(*rows)).sum();
    let mut bottom = total;
    Ok(pages
        .into_iter()
        .map(|(record, rows)| {
            bottom -= u64::from(rows);
            SnapshotHistoryPage { record, first_row: bottom, rows }
        })
        .collect())
}

impl Terminal {
    /// Encode a GHOSTSNP snapshot of this terminal. The caller serializes it
    /// with [`Terminal::vt_write`]: the snapshot reflects every byte written
    /// so far, including an unfinished escape sequence (its continuation).
    /// Fails while the unfinished sequence is longer than
    /// [`crate::SNAPSHOT_CONTINUATION_MAX_BYTES`].
    pub fn encode_snapshot(&self, phase: SnapshotPhase) -> Result<Vec<u8>> {
        encode_raw(self.raw(), phase)
    }

    /// The divergence check of a local-history READY: the primary screen's
    /// history row count and a digest of its last 64 history rows
    /// (codepoints and wrap flags, no styles). A viewer that reflowed its
    /// own copy of the history compares both after its reflow.
    ///
    /// `None` when libghostty-vt cannot compute it; the caller then sends a
    /// READY with its full history instead.
    pub fn history_digest(&self) -> Option<HistoryDigest> {
        // TODO(S2c): call `ghostty_terminal_history_digest` (manaflow-ai/ghostty-next
        // branch `restore-local-history`) once the ghostty-next gitlink
        // includes it. Until then no local-history READY is sent.
        None
    }
}

/// [`Terminal::history_digest`]: the history row count and the digest bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryDigest {
    pub rows: u64,
    pub digest: Vec<u8>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Callbacks;

    #[test]
    fn ready_snapshot_is_a_prefix_of_the_complete_snapshot() {
        let mut term = Terminal::new(20, 3, 1 << 20, Callbacks::default()).unwrap();
        for line in 0..40 {
            term.vt_write(format!("line {line}\r\n").as_bytes());
        }
        let ready = term.encode_snapshot(SnapshotPhase::Ready).unwrap();
        let complete = term.encode_snapshot(SnapshotPhase::Complete).unwrap();
        assert_eq!(snapshot_ready_len(&complete), Some(ready.len()));
        assert_eq!(&complete[..ready.len()], &ready[..]);
        assert_eq!(snapshot_envelope_version(&ready), Some(snapshot_version()));
        assert_ne!(snapshot_version(), 0);
        let last = snapshot_records(&ready).last().unwrap();
        assert_eq!(last.tag, tag::READY);
        let finish = snapshot_records(&complete).last().unwrap();
        assert_eq!(finish.tag, tag::FINISH);
    }

    #[test]
    fn digest_input_matches_after_a_ready_only_restore() {
        let mut term = Terminal::new(20, 3, 1 << 20, Callbacks::default()).unwrap();
        for line in 0..400 {
            term.vt_write(format!("line {line}\r\n").as_bytes());
        }
        let ready = term.encode_snapshot(SnapshotPhase::Ready).unwrap();
        // The viewer restored READY only: no history pages.
        let mut decoder: sys::GhosttySnapshotDecoder = std::ptr::null_mut();
        let mut restored: sys::GhosttyTerminal = std::ptr::null_mut();
        check(unsafe {
            sys::ghostty_snapshot_decoder_new_buf(
                std::ptr::null(),
                &mut decoder,
                ready.as_ptr(),
                ready.len(),
            )
        })
        .unwrap();
        check(unsafe { sys::ghostty_snapshot_decoder_ready(decoder, &mut restored) }).unwrap();
        let viewer = encode_raw(restored, SnapshotPhase::Ready).unwrap();
        unsafe {
            sys::ghostty_snapshot_decoder_free(decoder);
            sys::ghostty_terminal_free(restored);
        }
        assert_eq!(snapshot_digest_input(&viewer), snapshot_digest_input(&ready));
    }

    #[test]
    fn snapshot_carries_an_unfinished_escape_sequence() {
        let mut term = Terminal::new(20, 3, 1 << 20, Callbacks::default()).unwrap();
        term.vt_write(b"hello\x1b]0;tit");
        assert!(!term.vt_stream_is_ground());
        let ready = term.encode_snapshot(SnapshotPhase::Ready).unwrap();
        assert!(snapshot_records(&ready).any(|record| record.tag == tag::CONTINUATION));
    }

    #[test]
    fn history_pages_cover_the_rows_above_the_screen_newest_first() {
        let mut term = Terminal::new(20, 3, 1 << 22, Callbacks::default()).unwrap();
        for line in 0..5000 {
            term.vt_write(format!("line {line}\r\n").as_bytes());
        }
        let complete = term.encode_snapshot(SnapshotPhase::Complete).unwrap();
        let pages = primary_history_pages(&complete).unwrap();
        assert!(!pages.is_empty());
        for pair in pages.windows(2) {
            assert_eq!(pair[1].first_row + u64::from(pair[1].rows), pair[0].first_row);
        }
        assert_eq!(pages.last().unwrap().first_row, 0);
    }
}
