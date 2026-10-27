//! A sealed session journal segment (`decode_journal_segment`,
//! workspace_registry/session_journal.rs): the archive every journal read
//! older than the live rows goes through, and the salvage path after
//! corruption. A bad segment must give an error, never a panic.
//!
//! Two shapes, built with `arbitrary`: a raw row (any compressed bytes,
//! digest, lengths and codec: the gzip, trailer and size checks), and a
//! sealed row whose gzip, digest and length are right around a body of free
//! text or of record objects with a field dropped or added (the record
//! decoding and validation behind them). An accepted segment
//! holds exactly its record count, in contiguous sequence order from its
//! start to its end.

#![no_main]

#[path = "support/journal.rs"]
mod journal;

use arbitrary::Arbitrary;
use base64::Engine;
use cmux_tui_core::fuzz_entry::{JournalSegmentRow, journal_segment};
use libfuzzer_sys::fuzz_target;
use sha2::{Digest, Sha256};

#[derive(Arbitrary, Debug)]
struct RecordObject {
    sequence: u64,
    terminal_output: Option<Vec<u8>>,
    drop_field: Option<u8>,
    extra_field: Option<(String, String)>,
}

impl RecordObject {
    fn json(self) -> serde_json::Value {
        let mut record = serde_json::json!({
            "sequence": self.sequence,
            "event_id": format!("event_{}", self.sequence),
            "schema_version": 1,
            "kind": "workspace.created",
            "class": "state",
            "replay": "required",
            "occurred_at_ms": 1,
            "committed_at_ms": 2,
            "producer": {"kind": "daemon", "id": "d1"},
            "authority": null,
            "causation_id": null,
            "correlation_id": null,
            "causation_depth": 0,
            "subjects": [{"kind": "workspace", "id": "w1"}],
            "sensitivity": "public",
            "payload": {},
            "resource_revision": null,
            "previous_resource_revision": null,
        });
        if let Some(bytes) = self.terminal_output {
            record["kind"] = "terminal.output".into();
            record["payload"] = serde_json::json!({
                "format": "cmux.terminal-output.v1",
                "encoding": "base64",
                "data": base64::engine::general_purpose::STANDARD.encode(&bytes),
                "byte_count": bytes.len().to_string(),
                "stream_offset_start": "0",
                "stream_offset_end": bytes.len().to_string(),
                "sha256": journal::hex(&Sha256::digest(&bytes)),
            });
        }
        if let Some(object) = record.as_object_mut() {
            if let Some(index) = self.drop_field {
                let key = object.keys().nth(usize::from(index) % object.len().max(1)).cloned();
                if let Some(key) = key {
                    object.remove(&key);
                }
            }
            if let Some((key, value)) = self.extra_field {
                object.insert(key, value.into());
            }
        }
        record
    }
}

#[derive(Arbitrary, Debug)]
enum Body {
    Text(String),
    Records(Vec<RecordObject>),
}

impl Body {
    /// The body and, for records, the (start, end, count) they span.
    fn bytes(self) -> (Vec<u8>, Option<(i64, i64, i64)>) {
        match self {
            Self::Text(text) => (text.into_bytes(), None),
            Self::Records(records) => {
                let sequence = |record: Option<&RecordObject>| {
                    record.and_then(|record| i64::try_from(record.sequence).ok())
                };
                let span = sequence(records.first())
                    .zip(sequence(records.last()))
                    .zip(i64::try_from(records.len()).ok())
                    .map(|((start, end), count)| (start, end, count));
                let body =
                    serde_json::Value::Array(records.into_iter().map(RecordObject::json).collect());
                (body.to_string().into_bytes(), span)
            }
        }
    }
}

#[derive(Arbitrary, Debug)]
enum Segment {
    Raw {
        segment_id: String,
        start_sequence: i64,
        end_sequence: i64,
        record_count: i64,
        known_codec: bool,
        codec: String,
        compressed: Vec<u8>,
        uncompressed_bytes: i64,
        sha256: Vec<u8>,
    },
    Sealed {
        body: Body,
        /// Take the range and count from the records rather than the fields.
        range_from_body: bool,
        start_sequence: i64,
        end_sequence: i64,
        record_count: i64,
        trailing_gzip: Vec<u8>,
    },
}

fuzz_target!(|segment: Segment| {
    let row = match segment {
        Segment::Raw {
            segment_id,
            start_sequence,
            end_sequence,
            record_count,
            known_codec,
            codec,
            compressed,
            uncompressed_bytes,
            sha256,
        } => JournalSegmentRow {
            segment_id,
            start_sequence,
            end_sequence,
            record_count,
            codec: if known_codec { journal::CODEC.to_owned() } else { codec },
            compressed,
            uncompressed_bytes,
            sha256,
        },
        Segment::Sealed {
            body,
            range_from_body,
            start_sequence,
            end_sequence,
            record_count,
            trailing_gzip,
        } => {
            let (body, span) = body.bytes();
            let (start, end, count) = span.filter(|_| range_from_body).unwrap_or((
                start_sequence,
                end_sequence,
                record_count,
            ));
            let Ok(row) = journal::row_of(&body, start, end, count, &trailing_gzip) else {
                return;
            };
            row
        }
    };
    let (start, end, count) = (row.start_sequence, row.end_sequence, row.record_count);
    let Ok(records) = journal_segment(row) else {
        return;
    };
    assert!(i64::try_from(records.len()).ok() == Some(count), "record count is not the row's");
    let sequences: Vec<u64> = records.iter().map(|record| record.sequence).collect();
    assert!(
        sequences.first().and_then(|first| i64::try_from(*first).ok()) == Some(start)
            && sequences.last().and_then(|last| i64::try_from(*last).ok()) == Some(end),
        "records do not span the row's sequence range"
    );
    assert!(
        sequences.windows(2).all(|pair| pair[0].checked_add(1) == Some(pair[1])),
        "records are not contiguous"
    );
});
