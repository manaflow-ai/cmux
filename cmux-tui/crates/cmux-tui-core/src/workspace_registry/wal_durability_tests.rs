use super::*;

fn database(name: &str) -> (PathBuf, Connection) {
    let dir = std::env::temp_dir().join(format!("wal-durability-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("r.sqlite");
    let connection = Connection::open(&path).unwrap();
    connection
        .execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE t(v);")
        .unwrap();
    (dir, connection)
}

#[test]
fn every_commit_is_counted_and_flushed() {
    let (dir, connection) = database("count");
    let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
    connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
    connection.execute("INSERT INTO t VALUES (2)", []).unwrap();
    durability.wait_durable();
    assert_eq!(durability.counts(), (2, 2));
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn each_commit_counts_the_wal_frame_bytes_it_appended() {
    let (dir, connection) = database("frame-bytes");
    let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
    let page: i64 = connection.query_row("PRAGMA page_size", [], |row| row.get(0)).unwrap();
    let page = u64::try_from(page).unwrap();
    let frame = page + WAL_FRAME_HEADER_BYTES;
    // The first counted commit also counts the frames already in the WAL (here the CREATE TABLE): a reader
    // takes differences.
    connection.execute("INSERT INTO t VALUES (0)", []).unwrap();
    let base = durability.wal_frame_bytes();
    connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
    let small = durability.wal_frame_bytes() - base;
    assert!(
        small >= frame && small <= 3 * frame,
        "a one-row commit appended {small} bytes ({frame} per frame)"
    );
    // A 256 KiB value: overflow pages, so at least its size in frames.
    connection.execute("INSERT INTO t VALUES (?1)", [vec![7u8; 256 * 1024]]).unwrap();
    let large = durability.wal_frame_bytes() - base - small;
    assert!(
        large >= 256 * 1024 && large <= 256 * 1024 + 16 * frame,
        "a 256 KiB commit appended {large} bytes"
    );
    // The same small commit again appends about what the first one did, not the WAL so far.
    let before = durability.wal_frame_bytes();
    connection.execute("INSERT INTO t VALUES (2)", []).unwrap();
    let again = durability.wal_frame_bytes() - before;
    assert!(again >= frame && again <= 3 * frame, "a second one-row commit appended {again} bytes");
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn an_answered_request_syncs_nothing_until_a_checkpoint_or_close() {
    let (dir, connection) = database("share");
    let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
    for value in 0..5 {
        connection.execute("INSERT INTO t VALUES (?1)", [value]).unwrap();
    }
    durability.request_flush();
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(durability.counts(), (5, 0), "a small WAL was synced after a reply");
    durability.wait_durable();
    assert_eq!(durability.counts(), (5, 5));
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_commit_does_not_wait_for_a_slow_flush() {
    let (dir, connection) = database("slow");
    let durability = WalDurability::attach(
        &connection,
        &dir.join("r.sqlite"),
        Some(Duration::from_millis(300)),
        false,
    );
    let started = std::time::Instant::now();
    connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
    assert!(started.elapsed() < Duration::from_millis(100));
    durability.wait_durable();
    assert!(started.elapsed() >= Duration::from_millis(300));
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_syncer_checkpoints_a_large_wal_and_commits_never_do() {
    let (dir, connection) = database("checkpoint");
    let durability = WalDurability::attach(&connection, &dir.join("r.sqlite"), None, false);
    let blob = vec![7u8; 64 * 1024];
    for _ in 0..100 {
        connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
    }
    // A reply is out: the syncer looks at the WAL and checkpoints it.
    durability.request_flush();
    // The checkpoint follows the flush on the syncer thread.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let db_len = loop {
        let db_len = std::fs::metadata(dir.join("r.sqlite")).unwrap().len();
        if db_len > 4 * 1024 * 1024 || std::time::Instant::now() > deadline {
            break db_len;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(db_len > 4 * 1024 * 1024, "the database file is {db_len} bytes: no checkpoint ran");
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

/// SQLite keeps the WAL file's size when the WAL restarts from its first
/// frame (it cuts the file back only to `journal_size_limit`, 64 MiB), so
/// a WAL that passed the checkpoint size once kept a file above it for
/// good, and the syncer, which read the file's size, ran a checkpoint
/// (two fsyncs and a copy into the database) after every answered
/// request. One 10.8 GB registry: about 0.36 MiB written per commit that
/// appended about 60 KB of frames, 1,881 commits in ten minutes
/// (2026-11-12).
#[test]
fn a_wal_file_that_kept_its_size_is_not_checkpointed_after_every_request() {
    let (dir, connection) = database("kept-size");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    // 8 MiB of commits: the WAL passes the checkpoint size once.
    let blob = vec![7u8; 64 * 1024];
    for _ in 0..128 {
        connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
    }
    let large = durability.checkpoints_after_flush();
    assert!(large >= 1, "a WAL of 8 MiB was not checkpointed");
    // The next commit restarts the WAL from its first frame; the file keeps its size.
    connection.execute("INSERT INTO t VALUES (0)", []).unwrap();
    let file = std::fs::metadata(dir.join("r.sqlite-wal")).unwrap().len();
    assert!(file > CHECKPOINT_BYTES, "the restarted WAL file is {file} bytes");
    // 100 answered requests of one small commit each: well under 4 MiB of frames.
    for value in 1..=100 {
        connection.execute("INSERT INTO t VALUES (?1)", [value]).unwrap();
        durability.checkpoints_after_flush();
    }
    let ran = durability.checkpoints_after_flush() - large;
    assert!(
        ran <= 1,
        "100 one-row requests ran {ran} checkpoints of a WAL that held under 4 MiB of \
             frames (its file kept {file} bytes)"
    );
    // A WAL that fills again is still checkpointed.
    for _ in 0..128 {
        connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
    }
    let again = durability.checkpoints_after_flush() - large - ran;
    assert!(again >= 1, "a WAL that filled again was not checkpointed");
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Commits about one and a half [`WAL_SIZE_LIMIT_BYTES`] while a reader
/// holds its snapshot, as a long read of the registry does: no checkpoint
/// can copy past it. Returns the pinned WAL's size after the reader ended.
fn grow_a_pinned_wal(path: &Path, connection: &Connection, durability: &WalDurability) -> u64 {
    let reader = Connection::open(path).unwrap();
    reader.execute_batch("BEGIN").unwrap();
    let _: i64 = reader.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
    let blob = vec![7u8; 64 * 1024];
    let commits = (WAL_SIZE_LIMIT_BYTES * 3 / 2) / blob.len() as u64;
    for commit in 0..commits {
        connection.execute("INSERT INTO t VALUES (?1)", [&blob]).unwrap();
        if commit % 64 == 0 {
            durability.request_flush();
        }
    }
    durability.wait_durable();
    reader.execute_batch("COMMIT").unwrap();
    let mut wal = path.as_os_str().to_owned();
    wal.push("-wal");
    let pinned = std::fs::metadata(PathBuf::from(wal)).unwrap().len();
    assert!(pinned > WAL_SIZE_LIMIT_BYTES, "the pinned WAL is only {pinned} bytes");
    pinned
}

#[test]
fn a_wal_a_reader_pinned_shrinks_under_the_limit_once_the_reader_is_gone() {
    let (dir, connection) = database("pinned");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    let wal = dir.join("r.sqlite-wal");
    let pinned = grow_a_pinned_wal(&path, &connection, &durability);
    // Answered requests go on: the syncer checkpoints the whole WAL, and
    // the next commit restarts it and cuts the file to the limit.
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let after = loop {
        connection.execute("INSERT INTO t VALUES (1)", []).unwrap();
        durability.request_flush();
        let len = std::fs::metadata(&wal).map_or(0, |meta| meta.len());
        if len <= WAL_SIZE_LIMIT_BYTES || std::time::Instant::now() > deadline {
            break len;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(
        after <= WAL_SIZE_LIMIT_BYTES,
        "the WAL stayed at {after} bytes after its reader ended ({pinned} while pinned)"
    );
    let (now, high_water) = durability.wal_file_bytes();
    assert_eq!(now, after);
    assert!(high_water >= pinned, "a high-water mark of {high_water} bytes, {pinned} pinned");
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_transaction_that_reads_then_writes_never_gets_busy_while_the_syncer_checkpoints() {
    // A request transaction reads, then writes (an idle policy update).
    // The upgrade to a writer does not wait for a busy timeout: a
    // checkpoint that held the writer lock while it waited for this
    // transaction's read would fail the write at once.
    let (dir, connection) = database("read-then-write");
    let path = dir.join("r.sqlite");
    let durability = WalDurability::attach(&connection, &path, None, false);
    connection.busy_timeout(Duration::from_secs(5)).unwrap();
    grow_a_pinned_wal(&path, &connection, &durability);
    let wal = dir.join("r.sqlite-wal");
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut rounds = 0;
    while std::time::Instant::now() < deadline {
        durability.request_flush();
        let tx = connection.unchecked_transaction().unwrap();
        let _: i64 = tx.query_row("SELECT COUNT(*) FROM t", [], |row| row.get(0)).unwrap();
        std::thread::sleep(Duration::from_millis(10));
        if let Err(error) = tx.execute("INSERT INTO t VALUES (2)", []) {
            panic!("round {rounds}: the write after a read failed: {error}");
        }
        tx.commit().unwrap();
        rounds += 1;
        if rounds >= 20
            && std::fs::metadata(&wal).map_or(0, |meta| meta.len()) <= WAL_SIZE_LIMIT_BYTES
        {
            break;
        }
    }
    drop(connection);
    let _ = std::fs::remove_dir_all(&dir);
}
