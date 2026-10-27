//! Page builder and reader.
//!
//! The host holds a transcript as an ordered list of entries (one JSON line
//! each for ACP transcripts, but this codec treats entries as opaque bytes).
//! A client asks for a page with an optional cursor; the host answers with a
//! [`TranscriptPage`] and a cursor for the next page. The cursor stays valid
//! while the transcript only grows. When the host rewrites it (compaction, a
//! fork that replaces history), the host bumps `generation` and old cursors
//! fail with [`TranscriptError::StaleCursor`], so the client restarts instead
//! of silently skipping or repeating entries.
//!
//! Body layout before compression: for each entry, a 4-byte big-endian length
//! then the entry bytes. The header records the uncompressed length and its
//! SHA-256 so the reader bounds decompression and detects corruption.

use std::io::{Read, Write};

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// One entry larger than this can never be sent, whatever the page limit.
pub const MAX_ENTRY_BYTES: usize = 8 * 1024 * 1024;
/// Largest page header JSON a reader accepts.
pub const MAX_PAGE_HEADER_BYTES: usize = 16 * 1024;

/// How a page body is encoded on the wire.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum PageEncoding {
    /// No compression (already-compressed payloads, tiny pages).
    Identity,
    /// RFC 1952 gzip.
    Gzip,
}

/// What the host may put in one page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PageLimits {
    /// Most entries per page.
    pub max_entries: usize,
    /// Most uncompressed body bytes per page. A single entry larger than this
    /// (but at most `MAX_ENTRY_BYTES`) is sent alone so paging always moves.
    pub max_page_bytes: usize,
}

impl Default for PageLimits {
    fn default() -> Self {
        Self { max_entries: 500, max_page_bytes: 1024 * 1024 }
    }
}

/// The decoded form of the opaque cursor string.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct Cursor {
    t: String,
    g: u64,
    i: u64,
}

impl Cursor {
    fn encode(&self) -> String {
        // Serializing a struct of a string and two integers cannot fail.
        URL_SAFE_NO_PAD.encode(serde_json::to_vec(self).unwrap_or_default())
    }

    fn decode(text: &str) -> Result<Self, TranscriptError> {
        let bytes = URL_SAFE_NO_PAD.decode(text).map_err(|_| TranscriptError::BadCursor)?;
        serde_json::from_slice(&bytes).map_err(|_| TranscriptError::BadCursor)
    }
}

/// One page of a transcript, as sent on a transcript channel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranscriptPage {
    /// Transcript id the page belongs to.
    pub transcript: String,
    /// Transcript generation the page was cut from.
    pub generation: u64,
    /// Index of the first entry in this page.
    pub start_index: u64,
    /// Number of entries in this page.
    pub entry_count: u64,
    /// Entries the transcript held when the page was cut.
    pub total_entries: u64,
    /// Cursor for the next page. Present even at the end, so a client can
    /// poll for entries appended later.
    pub next_cursor: String,
    /// Whether this page reached the current end of the transcript.
    pub at_end: bool,
    /// Body encoding.
    pub encoding: PageEncoding,
    /// Body length before compression.
    pub uncompressed_len: u64,
    /// Lowercase hex SHA-256 of the uncompressed body.
    pub sha256: String,
    /// The encoded body. Not part of the JSON header on the wire.
    #[serde(skip)]
    pub body: Vec<u8>,
}

