//! The WAL restart rule (`wal_durability` module docs): the WAL file's size
//! under commits with no pause, behind a long read, after a previous run
//! left it large, and at a clean stop. Bytes and counts; the only times are
//! the rule's own wait limit.

use std::time::Instant;

use super::tests::{database, grow_a_pinned_wal};
use super::*;

/// The WAL file's bound under commits that this test asserts: the size
/// limit and four steps between tries to restart it. The rule's own bound
/// is the limit plus one commit; the margin lets two tries in a row end
/// late on a busy disk (their steps: 4 MiB, then 8 MiB).
const STORM_WAL_BOUND_BYTES: u64 = WAL_SIZE_LIMIT_BYTES + 4 * CHECKPOINT_BYTES;

/// One commit that rewrites the 64 KiB row 1 and, like an answered request,
/// asks for a flush. `round` makes each value new: SQLite writes no page
/// whose content did not change, so an equal value is no commit at all.
fn rewrite_the_row(connection: &Connection, durability: &WalDurability, round: u64) {
    let blob = vec![u8::try_from(round % 251).unwrap_or(0); 64 * 1024];
    connection.execute("INSERT OR REPLACE INTO t(rowid, v) VALUES (1, ?1)", [&blob]).unwrap();
    durability.request_flush();
}

/// Commits `frame_bytes` of WAL frames with no pause between them
/// ([`rewrite_the_row`]). Returns the commit count.
fn commit_storm(connection: &Connection, durability: &WalDurability, frame_bytes: u64) -> u64 {
    rewrite_the_row(connection, durability, 0);
    let before = durability.wal_frame_bytes();
    let mut commits = 0;
    while durability.wal_frame_bytes() - before < frame_bytes {
        commits += 1;
        rewrite_the_row(connection, durability, commits);
        // A commit that wrote nothing would never end this loop.
        assert!(commits < 100_000, "{commits} commits wrote under {frame_bytes} bytes of frames");
    }
    commits
}

#[test]
fn a_commit_storm_keeps_the_wal_file_under_its_bound() {
    // A session build, a restore or an agent burst commits with no pause
    // (one registry built 4000 changes in 53 s and left a 1366 MB WAL
    // beside a 45 MB database). No reader pins the WAL here.
    let (dir, connection) = database("storm");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    let storm = 3 * WAL_SIZE_LIMIT_BYTES;
    let commits = commit_storm(&connection, &durability, storm);
    let (now, high_water) = durability.wal_file_bytes();
    let (waits, longest) = durability.restart_waits();
    println!(
        "wal_storm: commits={commits} frame_bytes={storm} wal_file_bytes={now} \
         wal_file_high_water_bytes={high_water} bound={STORM_WAL_BOUND_BYTES} \
         restart_waits={waits} longest_wait_ms={}",
        longest.as_millis()
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        high_water <= STORM_WAL_BOUND_BYTES,
        "{commits} commits with no pause ({storm} bytes of frames) grew the WAL file to \
         {high_water} bytes; the bound is {STORM_WAL_BOUND_BYTES}"
    );
    // The price: one wait per restart (two or three in three limits of
    // frames; a try that ended late adds one), never one per commit.
    assert!((2..=6).contains(&waits), "{waits} of {commits} commits waited");
    assert!(longest < 2 * RESTART_WAIT, "a commit waited {longest:?}");
}

