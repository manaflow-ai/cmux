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
    /// `bytes` after the record header.
    payload: &'a [u8],
}

impl<'a> SnapshotRecord<'a> {
    pub fn payload(&self) -> &'a [u8] {
        self.payload
    }
}

/// Iterate the records of a snapshot (after the envelope). Stops at the first
/// incomplete record, so a READY prefix iterates through READY.
pub fn snapshot_records(snapshot: &[u8]) -> impl Iterator<Item = SnapshotRecord<'_>> {
    let valid = snapshot_envelope_version(snapshot).is_some();
    let mut at = SNAPSHOT_ENVELOPE_LEN;
    std::iter::from_fn(move || {
        if !valid {
            return None;
        }
        let (record, end) = record_at(snapshot, at)?;
        at = end;
        Some(record)
    })
}

/// The complete record that starts at `at`, and the offset just past it;
/// `None` when the header or the payload it declares is cut off.
fn record_at(bytes: &[u8], at: usize) -> Option<(SnapshotRecord<'_>, usize)> {
    let rest = bytes.get(at..)?;
    let (header, after_header) = rest.split_first_chunk::<SNAPSHOT_RECORD_HEADER_LEN>()?;
    let [tag0, tag1, len0, len1, len2, len3, ..] = *header;
    let payload_len = usize::try_from(u32::from_le_bytes([len0, len1, len2, len3])).ok()?;
    let payload = after_header.get(..payload_len)?;
    let record_len = SNAPSHOT_RECORD_HEADER_LEN.checked_add(payload_len)?;
    let record = SnapshotRecord {
        tag: u16::from_le_bytes([tag0, tag1]),
        bytes: rest.get(..record_len)?,
        payload,
    };
    Some((record, at.checked_add(record_len)?))
}

/// The format version in a snapshot envelope.
pub fn snapshot_envelope_version(snapshot: &[u8]) -> Option<u16> {
    let (envelope, _) = snapshot.split_first_chunk::<SNAPSHOT_ENVELOPE_LEN>()?;
    let [magic @ .., version0, version1] = envelope;
    (magic == SNAPSHOT_MAGIC).then(|| u16::from_le_bytes([*version0, *version1]))
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
        if record.tag == tag::SCREEN
            && let Some((head, rest)) = payload.split_first_chunk::<4>()
            && let Some((_history_extent, tail)) = rest.split_first_chunk::<8>()
        {
            out.extend_from_slice(head);
            out.extend_from_slice(&[0; 8]);
            out.extend_from_slice(tail);
        } else {
            out.extend_from_slice(payload);
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
        // SAFETY: `raw` is a writable local; a null allocator selects the default.
        if check(unsafe { sys::ghostty_terminal_new(std::ptr::null(), &mut raw, 1, 1) }).is_err() {
            return 0;
        }
        let bytes = encode_raw(raw, SnapshotPhase::Ready);
        // SAFETY: `raw` came from ghostty_terminal_new above, nothing else owns it,
        // and it is freed once.
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
            let Some((record, end)) = record_at(&self.bytes, self.scanned) else { return };
            if record.tag == tag::READY {
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
    // SAFETY: `userdata` is the SnapshotSink that `encode_raw` owns for the
    // duration of the encode, and nothing else borrows it meanwhile.
    let sink = unsafe { &mut *(userdata as *mut SnapshotSink) };
    if len > 0 {
        // SAFETY: libghostty passes `len` readable bytes at `data` for the duration
        // of the callback (GhosttyWriterFn).
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
    // SAFETY: callers pass a live terminal no one mutates during the call;
    // `writer` calls `snapshot_sink_write` with `sink`, which outlives the call.
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
    // SAFETY: `decoder` is a writable local; the decoder borrows `complete`
    // without copying, and `complete` outlives it (freed below).
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
    // SAFETY: `decoder` is live; RETAIN_CONTINUATION reads a bool from the live
    // `retain`.
    let result = check(unsafe {
        sys::ghostty_snapshot_decoder_set(
            decoder,
            sys::GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION,
            (&retain as *const bool).cast(),
        )
    })
    // SAFETY: `decoder` is live and `restored` a writable local.
    .and_then(|()| check(unsafe { sys::ghostty_snapshot_decoder_decode(decoder, &mut restored) }))
    .and_then(|()| encode_raw(restored, SnapshotPhase::Ready));
    // SAFETY: both are freed once and never used again: `decoder` came from
    // decoder_new_buf, and `restored` is null (allowed) or the decoded terminal.
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
    let (tag::HISTORY, &[_, _, count0, count1, count2, count3, ..]) =
        (history.tag, history.payload())
    else {
        return Err(Error::InvalidValue);
    };
    let page_count = u32::from_le_bytes([count0, count1, count2, count3]);
    for _ in 0..page_count {
        let Some(page) = records.next() else { return Err(Error::InvalidValue) };
        let (tag::PAGE, &[_, _, rows0, rows1, ..]) = (page.tag, page.payload()) else {
            return Err(Error::InvalidValue);
        };
        let rows = u16::from_le_bytes([rows0, rows1]);
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
    /// history row count and a digest of the 64 history rows directly above
    /// the READY seam (codepoints and wrap flags, no styles). Call it
    /// directly after [`Terminal::encode_snapshot`] with no terminal change
    /// in between. A viewer that reflowed its own copy of the history
    /// compares both after its reflow.
    ///
    /// Computed by libghostty-vt `ghostty_terminal_history_digest` (digest
    /// version [`HISTORY_DIGEST_VERSION`]). `None` when it fails; the caller
    /// then sends a READY with its full history instead.
    pub fn history_digest(&self) -> Option<HistoryDigest> {
        let mut rows = 0u64;
        let mut digest = vec![0u8; sys::GHOSTTY_TERMINAL_HISTORY_DIGEST_LEN as usize];
        // SAFETY: `self.raw()` is this Terminal's live handle; `rows` is a
        // writable local and `digest` is writable for `digest.len()` bytes, the
        // length the API requires.
        let result = unsafe {
            sys::ghostty_terminal_history_digest(
                self.raw(),
                &mut rows,
                digest.as_mut_ptr(),
                digest.len(),
            )
        };
        check(result).ok()?;
        Some(HistoryDigest { rows, digest })
    }
}

/// The history digest algorithm version of [`Terminal::history_digest`].
pub const HISTORY_DIGEST_VERSION: u32 = sys::GHOSTTY_TERMINAL_HISTORY_DIGEST_VERSION;

/// [`Terminal::history_digest`]: the history row count and the digest bytes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistoryDigest {
    pub rows: u64,
    pub digest: Vec<u8>,
}
