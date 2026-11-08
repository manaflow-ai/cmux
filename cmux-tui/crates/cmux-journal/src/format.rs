//! The on-disk format: a segment header, then records back to back. All integers are little
//! endian.
//!
//! Segment header (`SEGMENT_HEADER_LEN` bytes):
//!
//! | bytes | field |
//! | --- | --- |
//! | 0..8 | magic `CMXJRNL\0` |
//! | 8..12 | format version (1) |
//! | 12..16 | header length (56) |
//! | 16..24 | journal id: random, the same in every segment of one journal |
//! | 24..32 | segment number: +1 for each new segment, also in the file name |
//! | 32..40 | first LSN: the LSN of this segment's first record |
//! | 40..48 | previous last LSN: the journal's last LSN before this segment. Recovery reads the earlier segments only through it, so bytes an earlier segment holds after it are not part of the journal (the writer starts a new segment after a failed sync, and recovery at every open) |
//! | 48..52 | reserved, 0 |
//! | 52..56 | CRC-32 of bytes 0..52 |
//!
//! Record (`RECORD_HEADER_LEN` bytes, then the payload):
//!
//! | bytes | field |
//! | --- | --- |
//! | 0..4 | CRC-32 of bytes 4..20 and the payload |
//! | 4..8 | payload length |
//! | 8..16 | LSN |
//! | 16..18 | kind (the daemon's) |
//! | 18 | class: 1 ack, 2 stream |
//! | 19 | flags: 0 for a record, 1 for a sync marker |
//!
//! A sync marker (flags 1, kind 0, class 0, no payload) says that every record of its segment
//! before it is synced; its LSN field is the LSN of the last of them, and it takes no LSN of its
//! own. The writer writes one after each successful sync, before anything else it writes there.
//! Recovery re-writes a segment's records after its last marker (`recovery.rs`, step 4).
//!
//! A run of zero bytes never reads as an entry: the CRC of a zero header is not zero.

use crate::{Class, Lsn};

pub(crate) const MAGIC: [u8; 8] = *b"CMXJRNL\0";
pub(crate) const FORMAT_VERSION: u32 = 1;
pub(crate) const SEGMENT_HEADER_LEN: usize = 56;
/// The fixed part of a record, before its payload.
pub const RECORD_HEADER_LEN: usize = 20;
/// The largest payload one record may carry. A length field above it is damage.
pub const MAX_PAYLOAD_LEN: usize = 64 * 1024 * 1024;
/// The `flags` of a sync marker.
pub(crate) const MARKER: u8 = 1;

/// One segment's header, as written and as read back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SegmentHeader {
    pub(crate) journal_id: u64,
    pub(crate) seq: u64,
    pub(crate) first_lsn: Lsn,
    pub(crate) prev_last: Lsn,
}

impl SegmentHeader {
    pub(crate) fn encode(&self) -> [u8; SEGMENT_HEADER_LEN] {
        let mut out = [0u8; SEGMENT_HEADER_LEN];
        let mut at = Cursor::new(&mut out);
        at.put(&MAGIC);
        at.put(&FORMAT_VERSION.to_le_bytes());
        at.put(&u32_len(SEGMENT_HEADER_LEN).to_le_bytes());
        at.put(&self.journal_id.to_le_bytes());
        at.put(&self.seq.to_le_bytes());
        at.put(&self.first_lsn.to_le_bytes());
        at.put(&self.prev_last.to_le_bytes());
        at.put(&0u32.to_le_bytes());
        let crc = out.get(..SEGMENT_HEADER_LEN - 4).map_or(0, crc32fast::hash);
        if let Some(tail) = out.get_mut(SEGMENT_HEADER_LEN - 4..) {
            tail.copy_from_slice(&crc.to_le_bytes());
        }
        out
    }

    /// The header in `bytes`, or why it is not one.
    pub(crate) fn decode(bytes: &[u8]) -> Result<Self, &'static str> {
        let head = bytes.get(..SEGMENT_HEADER_LEN).ok_or("short segment header")?;
        let body = head.get(..SEGMENT_HEADER_LEN - 4).ok_or("short segment header")?;
        if crc32fast::hash(body) != read_u32(head, SEGMENT_HEADER_LEN - 4) {
            return Err("segment header checksum");
        }
        if head.get(..8) != Some(MAGIC.as_slice()) {
            return Err("not a journal segment");
        }
        if read_u32(head, 8) != FORMAT_VERSION {
            return Err("unknown journal format version");
        }
        if read_u32(head, 12) != u32_len(SEGMENT_HEADER_LEN) || read_u32(head, 48) != 0 {
            return Err("unknown segment header layout");
        }
        Ok(Self {
            journal_id: read_u64(head, 16),
            seq: read_u64(head, 24),
            first_lsn: read_u64(head, 32),
            prev_last: read_u64(head, 40),
        })
    }
}

/// A record header read back from a segment.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RecordHeader {
    pub(crate) crc: u32,
    pub(crate) len: usize,
    pub(crate) lsn: Lsn,
    pub(crate) kind: u16,
    pub(crate) class_code: u8,
    pub(crate) flags: u8,
}