/// Cuts the page that starts at `cursor` (or at the first entry).
///
/// `entries` is the host's current snapshot of transcript `transcript` at
/// `generation`.
pub fn build_page<E: AsRef<[u8]>>(
    transcript: &str,
    generation: u64,
    entries: &[E],
    cursor: Option<&str>,
    limits: PageLimits,
    encoding: PageEncoding,
) -> Result<TranscriptPage, TranscriptError> {
    let start = match cursor {
        None => 0,
        Some(text) => {
            let cursor = Cursor::decode(text)?;
            if cursor.t != transcript {
                return Err(TranscriptError::BadCursor);
            }
            if cursor.g != generation {
                return Err(TranscriptError::StaleCursor { cursor: cursor.g, current: generation });
            }
            usize::try_from(cursor.i).map_err(|_| TranscriptError::BadCursor)?
        }
    };
    let Some(pending) = entries.get(start..) else {
        return Err(TranscriptError::BadCursor);
    };

    let mut raw = Vec::new();
    let mut end = start;
    for entry in pending {
        let entry = entry.as_ref();
        if entry.len() > MAX_ENTRY_BYTES {
            return Err(TranscriptError::EntryTooLarge { index: end as u64, len: entry.len() });
        }
        let taken = end - start;
        if taken >= limits.max_entries.max(1) {
            break;
        }
        if taken > 0 && raw.len() + 4 + entry.len() > limits.max_page_bytes {
            break;
        }
        raw.extend_from_slice(&(entry.len() as u32).to_be_bytes());
        raw.extend_from_slice(entry);
        end += 1;
    }

    let sha256 = hex(&Sha256::digest(&raw));
    let body = match encoding {
        PageEncoding::Identity => raw.clone(),
        PageEncoding::Gzip => {
            let mut encoder = GzEncoder::new(Vec::new(), Compression::default());
            encoder.write_all(&raw).map_err(|error| TranscriptError::Io(error.to_string()))?;
            encoder.finish().map_err(|error| TranscriptError::Io(error.to_string()))?
        }
    };
    Ok(TranscriptPage {
        transcript: transcript.to_owned(),
        generation,
        start_index: start as u64,
        entry_count: (end - start) as u64,
        total_entries: entries.len() as u64,
        next_cursor: Cursor { t: transcript.to_owned(), g: generation, i: end as u64 }.encode(),
        at_end: end == entries.len(),
        encoding,
        uncompressed_len: raw.len() as u64,
        sha256,
        body,
    })
}

/// Decodes a page body into its entries.
///
/// Refuses pages whose declared uncompressed size exceeds `max_decoded_bytes`
/// and never inflates past the declared size (gzip bomb guard).
pub fn decode_entries(
    page: &TranscriptPage,
    max_decoded_bytes: u64,
) -> Result<Vec<Vec<u8>>, TranscriptError> {
    if page.uncompressed_len > max_decoded_bytes {
        return Err(TranscriptError::TooLarge {
            declared: page.uncompressed_len,
            limit: max_decoded_bytes,
        });
    }
    let raw = match page.encoding {
        PageEncoding::Identity => page.body.clone(),
        PageEncoding::Gzip => {
            let mut raw = Vec::new();
            GzDecoder::new(page.body.as_slice())
                .take(page.uncompressed_len + 1)
                .read_to_end(&mut raw)
                .map_err(|error| TranscriptError::Io(error.to_string()))?;
            raw
        }
    };
    if raw.len() as u64 != page.uncompressed_len || hex(&Sha256::digest(&raw)) != page.sha256 {
        return Err(TranscriptError::Corrupt);
    }

    let mut entries = Vec::new();
    let mut rest = raw.as_slice();
    while !rest.is_empty() {
        let Some((prefix, tail)) = rest.split_first_chunk::<4>() else {
            return Err(TranscriptError::Corrupt);
        };
        let Some((entry, after)) = tail.split_at_checked(u32::from_be_bytes(*prefix) as usize)
        else {
            return Err(TranscriptError::Corrupt);
        };
        entries.push(entry.to_vec());
        rest = after;
    }
    if entries.len() as u64 != page.entry_count {
        return Err(TranscriptError::Corrupt);
    }
    Ok(entries)
}

impl TranscriptPage {
    /// Wire bytes: 4-byte big-endian header length, header JSON, 4-byte
    /// big-endian body length, body.
    pub fn to_wire(&self) -> Result<Vec<u8>, TranscriptError> {
        let header =
            serde_json::to_vec(self).map_err(|error| TranscriptError::Io(error.to_string()))?;
        let mut out = Vec::with_capacity(8 + header.len() + self.body.len());
        out.extend_from_slice(&(header.len() as u32).to_be_bytes());
        out.extend_from_slice(&header);
        out.extend_from_slice(&(self.body.len() as u32).to_be_bytes());
        out.extend_from_slice(&self.body);
        Ok(out)
    }

