//! The `disk` section's read of the sealed segments does not read their
//! content.
//!
//! A sealed segment keeps its records in one `content` blob, megabytes on
//! overflow pages. Two things made the first `disk` request of a daemon read
//! every one of those pages: the sums ran with `GROUP BY codec`, which has no
//! index, so SQLite sorted the rows with the blob in the sorter; and
//! `uncompressed_bytes` is stored after the blob in the row, so reading it
//! can walk the blob's overflow chain. On a large registry the request ran
//! past the client's 10 s limit. The section also summed every segment again
//! when the count of the segments it had summed changed.
//!
//! The tests seal segments on a real on-disk registry and count the bytes
//! their thread reads from files during a `disk` read. Bytes, not time.
//! Linux only: the count is the thread's `rchar` in `/proc`.
//!
//! The bytes do not show how many sizes were read: on a new registry SQLite
//! can go past an overflow chain with no read of it (the pointer map). So
//! the tests also count the size reads of the section.

use sha2::{Digest, Sha256};

use super::*;
use crate::workspace_registry::new_uuid_v4;
use crate::workspace_registry::session_journal::kind_read_tests::TestJournalRecord;
use crate::{JournalProducer, JournalSubject};

/// Text in one record's payload.
const PAYLOAD_BYTES: usize = 16 * 1024;
const HEX: &[u8; 16] = b"0123456789abcdef";
const MIB: u64 = 1024 * 1024;

/// A record with `PAYLOAD_BYTES` of hex text from a SHA-256 chain: the same
/// text in every run, and it compresses to about half, so the segments keep
/// megabytes of content.
fn record(index: usize) -> TestJournalRecord {
    let session = format!("sess_{:032x}", index % 64);
    let mut block = Sha256::digest(u64::try_from(index).unwrap().to_le_bytes());
    let mut text = String::with_capacity(PAYLOAD_BYTES + 64);
    while text.len() < PAYLOAD_BYTES {
        for &byte in block.iter() {
            text.push(char::from(HEX[usize::from(byte >> 4)]));
            text.push(char::from(HEX[usize::from(byte & 15)]));
        }
        block = Sha256::digest(block);
    }
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

/// Appends `records` records and seals them, `segments` times: one segment
/// (or more) a time.
fn seal_segments(mux: &Mux, segments: usize, records: usize) {
    for segment in 0..segments {
        let batch: Vec<TestJournalRecord> =
            (0..records).map(|index| record(segment * records + index)).collect();
        for chunk in batch.chunks(64) {
            mux.workspace_registry.lock().unwrap().append_journal_records_for_test(chunk);
        }
        let through = mux
            .create_journal_checkpoint(
                "client_test",
                &format!("disk_read_cost_checkpoint_{segment}"),
            )
            .unwrap()
            .checkpoint
            .source_sequence;
        let mut sealed_through = 0;
        for round in 0..32 {
            if sealed_through >= through {
                break;
            }
            sealed_through = mux
                .seal_journal_segments(
                    through,
                    "client_test",
                    &format!("disk_read_cost_{segment}_{round}"),
                )
                .unwrap()
                .through_sequence;
        }
        assert!(sealed_through >= through, "the seal stopped at {sealed_through} of {through}");
    }
}

/// Bytes this thread has read from files: `rchar` of its I/O accounting.
fn thread_read_bytes() -> u64 {
    let io = std::fs::read_to_string("/proc/thread-self/io")
        .expect("the thread's I/O accounting in /proc");
    io.lines()
        .find_map(|line| line.strip_prefix("rchar: "))
        .and_then(|value| value.trim().parse().ok())
        .unwrap_or_else(|| panic!("no rchar line in /proc/thread-self/io: {io}"))
}

/// Size reads of the `disk` section since the daemon started: one for each
/// segment whose size before compression it read from the registry.
fn size_reads(mux: &Mux) -> u64 {
    mux.disk_usage.lock().unwrap().size_reads()
}

fn registry_number(mux: &Mux, sql: &str) -> u64 {
    let value: i64 = mux.registry_connection.get().query_row(sql, [], |row| row.get(0)).unwrap();
    u64::try_from(value).unwrap()
}

#[test]
fn the_first_disk_read_does_not_read_the_content_of_every_sealed_segment() {
    const SEGMENTS: usize = 32;
    const RECORDS: usize = 32;
    let root = std::env::temp_dir().join(format!("cmux-disk-read-cost-{}", new_uuid_v4()));
    let mux = open_persistent_test_mux("disk-read-cost", &root);
    mux.stop_journal_maintenance();
    seal_segments(&mux, SEGMENTS, RECORDS);
    let uncompressed =
        registry_number(&mux, "SELECT SUM(uncompressed_bytes) FROM journal_segments");

    // The first read of this daemon: the section has nothing kept.
    let before = thread_read_bytes();
    let disk = mux.disk_usage_stats().expect("an on-disk registry");
    let read = thread_read_bytes() - before;
    let sized = size_reads(&mux);
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);

    let segments = disk.segments.as_ref().unwrap_or_else(|| panic!("segments read: {disk:?}"));
    println!(
        "disk_read_cost: first read: segments={} records={} compressed_bytes={} \
         uncompressed_bytes={} (the sum is {uncompressed}) read_bytes={read}",
        segments.segments, segments.records, segments.compressed_bytes, segments.uncompressed_bytes
    );
    assert!(
        segments.segments >= u64::try_from(SEGMENTS).unwrap()
            && segments.records >= u64::try_from(SEGMENTS * RECORDS).unwrap(),
        "control: every record must be in a sealed segment: {segments:?}"
    );
    assert!(
        segments.compressed_bytes >= 4 * MIB,
        "control: the segments must hold megabytes of content: {segments:?}"
    );
    // More than 8 segments of one codec: the size before compression is an
    // estimate from the newest 8. These segments are alike, so it is near.
    assert!(
        segments.uncompressed_bytes.abs_diff(uncompressed) <= uncompressed / 10,
        "the estimate {} is not within a tenth of the sum {uncompressed}: {segments:?}",
        segments.uncompressed_bytes
    );
    assert_eq!(
        (segments.by_codec.len(), sized),
        (1, 8),
        "the size is read for the newest 8 segments of the one codec, not for all {}: \
         {segments:?}",
        segments.segments
    );
    assert!(
        read <= segments.compressed_bytes / 2,
        "the first disk read read {read} bytes from files for {} bytes of content in {} \
         segments: it may read the content of 8 of them, not of all (budget {})",
        segments.compressed_bytes,
        segments.segments,
        segments.compressed_bytes / 2
    );
}