impl RecordHeader {
    /// Decodes the fixed part. `None` when `bytes` is short.
    pub(crate) fn decode(bytes: &[u8]) -> Option<Self> {
        let head = bytes.get(..RECORD_HEADER_LEN)?;
        Some(Self {
            crc: read_u32(head, 0),
            len: usize::try_from(read_u32(head, 4)).ok()?,
            lsn: read_u64(head, 8),
            kind: u16::from_le_bytes([*head.get(16)?, *head.get(17)?]),
            class_code: *head.get(18)?,
            flags: *head.get(19)?,
        })
    }

    /// What the entry is when its header and `payload` are whole, whatever its LSN; else why not.
    pub(crate) fn check(&self, header: &[u8], payload: &[u8]) -> Result<Entry, &'static str> {
        let mut crc = crc32fast::Hasher::new();
        crc.update(header.get(4..RECORD_HEADER_LEN).ok_or("short record header")?);
        crc.update(payload);
        if crc.finalize() != self.crc {
            return Err("record checksum");
        }
        match self.flags {
            0 => Class::from_code(self.class_code).map(Entry::Record).ok_or("unknown record class"),
            MARKER if self.len == 0 && self.kind == 0 && self.class_code == 0 => Ok(Entry::Marker),
            _ => Err("unknown record flags"),
        }
    }
}

/// What one checked entry of a segment is.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Entry {
    Record(Class),
    /// A sync marker (module docs).
    Marker,
}

/// Appends a sync marker for `synced_through` (module docs) to `out`.
pub(crate) fn encode_marker(out: &mut Vec<u8>, synced_through: Lsn) {
    let mut head = [0u8; RECORD_HEADER_LEN];
    let mut at = Cursor::new(&mut head);
    at.put(&0u32.to_le_bytes());
    at.put(&0u32.to_le_bytes());
    at.put(&synced_through.to_le_bytes());
    at.put(&0u16.to_le_bytes());
    at.put(&[0, MARKER]);
    let crc = head.get(4..).map_or(0, crc32fast::hash);
    if let Some(field) = head.get_mut(..4) {
        field.copy_from_slice(&crc.to_le_bytes());
    }
    out.extend_from_slice(&head);
}

/// Appends one encoded record to `out`. `payload_crc` is the CRC-32 state of the payload alone,
/// computed by the caller off any lock ([`payload_crc`]).
pub(crate) fn encode_record(
    out: &mut Vec<u8>,
    lsn: Lsn,
    kind: u16,
    class: Class,
    payload: &[u8],
    payload_crc: &crc32fast::Hasher,
) {
    let mut head = [0u8; RECORD_HEADER_LEN];
    let mut at = Cursor::new(&mut head);
    at.put(&0u32.to_le_bytes());
    at.put(&u32_len(payload.len()).to_le_bytes());
    at.put(&lsn.to_le_bytes());
    at.put(&kind.to_le_bytes());
    at.put(&[class.code(), 0]);
    let mut crc = crc32fast::Hasher::new();
    crc.update(head.get(4..).unwrap_or_default());
    crc.combine(payload_crc);
    if let Some(field) = head.get_mut(..4) {
        field.copy_from_slice(&crc.finalize().to_le_bytes());
    }
    out.extend_from_slice(&head);
    out.extend_from_slice(payload);
}

/// The CRC-32 state of `payload`, for [`encode_record`].
pub(crate) fn payload_crc(payload: &[u8]) -> crc32fast::Hasher {
    let mut crc = crc32fast::Hasher::new();
    crc.update(payload);
    crc
}

/// The encoded size of a record with `payload_len` bytes of payload.
pub(crate) const fn record_len(payload_len: usize) -> usize {
    RECORD_HEADER_LEN.saturating_add(payload_len)
}

/// `00000000000000000042.seg` for segment 42 (every `u64` fits in 20 digits).
pub(crate) fn segment_name(seq: u64) -> String {
    format!("{seq:020}.seg")
}

/// The segment number of a file name `segment_name` made, or `None`.
pub(crate) fn parse_segment_name(name: &str) -> Option<u64> {
    let digits = name.strip_suffix(".seg")?;
    if digits.len() != 20 || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

/// A length that fits the format's 32-bit fields: payloads are capped at [`MAX_PAYLOAD_LEN`] and
/// headers are constants, so the saturation never happens.
fn u32_len(len: usize) -> u32 {
    u32::try_from(len).unwrap_or(u32::MAX)
}

fn read_u32(bytes: &[u8], at: usize) -> u32 {
    let mut word = [0u8; 4];
    if let Some(src) = bytes.get(at..at.saturating_add(4)) {
        word.copy_from_slice(src);
    }
    u32::from_le_bytes(word)
}

fn read_u64(bytes: &[u8], at: usize) -> u64 {
    let mut word = [0u8; 8];
    if let Some(src) = bytes.get(at..at.saturating_add(8)) {
        word.copy_from_slice(src);
    }
    u64::from_le_bytes(word)
}

/// Writes fields into a fixed buffer in order.
struct Cursor<'a> {
    out: &'a mut [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn new(out: &'a mut [u8]) -> Self {
        Self { out, at: 0 }
    }

    fn put(&mut self, bytes: &[u8]) {
        let end = self.at.saturating_add(bytes.len());
        if let Some(dst) = self.out.get_mut(self.at..end) {
            dst.copy_from_slice(bytes);
        }
        self.at = end;
    }
}
