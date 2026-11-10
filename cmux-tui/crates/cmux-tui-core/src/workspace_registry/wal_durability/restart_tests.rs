//! The WAL restart rule (`wal_durability` module docs): the WAL file's size
//! under commits with no pause, behind a long read, after a previous run
//! left it large, and at a clean stop. Bytes and counts, no times: the
//! syncer of a database attached in a test waits long for the writer lock
//! (`TEST_RESTART_WAIT`), so a try that did not get it is no race.

use std::sync::Arc;
use std::time::Instant;

use super::tests::{database, grow_a_pinned_wal};
use super::*;

/// The WAL file's bound under commits that this test asserts: the size
/// limit and one step between tries to restart it (far above one commit).
const STORM_WAL_BOUND_BYTES: u64 = WAL_SIZE_LIMIT_BYTES + CHECKPOINT_BYTES;

/// The lock of a store in these tests: every commit runs under it, as a
/// registry commit runs under the registry's connection lock.
type StoreLock = Arc<parking_lot::Mutex<()>>;

/// The syncer's hold of a [`StoreLock`]; `wait`: it waits this long for the
/// lock in place of the database's own limit.
struct WeakStoreLock {
    lock: std::sync::Weak<parking_lot::Mutex<()>>,
    wait: Option<Duration>,
}

impl WriterLock for WeakStoreLock {
    fn exclude_commits(&self, deadline: Instant, tail: &mut dyn FnMut()) -> bool {
        let Some(lock) = self.lock.upgrade() else { return false };
        let deadline = self.wait.map_or(deadline, |wait| Instant::now() + wait);
        let Some(guard) = lock.try_lock_until(deadline) else { return false };
        tail();
        drop(guard);
        true
    }
}

/// Give `durability` the lock of its store, so its syncer runs the restart rule.
fn own_lock(durability: &WalDurability) -> StoreLock {
    let lock = Arc::new(parking_lot::Mutex::new(()));
    durability.own_restart(WeakStoreLock { lock: Arc::downgrade(&lock), wait: None });
    lock
}

/// One commit that rewrites the 64 KiB row 1 under the store's lock and,
/// like an answered request, asks for a flush. `round` makes each value new:
/// SQLite writes no page whose content did not change, so an equal value is
/// no commit at all.
fn rewrite_the_row(
    connection: &Connection,
    durability: &WalDurability,
    lock: &StoreLock,
    round: u64,
) {
    let blob = vec![u8::try_from(round % 251).unwrap_or(0); 64 * 1024];
    let held = lock.lock();
    connection.execute("INSERT OR REPLACE INTO t(rowid, v) VALUES (1, ?1)", [&blob]).unwrap();
    drop(held);
    durability.request_flush();
}