    /// Reads one page from the start of `buffer`; `Ok(None)` means more bytes
    /// are needed. Returns the page and the bytes it used.
    pub fn from_wire(
        buffer: &[u8],
        max_body_bytes: usize,
    ) -> Result<Option<(Self, usize)>, TranscriptError> {
        let Some(header_len) = read_u32(buffer, 0) else {
            return Ok(None);
        };
        if header_len > MAX_PAGE_HEADER_BYTES {
            return Err(TranscriptError::TooLarge {
                declared: header_len as u64,
                limit: MAX_PAGE_HEADER_BYTES as u64,
            });
        }
        let Some(header) = buffer.get(4..4 + header_len) else {
            return Ok(None);
        };
        let Some(body_len) = read_u32(buffer, 4 + header_len) else {
            return Ok(None);
        };
        if body_len > max_body_bytes {
            return Err(TranscriptError::TooLarge {
                declared: body_len as u64,
                limit: max_body_bytes as u64,
            });
        }
        let body_start = 8 + header_len;
        let Some(body) = buffer.get(body_start..body_start + body_len) else {
            return Ok(None);
        };
        let mut page: Self =
            serde_json::from_slice(header).map_err(|_| TranscriptError::Corrupt)?;
        page.body = body.to_vec();
        Ok(Some((page, body_start + body_len)))
    }
}

/// Why a page could not be cut or read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptError {
    /// The cursor is not one this host issued for this transcript.
    BadCursor,
    /// The transcript was rewritten since the cursor was issued; restart
    /// from the first page.
    StaleCursor { cursor: u64, current: u64 },
    /// One entry is larger than `MAX_ENTRY_BYTES`.
    EntryTooLarge { index: u64, len: usize },
    /// A declared size is over the reader's limit.
    TooLarge { declared: u64, limit: u64 },
    /// The body does not match its declared length, hash or entry count.
    Corrupt,
    /// Compression or serialization failed.
    Io(String),
}

impl std::fmt::Display for TranscriptError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadCursor => {
                formatter.write_str("transcript cursor is not valid for this transcript")
            }
            Self::StaleCursor { cursor, current } => {
                write!(
                    formatter,
                    "transcript cursor is for generation {cursor}, transcript is at {current}"
                )
            }
            Self::EntryTooLarge { index, len } => {
                write!(
                    formatter,
                    "transcript entry {index} is {len} bytes, limit {MAX_ENTRY_BYTES}"
                )
            }
            Self::TooLarge { declared, limit } => {
                write!(formatter, "declared size {declared} is over limit {limit}")
            }
            Self::Corrupt => formatter.write_str("transcript page body is corrupt"),
            Self::Io(message) => write!(formatter, "transcript page: {message}"),
        }
    }
}

impl std::error::Error for TranscriptError {}

