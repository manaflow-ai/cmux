//! A daemon start on a registry at the current schema writes nothing and
//! copies nothing of the WAL the previous run left (REGISTRY WAL, PR 2b:
//! the start path).
//!
//! The start step `registry.schema` took 988 to 1009 ms of a 1262 ms start
//! with a 64 MiB WAL at rest, and 5.5 to 18.9 s with a WAL of 426 to 545 MB:
//! the open committed on every start (an index dropped and made again), and
//! that commit ran SQLite's automatic checkpoint, which copied the whole WAL
//! into the database on the starting thread. The start time followed the
//! size of the WAL, not of the database.
//!
//! The test builds a session in a real `Mux` on an on-disk registry while a
//! second connection holds a read snapshot (so no checkpoint copies the
//! WAL), stops the daemon, and opens the registry again. At each step of
//! the open it reads the WAL's frame count and the count of frames copied
//! into the database from the wal-index (`-shm`, SQLite file format 4.5),
//! on the opening thread. Counts, not times. Arms: 1, 60 and 826 workspaces.
//!
//! Three rules: the open copies 0 frames; its schema step (`registry.schema`,
//! all a registry at the current schema needs) commits 0 frames; the rest of
//! the open commits at most [`CATCH_UP_FRAMES`], whatever the session's size
//! (the retention marks move past the rows the last run wrote).

use std::cell::RefCell;
use std::io::Read;
use std::rc::Rc;

use super::*;
use crate::workspace_registry::WORKSPACE_REGISTRY_FILE;

/// Renames after the build: with them, each arm leaves more WAL frames than
/// SQLite's automatic checkpoint needs (1000).
const LEFT_CHANGES: usize = 100;
/// The last step of the open on the opening thread. The WAL syncer starts
/// after it, and copies the left WAL on its own thread.
const LAST_OPEN_STEP: &str = "registry.resource_invariants";
/// The step that makes the schema of a registry at the current version.
const SCHEMA_STEP: &str = "registry.schema";
/// WAL frames the whole open may commit: a few pages of `meta`, not a count
/// that grows with the session or with the left WAL.
const CATCH_UP_FRAMES: u32 = 16;
const WAL_HEADER_BYTES: u64 = 32;
const WAL_FRAME_HEADER_BYTES: u64 = 24;

/// The wal-index header's `mxFrame` (valid frames in the WAL) and
/// `nBackfill` (frames a checkpoint copied into the database).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct WalIndex {
    frames: u32,
    copied: u32,
}

fn side_file(db_path: &Path, suffix: &str) -> std::path::PathBuf {
    let mut path = db_path.as_os_str().to_owned();
    path.push(suffix);
    std::path::PathBuf::from(path)
}

fn wal_index(db_path: &Path) -> WalIndex {
    let mut bytes = [0u8; 100];
    std::fs::File::open(side_file(db_path, "-shm")).unwrap().read_exact(&mut bytes).unwrap();
    let word =
        |at: usize| u32::from_ne_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]]);
    WalIndex { frames: word(16), copied: word(96) }
}

/// The wal-index once the stopped daemon's threads are gone: two equal
/// reads 100 ms apart.
fn settled_wal_index(db_path: &Path) -> WalIndex {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = wal_index(db_path);
    loop {
        std::thread::sleep(Duration::from_millis(100));
        let now = wal_index(db_path);
        if now == last || Instant::now() > deadline {
            return now;
        }
        last = now;
    }
}

