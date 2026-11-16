//! Kept records at rest in the staging file. Up to 1024 records are one
//! compressed chunk, in the codec sealing writes; each record
//! keeps a row with its kind, actor, chunk and the few fields the index
//! rows are derived from (`index_json`), so the swap's SQL never inflates a
//! chunk. Staging format 2 stored every kept record as plain JSON, and one
//! registry's staging file reached 38.2 GB, mostly copies of the same
//! `personal.session.put` record (2026-11-09).

use std::ops::Range;

use anyhow::Context as _;
use rusqlite::{Connection, params};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::super::segment_codec;
use super::codec::{inflate_segment, split_records};

/// Records per chunk: a sealed segment's limit, so a staged segment is at
/// most one chunk.
pub(super) const CHUNK_RECORD_LIMIT: usize = 1024;

pub(super) const CHUNK_SCHEMA: &str = "CREATE TABLE output_cleanup_records (
       sequence INTEGER PRIMARY KEY CHECK(sequence > 0),
       kind TEXT NOT NULL,
       index_json TEXT NOT NULL CHECK(json_valid(index_json)),
       actor TEXT,
       chunk INTEGER NOT NULL
     );
     CREATE TABLE output_cleanup_chunks (
       chunk INTEGER PRIMARY KEY CHECK(chunk > 0),
       record_count INTEGER NOT NULL CHECK(record_count > 0),
       codec TEXT NOT NULL,
       content BLOB NOT NULL,
       uncompressed_bytes INTEGER NOT NULL,
       sha256 BLOB NOT NULL
     );";

/// The fields of a record that `copy_index_rows` reads; serde skips the
/// rest (payloads included) without allocating them.
#[derive(Deserialize)]
struct IndexFields {
    #[serde(default)]
    subjects: Value,
    #[serde(default)]
    event_id: Value,
    #[serde(default)]
    causation_depth: Value,
    #[serde(default)]
    causation_id: Value,
    #[serde(default)]
    producer: Value,
    #[serde(default)]
    resource_revision: Value,
    #[serde(default)]
    previous_resource_revision: Value,
}

/// `record`'s index fields under the same JSON paths as the record.
fn index_json(record: &[u8]) -> anyhow::Result<String> {
    let fields: IndexFields =
        serde_json::from_slice(record).context("staged journal record is invalid")?;
    Ok(json!({
        "subjects": fields.subjects,
        "event_id": fields.event_id,
        "causation_depth": fields.causation_depth,
        "causation_id": fields.causation_id,
        "producer": {"kind": fields.producer.get("kind").cloned().unwrap_or(Value::Null)},
        "resource_revision": fields.resource_revision,
        "previous_resource_revision": fields.previous_resource_revision,
    })
    .to_string())
}

/// One record to stage: sequence, kind, its archived JSON and its actor.
pub(super) type StagedRecord = (u64, String, Vec<u8>, Option<String>);

/// Stages `records` (at most [`CHUNK_RECORD_LIMIT`], in any order) as
/// one chunk through `connection`, inside the caller's transaction.
pub(super) fn insert_chunk(
    connection: &Connection,
    records: &[StagedRecord],
) -> anyhow::Result<()> {
    let Some(first) = records.first() else { return Ok(()) };
    anyhow::ensure!(records.len() <= CHUNK_RECORD_LIMIT, "a staged chunk holds too many records");
    // Sequences are unique, so the first one names the chunk.
    let chunk = i64::try_from(first.0)?;
    let mut json = Vec::with_capacity(records.iter().map(|record| record.2.len() + 1).sum());
    json.push(b'[');
    for (index, (_, _, bytes, _)) in records.iter().enumerate() {
        if index != 0 {
            json.push(b',');
        }
        json.extend_from_slice(bytes);
    }
    json.push(b']');
    let digest: [u8; 32] = Sha256::digest(&json).into();
    connection.execute(
        "INSERT INTO output_cleanup_chunks(
           chunk, record_count, codec, content, uncompressed_bytes, sha256)
         VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
        params![
            chunk,
            i64::try_from(records.len())?,
            segment_codec::SEAL_CODEC,
            segment_codec::encode(&json)?,
            i64::try_from(json.len())?,
            digest.as_slice(),
        ],
    )?;
    let mut insert = connection.prepare(
        "INSERT INTO output_cleanup_records(sequence, kind, index_json, actor, chunk)
         VALUES(?1, ?2, ?3, ?4, ?5)",
    )?;
    for (sequence, kind, bytes, actor) in records {
        insert.execute(params![
            i64::try_from(*sequence)?,
            kind,
            index_json(bytes)?,
            actor,
            chunk
        ])?;
    }
    Ok(())
}

