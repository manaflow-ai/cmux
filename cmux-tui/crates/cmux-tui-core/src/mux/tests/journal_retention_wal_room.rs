//! The retention pass and the room in the registry's WAL
//! (`workspace_registry::wal_durability::WalRoom`).
//!
//! The pass is a background writer: before the first hold of a tick, and
//! after each hold, it asks the WAL syncer for a look at the WAL and waits
//! for it. It begins no hold while the WAL file is past its limit with
//! frames that the look could not copy: its megabytes would only make that
//! file larger.
//!
//! Each test here has a session with a sealed segment that the floor has
//! passed, and a registry WAL of more than `WAL_SIZE_LIMIT_BYTES` that a
//! reader's snapshot holds (a long read of the registry does that; so do
//! requests that write faster than the checkpoint copies). No test times
//! anything.
#![cfg(unix)]

use super::journal_retention_bound::{RECORDS, head, write_through};
use super::journal_retention_holds::{Big, session_with_a_big_segment};
use super::*;
use crate::workspace_registry::wal_durability::WAL_SIZE_LIMIT_BYTES;

/// A row of `meta` that the test writes again and again to fill the WAL.
const FILLER_KEY: &str = "retention_wal_room_test";
/// Ticks the setup runs at most until one of them comes to the pass's
/// question for WAL room.
const SETUP_TICKS: usize = 32;

/// The registry file's WAL: its size now.
fn wal_file_bytes(mux: &Mux) -> u64 {
    mux.registry_connection.wal_file_bytes().0
}

fn retention_floor(mux: &Mux) -> u64 {
    mux.workspace_registry.lock().unwrap().journal_retention_floor().unwrap()
}

/// A reader connection with a snapshot of the registry as it is now: no
/// checkpoint copies a frame that is newer than this snapshot.
fn reader_with_a_snapshot(mux: &Mux) -> rusqlite::Connection {
    let path = mux
        .workspace_registry
        .lock()
        .unwrap()
        .session_journal_database_path()
        .expect("an on-disk registry");
    let reader = rusqlite::Connection::open(path).unwrap();
    reader.execute_batch("BEGIN").unwrap();
    let _: i64 = reader.query_row("SELECT COUNT(*) FROM meta", [], |row| row.get(0)).unwrap();
    reader
}

/// Commits more than `WAL_SIZE_LIMIT_BYTES` to the registry on its own
/// connection, with no request and no flush request: one megabyte in one
/// row, again and again. The row is gone at the end.
fn fill_the_wal_past_its_limit(mux: &Mux) {
    let registry = mux.workspace_registry.lock().unwrap();
    let db = registry.connection.get();
    let megabyte = vec![7u8; 1024 * 1024];
    for _ in 0..(WAL_SIZE_LIMIT_BYTES / 1024 / 1024 + 8) {
        db.execute(
            "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
            rusqlite::params![FILLER_KEY, megabyte],
        )
        .unwrap();
    }
    db.execute("DELETE FROM meta WHERE key = ?1", [FILLER_KEY]).unwrap();
    drop(db);
    drop(registry);
    let bytes = wal_file_bytes(mux);
    assert!(bytes > WAL_SIZE_LIMIT_BYTES, "the setup: the WAL file is only {bytes} bytes");
}

/// A session whose first sealed segment the retention floor has passed,
/// while a reader's snapshot holds a WAL of more than the limit; that
/// reader. The last tick so far found that WAL.
fn session_with_a_segment_to_delete_and_a_held_wal(
    root: &Path,
) -> (Arc<Mux>, Big, rusqlite::Connection) {
    let mut next_step = 0;
    let (mux, agents, big) = session_with_a_big_segment(root, &mut next_step);
    let reader = reader_with_a_snapshot(&mux);
    fill_the_wal_past_its_limit(&mux);
    write_through(&mux, &agents, &mut next_step, head(&mux) + RECORDS);
    // Until a tick came to the pass's question for WAL room (or deleted the
    // segment, which the tests refuse): the agent history fold is at the
    // head then and no record follows, so each later tick comes to it too.
    for _ in 0..SETUP_TICKS {
        if mux.journal_no_wal_room_ticks() > 0 || mux.journal_pruned_through().unwrap() >= big.end {
            break;
        }
        mux.run_journal_maintenance_for_test();
    }
    let floor = retention_floor(&mux);
    assert!(floor >= big.end, "the setup: floor {floor}, the segment ends at {}", big.end);
    let bytes = wal_file_bytes(&mux);
    assert!(bytes > WAL_SIZE_LIMIT_BYTES, "the setup: the reader holds a WAL of {bytes} bytes");
    // The defect that these tests are about, found in the setup: a hold
    // began while the reader held the WAL. No test goes on from that state.
    let pruned_through = mux.journal_pruned_through().unwrap();
    assert!(
        pruned_through < big.end,
        "the pass began the delete of the segment that ends at {} (deleted through \
         {pruned_through}) into a WAL of {bytes} bytes that a reader holds",
        big.end
    );
    // A setup that ends with no tick at the question would let a test pass
    // on nothing.
    assert!(
        mux.journal_no_wal_room_ticks() > 0,
        "the setup: none of {SETUP_TICKS} ticks came to the pass's question for WAL room (floor \
         {floor}, the segment ends at {}, deleted through {pruned_through})",
        big.end
    );
    (mux, big, reader)
}

