//! The `server-stats` `disk` section reads the sizes of the sealed
//! segments; it must not copy their content.
//!
//! On one Mac (a 10.7 GB registry, 2,816 segments holding 2,012 MiB,
//! 2026-11-13) the daemon wrote 2,438 MiB in the minute of one
//! `server-stats` request that took 33 s. The section summed the segments
//! with `GROUP BY codec`, and SQLite sorts for that: its sorter took every
//! column the sums read, the whole `content` blob included, and spilled
//! them to a temporary file. The sums are kept per daemon, so each daemon
//! start paid it once, and the nightly restarts the daemon several times a
//! day.
//!
//! A deleted temporary file of a short test never reaches the disk, so no
//! process counter shows it. The test therefore keeps SQLite's temporary
//! storage in memory on its own read-only connection and reads SQLite's
//! memory high-water mark around the section's segment read: what the
//! sorter would spill is what it holds. Nextest runs each test in a process
//! of its own, so the mark is this test's. A count, not a time.

use super::*;

const SEGMENTS: u64 = 48;
const SEGMENT_BYTES: u64 = 1024 * 1024;
/// SQLite memory the segment read may take: far under the segments' 48 MiB.
const READ_MEMORY_BUDGET: u64 = 4 * 1024 * 1024;

/// SQLite's memory in use now; `reset` restarts its high-water mark there.
fn sqlite_memory(reset: bool) -> (u64, u64) {
    // SAFETY: both calls only read (and reset) SQLite's memory counters.
    let (used, high) = unsafe {
        (
            rusqlite::ffi::sqlite3_memory_used(),
            rusqlite::ffi::sqlite3_memory_highwater(i32::from(reset)),
        )
    };
    (u64::try_from(used).unwrap(), u64::try_from(high).unwrap())
}

#[cfg(unix)]
#[test]
fn the_disk_section_reads_segment_sizes_without_copying_their_content() {
    let root = std::env::temp_dir()
        .join(format!("cmux-disk-read-cost-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("disk-read-cost", &root);
    mux.stop_journal_maintenance();
    let database_path = mux.journal_kernel.database_path().unwrap().to_path_buf();
    {
        let db = mux.registry_connection.get();
        for index in 0..SEGMENTS {
            let start = 1_000_000 + index * 10;
            db.execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES(?1, ?2, ?3, 10, 'zstd', randomblob(?4), ?5, randomblob(32), 1)",
                rusqlite::params![
                    format!("segment_test_{index}"),
                    i64::try_from(start).unwrap(),
                    i64::try_from(start + 9).unwrap(),
                    i64::try_from(SEGMENT_BYTES).unwrap(),
                    i64::try_from(2 * SEGMENT_BYTES).unwrap(),
                ],
            )
            .unwrap();
        }
    }
    // The daemon's own SQLite memory must not move the mark.
    mux.shutdown();

    let connection =
        crate::workspace_registry::open_registry_database_read_only(&database_path).unwrap();
    connection.execute_batch("PRAGMA query_only=ON; PRAGMA temp_store=MEMORY;").unwrap();
    // Open the schema and the page cache before the mark starts.
    let rows: i64 = connection
        .query_row("SELECT COUNT(*) FROM journal_segments", [], |row| row.get(0))
        .unwrap();
    assert_eq!(u64::try_from(rows).unwrap(), SEGMENTS);
    let (used_before, _) = sqlite_memory(true);
    let segments = crate::diagnostics::read_segments_for_test(&connection).unwrap();
    let (_, high) = sqlite_memory(false);
    let read_memory = high.saturating_sub(used_before);
    println!(
        "disk_usage_read_cost: segments={SEGMENTS} segment_bytes={} read_sqlite_memory={read_memory}",
        SEGMENTS * SEGMENT_BYTES
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&root);

    assert_eq!(segments.segments, SEGMENTS, "{segments:?}");
    assert_eq!(segments.records, SEGMENTS * 10, "{segments:?}");
    assert_eq!(segments.compressed_bytes, SEGMENTS * SEGMENT_BYTES, "{segments:?}");
    assert_eq!(segments.uncompressed_bytes, SEGMENTS * 2 * SEGMENT_BYTES, "{segments:?}");
    assert_eq!(segments.by_codec.len(), 1, "{segments:?}");
    assert!(
        read_memory <= READ_MEMORY_BUDGET,
        "summing {} bytes of segments held {read_memory} bytes in SQLite (budget \
         {READ_MEMORY_BUDGET}): the read must take the sizes, not the content, which a \
         daemon's sorter spills to a temporary file",
        SEGMENTS * SEGMENT_BYTES
    );
}