/// Chunks a [`ChunkReader`] keeps inflated. Sealed records stage one chunk
/// per segment, in sequence order; live rows stage one kind per chunk, so a
/// read in sequence order moves between one open chunk per kind. Past this
/// many kinds interleaved, or past [`OPEN_CHUNK_BYTES`] of inflated JSON, a
/// chunk is inflated again (slower, still exact).
const OPEN_CHUNKS: usize = 64;
/// Inflated JSON the open chunks may hold; a chunk is at most 16 MiB.
const OPEN_CHUNK_BYTES: usize = 256 * 1024 * 1024;

struct OpenChunk {
    chunk: i64,
    json: Vec<u8>,
    records: Vec<(u64, Range<usize>)>,
}

/// Reads staged records back in sequence order, inflating each chunk once
/// while it stays among the [`OPEN_CHUNKS`] most recently read.
pub(super) struct ChunkReader {
    open: std::collections::VecDeque<OpenChunk>,
}

impl ChunkReader {
    pub(super) fn new() -> Self {
        Self { open: std::collections::VecDeque::with_capacity(OPEN_CHUNKS) }
    }

    /// The JSON of staged record `sequence`, held in `chunk`.
    pub(super) fn record(
        &mut self,
        connection: &Connection,
        chunk: i64,
        sequence: u64,
    ) -> anyhow::Result<&[u8]> {
        let position = match self.open.iter().position(|open| open.chunk == chunk) {
            Some(position) => position,
            None => {
                let inflated = Self::inflate(connection, chunk)?;
                let mut bytes = inflated.json.len();
                self.open.retain(|open| {
                    bytes = bytes.saturating_add(open.json.len());
                    bytes <= OPEN_CHUNK_BYTES
                });
                self.open.truncate(OPEN_CHUNKS - 1);
                self.open.push_front(inflated);
                0
            }
        };
        let open = self.open.get(position).context("staged chunk is not open")?;
        let index = open
            .records
            .binary_search_by_key(&sequence, |(sequence, _)| *sequence)
            .map_err(|_| anyhow::anyhow!("staged chunk {chunk} has no record {sequence}"))?;
        let range = open.records.get(index).map(|(_, range)| range.clone());
        range.and_then(|range| open.json.get(range)).context("staged record is out of range")
    }