/// While the WAL has no room, a tick begins no hold of the delete: the
/// floor that retention deleted through does not move. The tick is counted,
/// and it leaves work for the next tick, which asks again.
#[test]
fn a_tick_begins_no_hold_while_the_registry_wal_has_no_room_and_counts_it() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-retention-no-room-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let (mux, big, reader) = session_with_a_segment_to_delete_and_a_held_wal(&root);
    let counted_before = mux.journal_no_wal_room_ticks();
    let settled = (0..4).map(|_| mux.run_journal_maintenance_for_test()).collect::<Vec<_>>();
    let pruned_through = mux.journal_pruned_through().unwrap();
    let counted = mux.journal_no_wal_room_ticks();
    let bytes = wal_file_bytes(&mux);
    drop(reader);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
    assert!(
        pruned_through < big.end,
        "the pass began the delete of the segment that ends at {} (deleted through \
         {pruned_through}) into a WAL of {bytes} bytes that a reader holds",
        big.end
    );
    assert_eq!(
        counted,
        counted_before + 4,
        "each of 4 ticks that began no hold for want of WAL room is counted"
    );
    assert_eq!(settled, [false; 4], "a tick with a segment to delete leaves work for the next");
}

/// The idle hole. A burst of requests (here: a reader's snapshot) left the
/// WAL file past its limit; then the reader ended and no request came. No
/// commit asks the syncer for a checkpoint, and SQLite does not cut the WAL
/// file at a checkpoint, so the file stays past the limit until a write
/// restarts the WAL. A pass that only looked at the file's size would never
/// write again, and the worker would wake each 30 s for nothing.
///
/// The pass's own question starts the syncer's look, which copies each
/// frame: the pass has room. The first tick begins its hold; that commit
/// restarts the WAL and SQLite cuts the file to the limit. When the segment
/// is gone the worker settles: it does not wake by the period. It also
/// settles, with no look at the WAL, when the WAL is past its limit again
/// and no segment waits.
#[test]
fn the_retention_pass_takes_a_copied_wal_past_its_limit_with_no_request() {
    let root = std::env::temp_dir()
        .join(format!("cmux-journal-retention-idle-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, big, reader) = session_with_a_segment_to_delete_and_a_held_wal(&root);
    reader.execute_batch("COMMIT").unwrap();
    drop(reader);
    let before = wal_file_bytes(&mux);
    assert!(before > WAL_SIZE_LIMIT_BYTES, "the setup: the WAL file is {before} bytes");
    let counted_before = mux.journal_no_wal_room_ticks();

    // ONE tick, with no request before it.
    mux.run_journal_maintenance_for_test();
    let pruned_through = mux.journal_pruned_through().unwrap();
    let after = wal_file_bytes(&mux);
    let counted = mux.journal_no_wal_room_ticks();

    // Nothing is owed after the delete: the worker settles.
    let ticks_to_settle = (1..=64).find(|_| mux.run_journal_maintenance_for_test());
    let left = mux
        .journal_segments()
        .unwrap()
        .iter()
        .filter(|segment| segment.end_sequence <= big.end)
        .count();

    // A WAL past its limit with no segment to delete: no look, no count,
    // and the worker still settles.
    let reader = reader_with_a_snapshot(&mux);
    fill_the_wal_past_its_limit(&mux);
    let settles_again = (1..=16).find(|_| mux.run_journal_maintenance_for_test());
    let counted_at_idle = mux.journal_no_wal_room_ticks();
    drop(reader);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();

    assert!(
        pruned_through >= big.end,
        "the first tick after the reader ended began no hold: deleted through {pruned_through}, \
         the segment ends at {}; the WAL file was {before} bytes with each frame copied by the \
         look that the pass asked for, and is {after} bytes now",
        big.end
    );
    assert!(
        after <= WAL_SIZE_LIMIT_BYTES,
        "the WAL file is {after} bytes after the tick's holds ({before} before)"
    );
    assert_eq!(counted, counted_before, "a tick that had room was counted as one without");
    assert!(
        ticks_to_settle.is_some(),
        "64 ticks after the delete all left work for the next tick: the worker wakes by the period"
    );
    assert_eq!(left, 0, "the segment and those before it are gone when the worker settles");
    assert!(
        settles_again.is_some(),
        "16 ticks with a WAL past its limit and no segment to delete all left work for the next"
    );
    assert_eq!(
        counted_at_idle, counted,
        "a tick with no segment to delete asked for WAL room and was counted"
    );
}
