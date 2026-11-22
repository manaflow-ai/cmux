//! Sealing a journal segment writes the segment, not zeros over the rows it
//! replaces (REGISTRY WAL, the seal's zero pages).
//!
//! On one Mac (826 workspaces, a 10.7 GB registry, 2026-11-13) 37% of the
//! frames in the registry WAL were pages of zeros, all of them in the
//! commits that seal a segment: about nine of ten pages such a commit wrote.
//! The registry connection runs with `secure_delete` on, so the seal's
//! delete of the journal rows wrote every overflow page it freed, although
//! the same records stay in the registry, in the segment the same
//! transaction inserts. Each zero page was then written once more by the
//! checkpoint, and moved or dropped by the incremental vacuum.
//!
//! The test runs a real `Mux` on an on-disk registry, appends records whose
//! payloads take overflow pages, seals them and counts the WAL frame bytes
//! of the seal. Counts, not times.

use super::*;
use crate::workspace_registry::new_uuid_v4;
use crate::workspace_registry::session_journal::kind_read_tests::TestJournalRecord;
use crate::{JournalProducer, JournalSubject};

/// Records the test seals.
const RECORDS: usize = 512;
/// Text in one record's payload: three pages, so its row has an overflow chain.
const PAYLOAD_BYTES: usize = 12 * 1024;

/// A record with `PAYLOAD_BYTES` of text that compresses, as terminal and
/// resource records do.
fn record(index: usize) -> TestJournalRecord {
    let session = format!("sess_{:032x}", index % 64);
    let line = format!("{index:08} the quick brown fox jumps over the lazy dog\n");
    let text = line.repeat(PAYLOAD_BYTES / line.len() + 1);
    TestJournalRecord {
        kind: "personal.session.put".into(),
        producer: JournalProducer { kind: "presentation".into(), id: "cmux-tui".into() },
        subjects: vec![JournalSubject { kind: "session".into(), id: session.clone() }],
        payload: serde_json::json!({
            "session": {"session_id": session, "last_seen_ms": index, "note": text},
            "created": false,
            "personal_revision": index,
        }),
    }
}

fn wal_frame_bytes(mux: &Mux) -> u64 {
    mux.write_path_stats().registry_wal_frame_bytes
}

fn registry_number(mux: &Mux, sql: &str) -> u64 {
    let value: i64 = mux.registry_connection.get().query_row(sql, [], |row| row.get(0)).unwrap();
    u64::try_from(value).unwrap()
}

#[cfg(unix)]
#[test]
fn sealing_a_segment_does_not_write_zeros_over_the_rows_it_replaces() {
    let root = std::env::temp_dir().join(format!("cmux-seal-cost-{}", new_uuid_v4()));
    let mux = open_persistent_test_mux("seal-cost", &root);
    mux.stop_journal_maintenance();
    let records: Vec<TestJournalRecord> = (0..RECORDS).map(record).collect();
    for batch in records.chunks(64) {
        mux.workspace_registry.lock().unwrap().append_journal_records_for_test(batch);
    }
    let payload_bytes = u64::try_from(RECORDS * PAYLOAD_BYTES).unwrap();
    let through = mux
        .create_journal_checkpoint("client_test", "seal_cost_checkpoint")
        .unwrap()
        .checkpoint
        .source_sequence;

    let before = wal_frame_bytes(&mux);
    let mut sealed_through = 0;
    for round in 0..32 {
        if sealed_through >= through {
            break;
        }
        sealed_through = mux
            .seal_journal_segments(through, "client_test", &format!("seal_cost_{round}"))
            .unwrap()
            .through_sequence;
    }
    let seal_wal_bytes = wal_frame_bytes(&mux) - before;
    let sealed_records =
        registry_number(&mux, "SELECT COALESCE(SUM(record_count), 0) FROM journal_segments");
    let segment_bytes =
        registry_number(&mux, "SELECT COALESCE(SUM(length(content)), 0) FROM journal_segments");
    let live_rows = registry_number(
        &mux,
        "SELECT COUNT(*) FROM session_journal WHERE kind = 'personal.session.put'",
    );
    let secure_delete = registry_number(&mux, "PRAGMA secure_delete");
    println!(
        "journal_seal_cost: records={RECORDS} payload_bytes={payload_bytes} \
         segment_bytes={segment_bytes} seal_wal_frame_bytes={seal_wal_bytes} \
         wal_bytes_per_1000_payload={} secure_delete_after={secure_delete}",
        seal_wal_bytes * 1000 / payload_bytes,
    );
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);

    assert!(sealed_through >= through, "the seal stopped at {sealed_through} of {through}");
    assert!(
        sealed_records >= u64::try_from(RECORDS).unwrap() && live_rows == 0,
        "control: the records must move into segments: {sealed_records} sealed, {live_rows} live"
    );
    assert_eq!(
        secure_delete, 1,
        "deletes after a seal must zero what they free: secure_delete is {secure_delete}"
    );
    assert!(
        seal_wal_bytes <= payload_bytes / 4,
        "sealing {payload_bytes} payload bytes into {segment_bytes} segment bytes wrote \
         {seal_wal_bytes} WAL bytes: the rows stay in the segment, so the seal must not write \
         the pages they leave (budget {})",
        payload_bytes / 4
    );
}