    fn inflate(connection: &Connection, chunk: i64) -> anyhow::Result<OpenChunk> {
        let (count, codec, content, uncompressed_bytes, sha256) = connection.query_row(
            "SELECT record_count, codec, content, uncompressed_bytes, sha256
             FROM main.output_cleanup_chunks WHERE chunk = ?1",
            [chunk],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Vec<u8>>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                ))
            },
        )?;
        let id = format!("staged chunk {chunk}");
        let json = inflate_segment(&id, &codec, &content, uncompressed_bytes, &sha256)?;
        let mut records: Vec<_> = split_records(&json)?
            .into_iter()
            .map(|record| (record.sequence, record.bytes))
            .collect();
        records.sort_unstable_by_key(|(sequence, _)| *sequence);
        anyhow::ensure!(i64::try_from(records.len())? == count, "{id} record count is invalid");
        Ok(OpenChunk { chunk, json, records })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One registry's staged records were mostly `personal.session.put`
    /// copies of about 7 KB (2026-11-09); format 2 stored each as is.
    #[test]
    fn staged_records_round_trip_compressed_with_their_index_fields() {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(CHUNK_SCHEMA).unwrap();
        let capabilities: Vec<String> = (0..280).map(|i| format!("capability-{i}-v1")).collect();
        let records: Vec<StagedRecord> = (1..=1024_u64)
            .map(|sequence| {
                let record = json!({
                    "sequence": sequence,
                    "event_id": format!("event_{sequence}"),
                    "kind": "personal.session.put",
                    "producer": {"kind": "daemon", "id": "cmux-tui"},
                    "subjects": [{"kind": "session", "id": "remote-1"}],
                    "payload": {"session": {"capabilities": capabilities}},
                });
                (sequence, "personal.session.put".to_owned(), record.to_string().into_bytes(), None)
            })
            .collect();
        let plain: usize = records.iter().map(|record| record.2.len()).sum();
        insert_chunk(&connection, &records).unwrap();
        let stored: i64 = connection
            .query_row(
                "SELECT (SELECT SUM(length(content)) FROM output_cleanup_chunks)
                      + (SELECT SUM(length(index_json)) FROM output_cleanup_records)",
                [],
                |row| row.get(0),
            )
            .unwrap();
        println!("staged_chunk: records=1024 plain_bytes={plain} stored_bytes={stored}");
        assert!(usize::try_from(stored).unwrap() * 20 < plain);
        let mut reader = ChunkReader::new();
        for (sequence, _, bytes, _) in &records {
            assert_eq!(reader.record(&connection, 1, *sequence).unwrap(), bytes.as_slice());
        }
        let (subject, producer): (String, String) = connection
            .query_row(
                "SELECT json_extract(subject.value, '$.id'),
                        json_extract(kept.index_json, '$.producer.kind')
                 FROM output_cleanup_records AS kept,
                      json_each(kept.index_json, '$.subjects') AS subject
                 WHERE kept.sequence = 7",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((subject, producer), ("remote-1".to_owned(), "daemon".to_owned()));
        assert!(reader.record(&connection, 1, 2048).is_err());
    }

    /// Live rows stage in (kind, sequence) order, one kind per chunk; the
    /// pack reads them by sequence and moves between the kinds' chunks.
    #[test]
    fn interleaved_kind_chunks_read_back_in_sequence_order() {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch(CHUNK_SCHEMA).unwrap();
        let record = |sequence: u64, kind: &str| -> StagedRecord {
            let json = json!({"sequence": sequence, "kind": kind, "subjects": []});
            (sequence, kind.to_owned(), json.to_string().into_bytes(), None)
        };
        let odd: Vec<_> = (1..=99).step_by(2).map(|s| record(s, "a.kind")).collect();
        let even: Vec<_> = (2..=100).step_by(2).map(|s| record(s, "b.kind")).collect();
        insert_chunk(&connection, &odd).unwrap();
        insert_chunk(&connection, &even).unwrap();
        let mut reader = ChunkReader::new();
        let mut statement = connection
            .prepare("SELECT sequence, chunk FROM output_cleanup_records ORDER BY sequence")
            .unwrap();
        let rows: Vec<(i64, i64)> = statement
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .unwrap()
            .map(Result::unwrap)
            .collect();
        assert_eq!(rows.len(), 100);
        for (sequence, chunk) in rows {
            let sequence = u64::try_from(sequence).unwrap();
            let json: Value =
                serde_json::from_slice(reader.record(&connection, chunk, sequence).unwrap())
                    .unwrap();
            assert_eq!(json["sequence"], json!(sequence));
        }
        assert_eq!(reader.open.len(), 2, "each chunk was inflated once and kept");
    }
}
