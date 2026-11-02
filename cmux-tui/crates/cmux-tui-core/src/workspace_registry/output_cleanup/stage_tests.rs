//! Phase A keeps every non-output record of a sealed segment, whatever its
//! segment kind map says: a legacy kind backfill killed partway leaves a
//! mixed segment listed as output only, and nothing later tells it apart.
//! The presence check does not trust a map such a backfill left unfinished.

use std::io::Write as _;

use sha2::{Digest, Sha256};

use super::*;

#[test]
fn a_mixed_segment_listed_as_output_only_keeps_its_other_records() {
    let source = Connection::open_in_memory().unwrap();
    source
        .execute_batch(
            "CREATE TABLE journal_segments(
               segment_id TEXT PRIMARY KEY, codec TEXT, content BLOB,
               uncompressed_bytes INTEGER, sha256 BLOB, actors_json TEXT);
             CREATE TABLE journal_segment_kinds(segment_id TEXT, kind TEXT);",
        )
        .unwrap();
    let json = br#"[{"sequence":1,"kind":"terminal.output","payload":{"data":"aGk="}},{"sequence":2,"kind":"terminal.title","payload":{"title":"build"}}]"#;
    let mut encoder =
        flate2::GzBuilder::new().mtime(0).write(Vec::new(), flate2::Compression::fast());
    encoder.write_all(json).unwrap();
    source
        .execute(
            "INSERT INTO journal_segments VALUES('mixed', 'gzip-json-v1', ?1, ?2, ?3, NULL)",
            params![
                encoder.finish().unwrap(),
                i64::try_from(json.len()).unwrap(),
                Sha256::digest(json).as_slice()
            ],
        )
        .unwrap();
    // The backfill was killed after its first kind row for this segment.
    source.execute("INSERT INTO journal_segment_kinds VALUES('mixed', ?1)", [OUTPUT_KIND]).unwrap();

    let kept = kept_segment_records(&source, "mixed", 1, 2, 2).unwrap();
    let kept: Vec<(u64, &str)> = kept.iter().map(|record| (record.0, record.1.as_str())).collect();
    assert_eq!(kept, vec![(2, "terminal.title")], "the title record is not output");
}

/// A source with `rows` live journal rows after an empty archive, and a
/// staging file with the cleanup state keys.
fn live_rows(rows: i64) -> (Connection, Connection) {
    let source = Connection::open_in_memory().unwrap();
    source
        .execute_batch(
            "CREATE TABLE journal_segments(end_sequence INTEGER);
             CREATE TABLE session_journal(sequence INTEGER PRIMARY KEY, kind TEXT);
             CREATE INDEX session_journal_by_kind_sequence ON session_journal(kind, sequence);",
        )
        .unwrap();
    source
        .execute(
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < ?1)
             INSERT INTO session_journal SELECT i, 'terminal.output' FROM n",
            [rows],
        )
        .unwrap();
    let staging = Connection::open_in_memory().unwrap();
    staging
        .execute_batch(
            "CREATE TABLE output_cleanup_state(key TEXT PRIMARY KEY, value TEXT);
             INSERT INTO output_cleanup_state VALUES
               ('live_archive_end', '0'), ('live_head', '0'), ('live_output', '0');",
        )
        .unwrap();
    (source, staging)
}

#[test]
fn a_stop_cuts_the_live_row_count_short() {
    // The count reads the whole live journal in one statement; a stop must
    // not wait for it, or the owner's shutdown waits too.
    let (source, staging) = live_rows(200_000);
    stop_reads_on(&source, std::sync::Arc::new(|| true)).unwrap();
    let error = count_live_rows(&source, &staging).unwrap_err();
    let interrupted = error.chain().any(|cause| {
        cause.downcast_ref::<rusqlite::Error>().and_then(rusqlite::Error::sqlite_error_code)
            == Some(rusqlite::ErrorCode::OperationInterrupted)
    });
    assert!(interrupted, "{error:#}");
    assert_eq!(state(&staging, "live_head").unwrap(), "0", "nothing was recorded");

    // Not stopping, the same count finishes.
    let (source, staging) = live_rows(200_000);
    stop_reads_on(&source, std::sync::Arc::new(|| false)).unwrap();
    count_live_rows(&source, &staging).unwrap();
    assert_eq!(state(&staging, "live_head").unwrap(), "200000");
    assert_eq!(state(&staging, "live_output").unwrap(), "200000");
}

/// A source whose only sealed segment is mapped to a non-output kind.
fn mapped_source(backfill: Option<&str>) -> Connection {
    let source = Connection::open_in_memory().unwrap();
    source
        .execute_batch(
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE journal_segments(segment_id TEXT PRIMARY KEY);
             CREATE TABLE journal_segment_kinds(segment_id TEXT, kind TEXT);
             CREATE TABLE session_journal(sequence INTEGER PRIMARY KEY, kind TEXT);
             CREATE INDEX session_journal_by_kind_sequence ON session_journal(kind, sequence);
             INSERT INTO journal_segments VALUES('mixed');
             INSERT INTO journal_segment_kinds VALUES('mixed', 'agent.session.started');",
        )
        .unwrap();
    if let Some(value) = backfill {
        source
            .execute("INSERT INTO meta VALUES('journal_segment_kinds_backfill', ?1)", [value])
            .unwrap();
    }
    source
}

#[test]
fn an_interrupted_kind_backfill_never_marks_the_cleanup_not_needed() {
    // The backfill was killed after the segment's first kind row, before its
    // terminal.output row: the map alone says "no output".
    assert!(output_present(&mapped_source(Some("0"))).unwrap());
    // A finished backfill's map is trusted.
    assert!(!output_present(&mapped_source(Some("1"))).unwrap());
    // Segments sealed with their kind map (no backfill ever ran).
    assert!(!output_present(&mapped_source(None)).unwrap());
}

#[test]
fn a_resumed_kind_backfill_decodes_partly_mapped_segments_again() {
    // The startup backfill sets its marker to `1` when it finishes. Resumed
    // after a stop, it must revisit a segment that already has some kind
    // rows, or the missing `terminal.output` row is never added and the map
    // later says "no output".
    let source = Connection::open_in_memory().unwrap();
    source
        .execute_batch(
            "CREATE TABLE journal_segments(segment_id TEXT PRIMARY KEY, start_sequence INTEGER);
             CREATE TABLE journal_segment_kinds(segment_id TEXT, kind TEXT);
             INSERT INTO journal_segments VALUES('partly', 1), ('unmapped', 3);
             INSERT INTO journal_segment_kinds VALUES('partly', 'agent.session.started');",
        )
        .unwrap();
    let ids = |resumed| {
        super::super::super::session_journal::legacy_backfill_segment_ids(&source, resumed).unwrap()
    };
    assert_eq!(ids(false), vec!["unmapped".to_owned()]);
    assert_eq!(ids(true), vec!["partly".to_owned(), "unmapped".to_owned()]);
}