#[test]
fn a_disk_read_after_old_segments_are_gone_reads_no_segment_content() {
    const SEGMENTS: usize = 8;
    const RECORDS: usize = 128;
    const DELETED: u64 = 4;
    let root = std::env::temp_dir().join(format!("cmux-disk-read-cost-{}", new_uuid_v4()));
    let mux = open_persistent_test_mux("disk-read-cost-delete", &root);
    mux.stop_journal_maintenance();
    seal_segments(&mux, SEGMENTS, RECORDS);
    let first = mux.disk_usage_stats().expect("an on-disk registry");
    let first = first.segments.as_ref().unwrap_or_else(|| panic!("segments read: {first:?}"));
    let sized_first = size_reads(&mux);

    // A later change can delete old segments. The daemon deletes none now (a
    // trigger refuses it), so the test drops the trigger and deletes the
    // oldest itself.
    mux.registry_connection
        .get()
        .execute_batch(&format!(
            "DROP TRIGGER IF EXISTS journal_segments_reject_delete;
             DELETE FROM journal_segment_kinds WHERE segment_id IN
               (SELECT segment_id FROM journal_segments
                ORDER BY start_sequence LIMIT {DELETED});
             DELETE FROM journal_segments WHERE start_sequence IN
               (SELECT start_sequence FROM journal_segments
                ORDER BY start_sequence LIMIT {DELETED});"
        ))
        .unwrap();
    let left = registry_number(&mux, "SELECT COUNT(*) FROM journal_segments");
    let records = registry_number(&mux, "SELECT SUM(record_count) FROM journal_segments");
    let compressed = registry_number(&mux, "SELECT SUM(length(content)) FROM journal_segments");
    let uncompressed =
        registry_number(&mux, "SELECT SUM(uncompressed_bytes) FROM journal_segments");
    let with_kind = registry_number(
        &mux,
        "SELECT COUNT(*) FROM journal_segment_kinds WHERE kind = 'personal.session.put'",
    );

    let before = thread_read_bytes();
    let disk = mux.disk_usage_stats().expect("an on-disk registry");
    let read = thread_read_bytes() - before;
    let sized = size_reads(&mux);
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);

    let segments = disk.segments.as_ref().unwrap_or_else(|| panic!("segments read: {disk:?}"));
    println!(
        "disk_read_cost: after the delete: segments={} (were {}) compressed_bytes={} \
         read_bytes={read}",
        segments.segments, first.segments, segments.compressed_bytes
    );
    assert_eq!(first.segments, left + DELETED, "control: the delete took {DELETED} segments");
    assert!(compressed >= 2 * MIB, "control: megabytes of content must be left: {compressed}");
    // The section is of the segments that are left, as a first read would be.
    assert_eq!(
        (segments.segments, segments.records, segments.compressed_bytes),
        (left, records, compressed),
        "{segments:?}"
    );
    assert_eq!(segments.uncompressed_bytes, uncompressed, "at most 8 segments: exact");
    assert_eq!(
        (first.segments, sized_first, sized),
        (8, 8, 8),
        "the read after the delete reads no size again: the segments that are left keep theirs"
    );
    let put = segments.kinds.iter().find(|kind| kind.kind == "personal.session.put");
    assert_eq!(put.map(|kind| kind.segments), Some(with_kind), "{:?}", segments.kinds);
    assert!(
        read <= compressed / 2,
        "the disk read after {DELETED} old segments were deleted read {read} bytes from files \
         for {compressed} bytes of content in {left} segments: it must take the deleted \
         segments out of what it kept, not read the others again (budget {})",
        compressed / 2
    );
}