#[test]
fn a_wal_left_over_the_limit_is_cut_by_the_first_commits_of_the_next_open() {
    // A daemon that was killed in a commit storm, or one of an older
    // build, leaves a WAL far over the limit. The next daemon checkpoints
    // it at once, with no caller that asks, and its first commits cut it.
    let (dir, connection) = database("left");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    let left = grow_a_pinned_wal(&path, &connection, &durability);
    // What a kill leaves on the disk: the database and its WAL as they
    // are, with no close. The WAL is never deleted.
    let next = dir.join("next");
    std::fs::create_dir_all(&next).unwrap();
    let next_path = next.join("r.sqlite");
    let next_wal = next.join("r.sqlite-wal");
    std::fs::copy(&path, &next_path).unwrap();
    std::fs::copy(dir.join("r.sqlite-wal"), &next_wal).unwrap();
    drop(connection);

    let connection = Connection::open(&next_path).unwrap();
    connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;").unwrap();
    let rows: i64 = connection.query_row("SELECT COUNT(*) FROM t", [], |r| r.get(0)).unwrap();
    assert!(rows > 0, "the copied WAL lost its rows");
    let opened = std::fs::metadata(&next_wal).unwrap().len();
    assert_eq!(opened, left, "the next open found another WAL than the one left");
    let _durability = WalDurability::attach(&connection, &next_path, None, false);
    // A quiet daemon: a small commit now and then, and no flush request.
    // The deadline only ends a run in which the WAL is never cut.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut commits = 0;
    let now = loop {
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        commits += 1;
        let len = std::fs::metadata(&next_wal).map_or(0, |meta| meta.len());
        if len <= WAL_SIZE_LIMIT_BYTES || Instant::now() > deadline {
            break len;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    println!(
        "wal_left: left_bytes={left} commits={commits} wal_file_bytes={now} \
         limit={WAL_SIZE_LIMIT_BYTES}"
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        now <= WAL_SIZE_LIMIT_BYTES,
        "a WAL left at {left} bytes is {now} bytes after {commits} small commits in 30 s \
         of the next open; the limit is {WAL_SIZE_LIMIT_BYTES}"
    );
}

#[test]
fn a_long_read_in_a_commit_storm_never_holds_a_commit_and_the_wal_is_cut_after_it() {
    // A whole-session snapshot read keeps one read transaction open on
    // its own connection for its full build. It pins the WAL: no
    // checkpoint copies past its mark. Commits must not wait for it.
    let (dir, connection) = database("long-read");
    let path = dir.join("r.sqlite");
    let wal = dir.join("r.sqlite-wal");
    let durability = WalDurability::attach(&connection, &path, None, false);
    rewrite_the_row(&connection, &durability, 0);
    let reader = Connection::open(&path).unwrap();
    reader.execute_batch("BEGIN").unwrap();
    let _: i64 = reader.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    let before = durability.wal_frame_bytes();
    let mut commits = 0u64;
    let mut slowest = Duration::ZERO;
    while durability.wal_frame_bytes() - before < 2 * WAL_SIZE_LIMIT_BYTES {
        commits += 1;
        let started = Instant::now();
        rewrite_the_row(&connection, &durability, commits);
        slowest = slowest.max(started.elapsed());
        assert!(commits < 100_000, "{commits} commits wrote under two limits of frames");
    }
    let (waits, longest) = durability.restart_waits();
    let pinned = std::fs::metadata(&wal).unwrap().len();
    reader.execute_batch("COMMIT").unwrap();
    println!(
        "wal_long_read: commits={commits} wal_file_bytes_pinned={pinned} restart_waits={waits} \
         longest_wait_ms={} slowest_commit_ms={}",
        longest.as_millis(),
        slowest.as_millis()
    );
    assert!(pinned > WAL_SIZE_LIMIT_BYTES, "the reader did not pin the WAL: {pinned} bytes");
    // One try per step past the limit, never one per commit.
    let tries = 2 * WAL_SIZE_LIMIT_BYTES / CHECKPOINT_BYTES;
    assert!(
        (1..=tries).contains(&waits),
        "{waits} of {commits} commits waited for a restart checkpoint; at most {tries}"
    );
    // The read lasted the whole storm; a wait ends with its checkpoint.
    assert!(
        longest < 2 * RESTART_WAIT,
        "a commit waited {longest:?} behind a long read; the limit is {RESTART_WAIT:?}"
    );
    // The read ended: answered requests go on and the WAL is cut.
    let deadline = Instant::now() + Duration::from_secs(10);
    let after = loop {
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        durability.request_flush();
        let len = std::fs::metadata(&wal).map_or(0, |meta| meta.len());
        if len <= WAL_SIZE_LIMIT_BYTES || Instant::now() > deadline {
            break len;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        after <= WAL_SIZE_LIMIT_BYTES,
        "the WAL stayed at {after} bytes after the long read ended ({pinned} while pinned)"
    );
}

#[test]
fn a_wal_left_over_the_limit_is_cut_in_a_commit_storm_from_the_first_moment() {
    // The next daemon restores: it commits with no pause from its start.
    let (dir, connection) = database("left-storm");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    let left = grow_a_pinned_wal(&path, &connection, &durability);
    let next = dir.join("next");
    std::fs::create_dir_all(&next).unwrap();
    let next_path = next.join("r.sqlite");
    let next_wal = next.join("r.sqlite-wal");
    std::fs::copy(&path, &next_path).unwrap();
    std::fs::copy(dir.join("r.sqlite-wal"), &next_wal).unwrap();
    drop(connection);

    let connection = Connection::open(&next_path).unwrap();
    connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;").unwrap();
    let durability = WalDurability::attach(&connection, &next_path, None, false);
    // The first commit also counts the frames the previous run left.
    rewrite_the_row(&connection, &durability, 0);
    let before = durability.wal_frame_bytes();
    let mut commits = 0u64;
    // The WAL is cut once the syncer copied what the previous run left
    // (commits do not wait for that copy) and one more commit came. The
    // deadline only ends a run in which that never happens.
    let deadline = Instant::now() + Duration::from_secs(30);
    let (written, high_water, now) = loop {
        commits += 1;
        rewrite_the_row(&connection, &durability, commits);
        let written = durability.wal_frame_bytes().saturating_sub(before);
        let (len, high_water) = durability.wal_file_bytes();
        if len <= WAL_SIZE_LIMIT_BYTES || Instant::now() > deadline {
            break (written, high_water, len);
        }
    };
    println!(
        "wal_left_storm: left_bytes={left} commits={commits} frame_bytes={written} \
         wal_file_high_water_bytes={high_water} wal_file_bytes={now} limit={WAL_SIZE_LIMIT_BYTES}"
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        now <= WAL_SIZE_LIMIT_BYTES,
        "a WAL left at {left} bytes is {now} bytes after {commits} commits with no pause \
         ({written} bytes of frames, 30 s) of the next open"
    );
}

#[test]
fn a_clean_stop_copies_a_small_wal_into_the_database() {
    let (dir, connection) = database("stop");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    connection.execute("INSERT INTO t VALUES (?1)", [vec![7u8; 1024 * 1024]]).unwrap();
    let before = std::fs::metadata(&path).unwrap().len();
    assert!(before < 1024 * 1024, "the database file already holds the row: {before} bytes");
    durability.checkpoint_at_stop();
    // The stop waits for the checkpoint only up to its limit; on a busy
    // disk the copy ends a little later.
    let deadline = Instant::now() + Duration::from_secs(30);
    let after = loop {
        let len = std::fs::metadata(&path).unwrap().len();
        if len > 1024 * 1024 || Instant::now() > deadline {
            break len;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(after > 1024 * 1024, "the database file is {after} bytes after the stop");
}