fn read_u32(buffer: &[u8], at: usize) -> Option<usize> {
    let bytes = buffer.get(at..)?.first_chunk::<4>()?;
    Some(u32::from_be_bytes(*bytes) as usize)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entries(count: usize) -> Vec<Vec<u8>> {
        (0..count)
            .map(|index| {
                format!(
                    r#"{{"type":"agent_message_chunk","index":{index},"text":"hello hello hello"}}"#
                )
                .into_bytes()
            })
            .collect()
    }

    fn read_all(all: &[Vec<u8>], limits: PageLimits) -> (Vec<Vec<u8>>, usize) {
        let mut cursor = None;
        let mut out = Vec::new();
        let mut pages = 0;
        loop {
            let page =
                build_page("t1", 7, all, cursor.as_deref(), limits, PageEncoding::Gzip).unwrap();
            let wire = page.to_wire().unwrap();
            let (read, used) = TranscriptPage::from_wire(&wire, 1 << 24).unwrap().unwrap();
            assert_eq!(used, wire.len());
            assert_eq!(read.start_index, out.len() as u64);
            out.extend(decode_entries(&read, 1 << 24).unwrap());
            pages += 1;
            cursor = Some(read.next_cursor.clone());
            if read.at_end {
                return (out, pages);
            }
        }
    }

    #[test]
    fn paging_returns_every_entry_once_in_order() {
        let all = entries(1234);
        let (read, pages) =
            read_all(&all, PageLimits { max_entries: 100, max_page_bytes: 1 << 20 });
        assert_eq!(read, all);
        assert_eq!(pages, 13);
    }

    #[test]
    fn page_byte_limit_is_respected() {
        let all = entries(200);
        let limits = PageLimits { max_entries: 1000, max_page_bytes: 2048 };
        let page = build_page("t1", 7, &all, None, limits, PageEncoding::Identity).unwrap();
        assert!(page.uncompressed_len <= 2048);
        assert!(page.entry_count > 1);
        assert_eq!(read_all(&all, limits).0, all);
    }

    #[test]
    fn gzip_shrinks_repetitive_transcripts() {
        let all = entries(500);
        let page =
            build_page("t1", 7, &all, None, PageLimits::default(), PageEncoding::Gzip).unwrap();
        assert!(
            page.body.len() * 5 < page.uncompressed_len as usize,
            "{} vs {}",
            page.body.len(),
            page.uncompressed_len
        );
    }

    #[test]
    fn oversized_single_entry_still_makes_progress() {
        let all = vec![vec![b'x'; 10_000], b"small".to_vec()];
        let limits = PageLimits { max_entries: 10, max_page_bytes: 100 };
        let first = build_page("t1", 1, &all, None, limits, PageEncoding::Gzip).unwrap();
        assert_eq!(first.entry_count, 1);
        let second =
            build_page("t1", 1, &all, Some(&first.next_cursor), limits, PageEncoding::Gzip)
                .unwrap();
        assert_eq!(decode_entries(&second, 1 << 20).unwrap(), vec![b"small".to_vec()]);
        assert!(second.at_end);
    }

    #[test]
    fn end_cursor_picks_up_appended_entries() {
        let mut all = entries(3);
        let page =
            build_page("t1", 1, &all, None, PageLimits::default(), PageEncoding::Gzip).unwrap();
        assert!(page.at_end);
        let empty = build_page(
            "t1",
            1,
            &all,
            Some(&page.next_cursor),
            PageLimits::default(),
            PageEncoding::Gzip,
        )
        .unwrap();
        assert_eq!(empty.entry_count, 0);
        all.push(b"new".to_vec());
        let next = build_page(
            "t1",
            1,
            &all,
            Some(&page.next_cursor),
            PageLimits::default(),
            PageEncoding::Gzip,
        )
        .unwrap();
        assert_eq!(decode_entries(&next, 1 << 20).unwrap(), vec![b"new".to_vec()]);
    }

    #[test]
    fn rewritten_transcript_rejects_old_cursor() {
        let all = entries(10);
        let page = build_page(
            "t1",
            1,
            &all,
            None,
            PageLimits { max_entries: 4, max_page_bytes: 1 << 20 },
            PageEncoding::Gzip,
        )
        .unwrap();
        let error = build_page(
            "t1",
            2,
            &all,
            Some(&page.next_cursor),
            PageLimits::default(),
            PageEncoding::Gzip,
        )
        .unwrap_err();
        assert_eq!(error, TranscriptError::StaleCursor { cursor: 1, current: 2 });
        let error = build_page(
            "t2",
            1,
            &all,
            Some(&page.next_cursor),
            PageLimits::default(),
            PageEncoding::Gzip,
        )
        .unwrap_err();
        assert_eq!(error, TranscriptError::BadCursor);
        assert_eq!(
            build_page("t1", 1, &all, Some("!!"), PageLimits::default(), PageEncoding::Gzip)
                .unwrap_err(),
            TranscriptError::BadCursor
        );
    }

    #[test]
    fn tampered_body_and_bombs_are_refused() {
        let all = entries(50);
        let mut page =
            build_page("t1", 1, &all, None, PageLimits::default(), PageEncoding::Gzip).unwrap();
        assert!(matches!(decode_entries(&page, 10), Err(TranscriptError::TooLarge { .. })));

        let mut lying = page.clone();
        lying.uncompressed_len = 16;
        assert_eq!(decode_entries(&lying, 1 << 20), Err(TranscriptError::Corrupt));

        let mut wrong_hash = page.clone();
        wrong_hash.sha256 = "00".repeat(32);
        assert_eq!(decode_entries(&wrong_hash, 1 << 20), Err(TranscriptError::Corrupt));

        let last = page.body.len() - 9;
        page.body[last] ^= 0xff;
        assert!(decode_entries(&page, 1 << 20).is_err());
    }

    #[test]
    fn partial_wire_input_asks_for_more() {
        let page =
            build_page("t1", 1, &entries(5), None, PageLimits::default(), PageEncoding::Gzip)
                .unwrap();
        let wire = page.to_wire().unwrap();
        for cut in 0..wire.len() {
            assert_eq!(
                TranscriptPage::from_wire(&wire[..cut], 1 << 20).unwrap(),
                None,
                "cut at {cut}"
            );
        }
        assert!(TranscriptPage::from_wire(&wire, 4).is_err());
    }
}
