//! Sealed journal segment decode for cmux-tui/fuzz.
//! The harness makes the gzip, length, digest, count and sequence range of
//! the row match the fuzzed JSON body, so the input reaches the record parse,
//! the terminal output check and the wire projection.

use std::io::Write;

use flate2::Compression;
use flate2::write::GzEncoder;
use sha2::{Digest, Sha256};

use super::{SessionJournalRecord, decode_journal_segment};

pub(crate) fn segment(data: &[u8]) {
    let (count, start, end) = match serde_json::from_slice::<Vec<SessionJournalRecord>>(data) {
        Ok(records) => (
            records.len(),
            records.first().map_or(0, |record| record.sequence),
            records.last().map_or(0, |record| record.sequence),
        ),
        Err(_) => (1, 0, 0),
    };
    let mut encoder = GzEncoder::new(Vec::new(), Compression::fast());
    if encoder.write_all(data).is_err() {
        return;
    }
    let Ok(compressed) = encoder.finish() else { return };
    let as_i64 = |value: u64| i64::try_from(value).unwrap_or(i64::MAX);
    let row = (
        "fuzz".to_owned(),
        as_i64(start),
        as_i64(end),
        i64::try_from(count).unwrap_or(i64::MAX),
        "gzip-json-v1".to_owned(),
        compressed,
        i64::try_from(data.len()).unwrap_or(i64::MAX),
        Sha256::digest(data).to_vec(),
    );
    let Ok(decoded) = decode_journal_segment(row) else { return };
    for record in decoded.records {
        let document = crate::journal_kernel::JournalDocument::new(record);
        let _ = document.wire_value();
        let _ = document.subjects_bytes();
        let _ = document.payload_bytes();
        let _ = document.record_bytes();
        let _ = document.terminal_output_bytes();
    }
}
