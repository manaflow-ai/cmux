//! A sealed journal segment row built the way the sealer writes one
//! (workspace_registry/journal_extensions.rs, `prepare`): a JSON array of the
//! archived records, its SHA-256, gzip with mtime 0, the codec name.

// Each journal target uses part of this.
#![allow(dead_code)]

use std::io::Write;

use cmux_tui_core::SessionJournalRecord;
use cmux_tui_core::fuzz_entry::JournalSegmentRow;
use sha2::{Digest, Sha256};

pub const CODEC: &str = "gzip-json-v1";

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The segment row of `uncompressed` (a JSON array) with a right digest,
/// length and gzip stream; `trailing_gzip` follows the gzip member.
pub fn row_of(
    uncompressed: &[u8],
    start_sequence: i64,
    end_sequence: i64,
    record_count: i64,
    trailing_gzip: &[u8],
) -> std::io::Result<JournalSegmentRow> {
    let mut encoder =
        flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    encoder.write_all(uncompressed)?;
    let mut compressed = encoder.finish()?;
    compressed.extend_from_slice(trailing_gzip);
    let digest = Sha256::digest(uncompressed);
    Ok(JournalSegmentRow {
        segment_id: format!("segment_{start_sequence}_{end_sequence}_{}", hex(&digest)),
        start_sequence,
        end_sequence,
        record_count,
        codec: CODEC.to_owned(),
        compressed,
        uncompressed_bytes: i64::try_from(uncompressed.len()).unwrap_or(i64::MAX),
        sha256: digest.to_vec(),
    })
}

/// The segment the sealer writes for `archived` (records already in their
/// archive form, in sequence order).
pub fn seal(archived: &[SessionJournalRecord]) -> anyhow::Result<JournalSegmentRow> {
    let mut uncompressed = vec![b'['];
    for (index, record) in archived.iter().enumerate() {
        if index != 0 {
            uncompressed.push(b',');
        }
        uncompressed.extend_from_slice(&serde_json::to_vec(record)?);
    }
    uncompressed.push(b']');
    let sequence = |record: Option<&SessionJournalRecord>| {
        record.map_or(Ok(0), |record| i64::try_from(record.sequence))
    };
    Ok(row_of(
        &uncompressed,
        sequence(archived.first())?,
        sequence(archived.last())?,
        i64::try_from(archived.len())?,
        &[],
    )?)
}