/// Commits `frame_bytes` of WAL frames with no pause between them
/// ([`rewrite_the_row`]). Returns the commit count.
fn commit_storm(
    connection: &Connection,
    durability: &WalDurability,
    lock: &StoreLock,
    frame_bytes: u64,
) -> u64 {
    rewrite_the_row(connection, durability, lock, 0);
    let before = durability.wal_frame_bytes();
    let mut commits = 0;
    while durability.wal_frame_bytes() - before < frame_bytes {
        commits += 1;
        rewrite_the_row(connection, durability, lock, commits);
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
    let lock = own_lock(&durability);
    let storm = 3 * WAL_SIZE_LIMIT_BYTES;
    let commits = commit_storm(&connection, &durability, &lock, storm);
    let (now, high_water) = durability.wal_file_bytes();
    let tries = durability.restart_tries();
    let holds = durability.restart_holds();
    let longest = holds.iter().map(|(from, to)| *to - *from).max().unwrap_or(Duration::ZERO);
    println!(
        "wal_storm: commits={commits} frame_bytes={storm} wal_file_bytes={now} \
         wal_file_high_water_bytes={high_water} bound={STORM_WAL_BOUND_BYTES} \
         restart_tries={tries} lock_holds={} longest_hold_ms={}",
        holds.len(),
        longest.as_millis()
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(
        high_water <= STORM_WAL_BOUND_BYTES,
        "{commits} commits with no pause ({storm} bytes of frames) grew the WAL file to \
         {high_water} bytes; the bound is {STORM_WAL_BOUND_BYTES}"
    );
    // The price: one hold of the store's lock per restart (three limits of
    // frames and a restart point of a quarter of a limit: about twelve),
    // never one per commit and at most one per step between two tries.
    assert!(
        (2..=storm / CHECKPOINT_BYTES).contains(&(holds.len() as u64)) && tries >= 2,
        "{} lock holds and {tries} tries for {commits} commits",
        holds.len()
    );
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
    let durability = WalDurability::attach(&connection, &next_path, None, false);
    let lock = own_lock(&durability);
    // A quiet daemon: a small commit now and then, and no flush request.
    // The deadline only ends a run in which the WAL is never cut.
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut commits = 0;
    let now = loop {
        let held = lock.lock();
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        drop(held);
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
    let lock = own_lock(&durability);
    rewrite_the_row(&connection, &durability, &lock, 0);
    let reader = Connection::open(&path).unwrap();
    reader.execute_batch("BEGIN").unwrap();
    let _: i64 = reader.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    let before = durability.wal_frame_bytes();
    let mut commits = 0u64;
    let mut slowest = Duration::ZERO;
    while durability.wal_frame_bytes() - before < 2 * WAL_SIZE_LIMIT_BYTES {
        commits += 1;
        let started = Instant::now();
        rewrite_the_row(&connection, &durability, &lock, commits);
        slowest = slowest.max(started.elapsed());
        assert!(commits < 100_000, "{commits} commits wrote under two limits of frames");
    }
    let tries = durability.restart_tries();
    let holds = durability.restart_holds().len();
    let pinned = std::fs::metadata(&wal).unwrap().len();
    reader.execute_batch("COMMIT").unwrap();
    println!(
        "wal_long_read: commits={commits} wal_file_bytes_pinned={pinned} restart_tries={tries} \
         lock_holds={holds} slowest_commit_ms={}",
        slowest.as_millis()
    );
    assert!(pinned > WAL_SIZE_LIMIT_BYTES, "the reader did not pin the WAL: {pinned} bytes");
    // One try per step past the restart point, never one per commit.
    let most = 2 * WAL_SIZE_LIMIT_BYTES / CHECKPOINT_BYTES;
    assert!(
        (1..=most).contains(&tries),
        "{tries} tries of the restart rule for {commits} commits; at most {most}"
    );
    // The read lasted the whole storm: each try's copy stopped at the
    // reader's mark, so no try took the store's lock from the commits.
    assert_eq!(holds, 0, "{holds} of {tries} tries behind a long read took the store's lock");
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
    let lock = own_lock(&durability);
    // The first commit also counts the frames the previous run left.
    rewrite_the_row(&connection, &durability, &lock, 0);
    let before = durability.wal_frame_bytes();
    let mut commits = 0u64;
    // The WAL is cut once the syncer copied what the previous run left
    // (commits do not wait for that copy) and one more commit came. The
    // deadline only ends a run in which that never happens.
    let deadline = Instant::now() + Duration::from_secs(30);
    let (written, high_water, now) = loop {
        commits += 1;
        rewrite_the_row(&connection, &durability, &lock, commits);
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

#[test]
fn a_try_ends_with_no_restart_while_another_thread_keeps_the_stores_lock() {
    // A flow holds the store's lock for longer than the syncer waits for
    // it. The try ends, no commit waited, and a later try restarts the WAL.
    let (dir, connection) = database("kept-lock");
    let path = dir.join("r.sqlite");
    let wal = dir.join("r.sqlite-wal");
    let durability = WalDurability::attach(&connection, &path, None, false);
    let kept = Arc::new(parking_lot::Mutex::new(()));
    // The syncer waits 50 ms for this lock; the test keeps it for the storm.
    let wait = Some(Duration::from_millis(50));
    durability.own_restart(WeakStoreLock { lock: Arc::downgrade(&kept), wait });
    let held = kept.lock();
    let blob = vec![7u8; 64 * 1024];
    let mut commits = 0u64;
    let mut slowest = Duration::ZERO;
    while durability.restart_tries() < 2 {
        commits += 1;
        let started = Instant::now();
        connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        slowest = slowest.max(started.elapsed());
        durability.request_flush();
        assert!(commits < 100_000, "{commits} commits and no second try");
    }
    let kept_bytes = std::fs::metadata(&wal).unwrap().len();
    let kept_holds = durability.restart_holds().len();
    drop(held);
    // The flow released the lock: the next tries get it.
    let deadline = Instant::now() + Duration::from_secs(30);
    let after = loop {
        let held = kept.lock();
        connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        drop(held);
        durability.request_flush();
        let len = std::fs::metadata(&wal).map_or(0, |meta| meta.len());
        if (len <= WAL_SIZE_LIMIT_BYTES && !durability.restart_holds().is_empty())
            || Instant::now() > deadline
        {
            break len;
        }
        std::thread::sleep(Duration::from_millis(1));
    };
    let holds = durability.restart_holds().len();
    println!(
        "wal_kept_lock: commits={commits} wal_file_bytes_kept={kept_bytes} holds_kept={kept_holds} \
         slowest_commit_ms={} holds={holds} wal_file_bytes={after}",
        slowest.as_millis()
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert_eq!(kept_holds, 0, "the syncer ran {kept_holds} tails while a flow kept the lock");
    assert!(
        holds >= 1 && after <= WAL_SIZE_LIMIT_BYTES,
        "after the flow released the lock: {holds} lock holds, a WAL of {after} bytes"
    );
}

/// The next open of a database whose previous run was killed and left a
/// WAL of valid frames: over the limit (a reader pinned it), or of two
/// checkpoint sizes. No commit and no flush request comes. Returns (frames
/// in the WAL, frames copied at the open, frames copied once the syncer's
/// start pass ended or 30 s passed).
fn the_start_pass_alone(name: &str, over_the_limit: bool) -> (u32, u32, u32) {
    let (dir, connection) = database(name);
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    if over_the_limit {
        grow_a_pinned_wal(&path, &connection, &durability);
    } else {
        // No flush request and a WAL under the limit: no checkpoint runs.
        let blob = vec![7u8; 64 * 1024];
        while durability.wal_frame_bytes() < 2 * CHECKPOINT_BYTES {
            connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        }
    }
    let left = std::fs::metadata(dir.join("r.sqlite-wal")).unwrap().len();
    let next = dir.join("next");
    std::fs::create_dir_all(&next).unwrap();
    let next_path = next.join("r.sqlite");
    std::fs::copy(&path, &next_path).unwrap();
    std::fs::copy(dir.join("r.sqlite-wal"), next.join("r.sqlite-wal")).unwrap();
    drop(connection);

    let connection = Connection::open(&next_path).unwrap();
    connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;").unwrap();
    let _: i64 = connection.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    let (frames, copied_at_open) = wal_index_frames(&next_path);
    let _durability = WalDurability::attach(&connection, &next_path, None, false);
    let deadline = Instant::now() + Duration::from_secs(30);
    let copied = loop {
        let (_, copied) = wal_index_frames(&next_path);
        if copied == frames || Instant::now() > deadline {
            break copied;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    println!(
        "wal_start_pass: left_bytes={left} wal_frames={frames} copied_at_open={copied_at_open} \
         copied={copied}"
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    (frames, copied_at_open, copied)
}

#[test]
fn a_wal_left_under_the_limit_is_copied_at_the_next_open_with_no_commit() {
    // Between the checkpoint size and the limit: the restart rule never
    // fires for it, and an idle daemon makes no commit and no request.
    let (frames, copied_at_open, copied) = the_start_pass_alone("left-8", false);
    assert!(frames > 1024 && copied_at_open == 0, "{copied_at_open} of {frames} at the open");
    assert_eq!(copied, frames, "the syncer copied {copied} of {frames} left frames in 30 s");
}

#[test]
fn a_wal_left_over_the_limit_is_copied_at_the_next_open_with_no_commit() {
    let (frames, copied_at_open, copied) = the_start_pass_alone("left-96", true);
    assert!(frames > 16 * 1024 && copied_at_open == 0, "{copied_at_open} of {frames} at the open");
    assert_eq!(copied, frames, "the syncer copied {copied} of {frames} left frames in 30 s");
}

#[test]
fn after_a_cut_the_syncer_checkpoints_by_what_commits_wrote_not_at_each_request() {
    // A cut leaves the WAL file at its limit for the rest of the run. The
    // syncer must then checkpoint once per `CHECKPOINT_BYTES` of new frames,
    // not once per answered request because the file is large.
    let (dir, connection) = database("rest");
    let path = dir.join("r.sqlite");
    let wal = dir.join("r.sqlite-wal");
    let durability = WalDurability::attach(&connection, &path, None, false);
    let lock = own_lock(&durability);
    commit_storm(&connection, &durability, &lock, 2 * WAL_SIZE_LIMIT_BYTES);
    // A try of the restart rule that the storm's last commits started ends
    // first; it is not a checkpoint of the rest.
    for _ in 0..2 {
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        durability.request_flush();
        durability.checkpoints_once_idle();
    }
    let file = std::fs::metadata(&wal).unwrap().len();
    let before = durability.checkpoints_once_idle();
    let tries_before = durability.restart_tries();
    let frames_before = durability.wal_frame_bytes();
    let commits = 200u64;
    for _ in 0..commits {
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        durability.request_flush();
        durability.checkpoints_once_idle();
    }
    let checkpoints = durability.checkpoints_once_idle() - before;
    // The small commits can take the WAL to its restart point: that try is
    // one more pass, and not a checkpoint of the rest.
    let tries = durability.restart_tries() - tries_before;
    let written = durability.wal_frame_bytes() - frames_before;
    println!(
        "wal_rest: wal_file_bytes={file} commits={commits} frame_bytes={written} \
         checkpoints={checkpoints}"
    );
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
    assert!(file > CHECKPOINT_BYTES, "the storm left a WAL file of only {file} bytes");
    assert!(written < CHECKPOINT_BYTES, "{commits} small commits wrote {written} bytes");
    // What the storm's last commits left may be one checkpoint size.
    assert!(
        tries <= 1 && checkpoints <= 1 + tries,
        "{checkpoints} checkpoints for {commits} small commits ({written} bytes of frames) at \
         rest after a cut; a checkpoint is due once per {CHECKPOINT_BYTES} bytes"
    );
}