fn a_start_on_a_current_registry_leaves_the_left_wal_alone(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-start-log-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "start-log";
    let mux = open_persistent_test_mux(session, &root);
    // The worker would checkpoint and seal on its own ticks, which commit.
    mux.stop_journal_maintenance();
    let db_path = std::fs::read_dir(&root)
        .unwrap()
        .map(|entry| entry.unwrap().path().join(WORKSPACE_REGISTRY_FILE))
        .find(|path| path.is_file())
        .expect("the registry file");
    // A read snapshot from before the build: no checkpoint copies past it,
    // so the daemon leaves every frame of the build in the WAL. The open
    // connection also keeps SQLite from removing the WAL at the clean stop.
    let pin = rusqlite::Connection::open(&db_path).unwrap();
    pin.execute_batch("BEGIN").unwrap();
    let _: i64 = pin.query_row("SELECT COUNT(*) FROM meta", [], |row| row.get(0)).unwrap();
    let page_bytes: i64 = pin.query_row("PRAGMA page_size", [], |row| row.get(0)).unwrap();
    let page_bytes = u64::try_from(page_bytes).unwrap();

    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.request_registry_flush();
    for index in 1..workspaces {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
        mux.request_registry_flush();
    }
    let target = mux.with_state(|state| state.workspaces[0].id);
    for change in 0..LEFT_CHANGES {
        assert!(mux.rename_workspace(target, format!("left {change}")), "rename {change}");
        mux.request_registry_flush();
    }
    mux.shutdown();
    drop(mux);
    // The snapshot ends; the connection stays, without a transaction.
    pin.execute_batch("COMMIT").unwrap();

    let before = settled_wal_index(&db_path);
    let wal_bytes = std::fs::metadata(side_file(&db_path, "-wal")).unwrap().len();
    let frame_bytes = page_bytes + WAL_FRAME_HEADER_BYTES;
    assert!(
        before.frames > 1000
            && before.copied < before.frames
            && WAL_HEADER_BYTES + u64::from(before.frames) * frame_bytes <= wal_bytes,
        "the wal-index {before:?} does not describe a left WAL of {wal_bytes} bytes \
         ({frame_bytes} bytes a frame)"
    );

    let steps: Rc<RefCell<Vec<(&'static str, WalIndex)>>> = Rc::default();
    let seen = steps.clone();
    crate::startup_timings::observe_laps_on_this_thread(Some(Box::new(move |step| {
        seen.borrow_mut().push((step, wal_index(&db_path)));
    })));
    let started = Instant::now();
    let registry = WorkspaceRegistry::open(&root, session);
    let open_ms = started.elapsed().as_secs_f64() * 1000.0;
    crate::startup_timings::observe_laps_on_this_thread(None);
    let registry = registry.unwrap();

    // The steps that changed the WAL or copied it, up to the last step of
    // the opening thread (later steps run beside the syncer's own copy).
    let mut at_end = None;
    let mut schema_step = None;
    let mut changed = Vec::new();
    let mut last = before;
    for (step, index) in steps.borrow().iter() {
        if *step == SCHEMA_STEP {
            schema_step = Some((last, *index));
        }
        if *index != last {
            changed.push(format!(
                "{step}: frames {} -> {}, copied {} -> {}",
                last.frames, index.frames, last.copied, index.copied
            ));
            last = *index;
        }
        if *step == LAST_OPEN_STEP {
            at_end = Some(*index);
            break;
        }
    }
    println!(
        "registry_start_log: workspaces={workspaces} wal_bytes={wal_bytes} wal_frames={} \
         wal_frames_copied={} open_ms={open_ms:.1} at_end_of_open={at_end:?} \
         steps_that_wrote={changed:?}",
        before.frames, before.copied
    );
    drop(registry);
    drop(pin);
    let _ = std::fs::remove_dir_all(&root);
    let at_end = at_end.expect("the open reached its last step");
    let (schema_before, schema_after) = schema_step.expect("the open ran its schema step");
    let committed = at_end.frames.checked_sub(before.frames);
    assert!(
        at_end.copied == before.copied
            && schema_after == schema_before
            && committed.is_some_and(|frames| frames <= CATCH_UP_FRAMES),
        "the open of a current registry of {workspaces} workspaces with a left WAL of \
         {wal_bytes} bytes took {open_ms:.1} ms: it must copy 0 frames on the opening thread, \
         commit 0 frames in {SCHEMA_STEP} and at most {CATCH_UP_FRAMES} in all, but the WAL \
         went from {} to {} frames and the copied frames from {} to {}; steps that wrote: \
         {changed:?}",
        before.frames,
        at_end.frames,
        before.copied,
        at_end.copied,
    );
}

#[cfg(unix)]
#[test]
fn a_start_on_a_current_registry_leaves_the_left_wal_alone_on_1_workspace() {
    a_start_on_a_current_registry_leaves_the_left_wal_alone(1);
}

#[cfg(unix)]
#[test]
fn a_start_on_a_current_registry_leaves_the_left_wal_alone_on_60_workspaces() {
    a_start_on_a_current_registry_leaves_the_left_wal_alone(60);
}

#[cfg(unix)]
#[test]
fn a_start_on_a_current_registry_leaves_the_left_wal_alone_on_826_workspaces() {
    a_start_on_a_current_registry_leaves_the_left_wal_alone(826);
}
