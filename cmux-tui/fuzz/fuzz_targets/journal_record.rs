//! A stored session journal row (`decode_record`,
//! workspace_registry/session_journal.rs), read on every journal page, replay
//! and restore. A bad row must give an error, never a panic. A row it accepts
//! must survive archiving: sealed into a segment the way the sealer writes it
//! (journal_extensions.rs), the segment decoder returns the same record.
//!
//! The row is built with `arbitrary`: each enum-like column is a known value
//! or free text, and the payload is free text or a terminal-output payload
//! whose content, offsets, count and digest are each right or wrong.

#![no_main]

#[path = "support/journal.rs"]
mod journal;

use arbitrary::Arbitrary;
use base64::Engine;
use cmux_tui_core::fuzz_entry::{JournalRow, journal_record, journal_record_for_archive};
use libfuzzer_sys::fuzz_target;
use sha2::{Digest, Sha256};

#[derive(Arbitrary, Debug)]
enum Column {
    Known(u8),
    Text(String),
}

impl Column {
    fn pick(self, known: &[&str]) -> String {
        match self {
            Self::Known(index) => known
                .get(usize::from(index) % known.len().max(1))
                .copied()
                .unwrap_or_default()
                .to_owned(),
            Self::Text(text) => text,
        }
    }
}

#[derive(Arbitrary, Debug)]
enum Payload {
    Text(String),
    TerminalOutput {
        content: Vec<u8>,
        /// Stored on the row (encoding raw) rather than inline base64.
        stored: bool,
        start: u64,
        byte_count_delta: i8,
        span_delta: i8,
        digest_right: bool,
        extra_field: Option<(String, String)>,
    },
}

#[derive(Arbitrary, Debug)]
struct Row {
    sequence: i64,
    event_id: String,
    schema_version: i64,
    kind: Column,
    class: Column,
    replay: Column,
    occurred_at_ms: i64,
    committed_at_ms: i64,
    producer: Column,
    authority: Option<Column>,
    causation_id: Option<String>,
    correlation_id: Option<String>,
    causation_depth: i64,
    subjects: Column,
    sensitivity: Column,
    payload: Payload,
    content: Option<Vec<u8>>,
    resource_revision: Option<i64>,
    previous_resource_revision: Option<i64>,
}

fn offset(value: u64, delta: i8) -> u64 {
    value.wrapping_add_signed(i64::from(delta))
}

fn payload_columns(payload: Payload, content: Option<Vec<u8>>) -> (String, Option<Vec<u8>>) {
    let (bytes, stored, start, byte_count_delta, span_delta, digest_right, extra_field) =
        match payload {
            Payload::Text(text) => return (text, content),
            Payload::TerminalOutput {
                content,
                stored,
                start,
                byte_count_delta,
                span_delta,
                digest_right,
                extra_field,
            } => (content, stored, start, byte_count_delta, span_delta, digest_right, extra_field),
        };
    let count = u64::try_from(bytes.len()).unwrap_or(u64::MAX);
    let digest = if digest_right { Sha256::digest(&bytes) } else { Sha256::digest(b"other") };
    let mut value = serde_json::json!({
        "format": "cmux.terminal-output.v1",
        "encoding": if stored { "raw" } else { "base64" },
        "byte_count": offset(count, byte_count_delta).to_string(),
        "stream_offset_start": start.to_string(),
        "stream_offset_end": offset(start.wrapping_add(count), span_delta).to_string(),
        "sha256": journal::hex(&digest),
    });
    if !stored {
        value["data"] = base64::engine::general_purpose::STANDARD.encode(&bytes).into();
    }
    if let (Some((key, field)), Some(object)) = (extra_field, value.as_object_mut()) {
        object.insert(key, field.into());
    }
    (value.to_string(), if stored { Some(bytes) } else { content })
}

fuzz_target!(|row: Row| {
    let (payload, content) = payload_columns(row.payload, row.content);
    let row = JournalRow {
        sequence: row.sequence,
        event_id: row.event_id,
        schema_version: row.schema_version,
        kind: row.kind.pick(&["terminal.output", "workspace.created", "session.journal.migrated"]),
        class: row.class.pick(&["state", "observation", "effect", "checkpoint"]),
        replay: row.replay.pick(&["required", "advisory", "never"]),
        occurred_at_ms: row.occurred_at_ms,
        committed_at_ms: row.committed_at_ms,
        producer: row.producer.pick(&[r#"{"kind":"daemon","id":"d1"}"#, r#"{"kind":"cli"}"#]),
        authority: row.authority.map(|authority| {
            authority.pick(&[
                r#"{"principal_id":"p","lease_id":"l","generation":"g","role":"owner"}"#,
                r#"{"principal_id":"p","lease_id":"l","generation":"g","role":"r","new":1}"#,
                "null",
            ])
        }),
        causation_id: row.causation_id,
        correlation_id: row.correlation_id,
        causation_depth: row.causation_depth,
        subjects: row.subjects.pick(&[
            r#"[{"kind":"terminal","id":"t1"},{"kind":"workspace","id":"w1"}]"#,
            "[]",
            r#"[{"kind":"pane","id":"p1","extra":1}]"#,
        ]),
        sensitivity: row.sensitivity.pick(&["public", "metadata", "sensitive", "secret"]),
        payload,
        content,
        resource_revision: row.resource_revision,
        previous_resource_revision: row.previous_resource_revision,
    };
    let Ok(record) = journal_record(row) else {
        return;
    };
    let archived = journal_record_for_archive(&record);
    match journal::seal(std::slice::from_ref(&archived)) {
        Ok(segment) => match cmux_tui_core::fuzz_entry::journal_segment(segment) {
            Ok(records) => assert_eq!(records, [record], "an archived record does not round-trip"),
            Err(error) => panic!("a sealed segment of an accepted record is refused: {error:#}"),
        },
        Err(error) => panic!("an accepted record does not seal: {error:#}"),
    }
});
