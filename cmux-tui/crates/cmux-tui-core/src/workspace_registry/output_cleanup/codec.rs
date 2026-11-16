//! Byte-level segment work for the cleanup: inflate a sealed segment and
//! find its records without decoding their payloads, and encode the new
//! segments in the codec sealing writes (`segment_codec`).

use std::ops::Range;

use anyhow::Context as _;
use serde::Deserialize;
use sha2::{Digest, Sha256};

use super::super::segment_codec;
use super::super::session_journal::{
    MAX_JOURNAL_SEGMENT_COMPRESSED_BYTES, MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES,
};

/// The two fields the cleanup needs; serde skips the rest of the record
/// (output payloads included) without allocating them.
#[derive(Deserialize)]
struct RecordHead {
    sequence: u64,
    kind: String,
}

pub(super) struct SplitRecord {
    pub(super) sequence: u64,
    pub(super) kind: String,
    /// The record's exact JSON bytes inside the inflated segment.
    pub(super) bytes: Range<usize>,
}

/// The inflated JSON of one sealed segment, checked against its stored
/// length and SHA-256.
pub(super) fn inflate_segment(
    segment_id: &str,
    codec: &str,
    compressed: &[u8],
    uncompressed_bytes: i64,
    sha256: &[u8],
) -> anyhow::Result<Vec<u8>> {
    anyhow::ensure!(
        segment_codec::is_known(codec),
        "journal segment {segment_id} codec is invalid"
    );
    anyhow::ensure!(
        compressed.len() <= MAX_JOURNAL_SEGMENT_COMPRESSED_BYTES,
        "journal segment {segment_id} exceeds the compressed size limit"
    );
    let expected = usize::try_from(uncompressed_bytes)?;
    anyhow::ensure!(
        expected <= MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES,
        "journal segment {segment_id} exceeds the uncompressed size limit"
    );
    let json = segment_codec::decode(codec, compressed, expected)
        .with_context(|| format!("inflate journal segment {segment_id}"))?;
    anyhow::ensure!(json.len() == expected, "journal segment {segment_id} length is invalid");
    anyhow::ensure!(
        Sha256::digest(&json).as_slice() == sha256,
        "journal segment {segment_id} digest is invalid"
    );
    Ok(json)
}

/// The records of a segment's JSON array, in order, with their byte ranges.
pub(super) fn split_records(json: &[u8]) -> anyhow::Result<Vec<SplitRecord>> {
    let mut records = Vec::new();
    let mut position = skip_whitespace(json, 0);
    anyhow::ensure!(json.get(position) == Some(&b'['), "journal segment is not a JSON array");
    position = skip_whitespace(json, position + 1);
    if json.get(position) == Some(&b']') {
        position += 1;
    } else {
        loop {
            let rest =
                json.get(position..).context("journal segment ended inside its record array")?;
            let mut stream = serde_json::Deserializer::from_slice(rest).into_iter::<RecordHead>();
            let head = stream
                .next()
                .context("journal segment ended inside its record array")?
                .context("journal segment record is invalid")?;
            let end = position + stream.byte_offset();
            records.push(SplitRecord {
                sequence: head.sequence,
                kind: head.kind,
                bytes: position..end,
            });
            position = skip_whitespace(json, end);
            match json.get(position) {
                Some(b',') => position = skip_whitespace(json, position + 1),
                Some(b']') => {
                    position += 1;
                    break;
                }
                _ => anyhow::bail!("journal segment record array is malformed"),
            }
        }
    }
    anyhow::ensure!(
        skip_whitespace(json, position) == json.len(),
        "journal segment contains trailing data"
    );
    Ok(records)
}

fn skip_whitespace(json: &[u8], mut position: usize) -> usize {
    while json.get(position).is_some_and(|byte| matches!(byte, b' ' | b'\n' | b'\r' | b'\t')) {
        position += 1;
    }
    position
}

/// One new segment's stored columns.
pub(super) struct EncodedSegment {
    pub(super) compressed: Vec<u8>,
    pub(super) uncompressed_bytes: usize,
    pub(super) digest: [u8; 32],
}

/// Appends records into one `[r1,r2,...]` array, as sealing does.
pub(super) struct SegmentWriter {
    json: Vec<u8>,
    records: usize,
}

impl SegmentWriter {
    pub(super) fn new() -> Self {
        Self { json: vec![b'['], records: 0 }
    }

    pub(super) fn records(&self) -> usize {
        self.records
    }

    /// Whether `record` still fits under the uncompressed segment limit.
    pub(super) fn fits(&self, record: &[u8]) -> bool {
        self.json.len().saturating_add(usize::from(self.records != 0)).saturating_add(record.len())
            < MAX_JOURNAL_SEGMENT_UNCOMPRESSED_BYTES
    }

    pub(super) fn push(&mut self, record: &[u8]) {
        if self.records != 0 {
            self.json.push(b',');
        }
        self.json.extend_from_slice(record);
        self.records += 1;
    }

    pub(super) fn finish(mut self) -> anyhow::Result<EncodedSegment> {
        self.json.push(b']');
        let digest: [u8; 32] = Sha256::digest(&self.json).into();
        Ok(EncodedSegment {
            compressed: segment_codec::encode(&self.json)?,
            uncompressed_bytes: self.json.len(),
            digest,
        })
    }
}

pub(super) fn encode_hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut text = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(text, "{byte:02x}");
    }
    text
}
