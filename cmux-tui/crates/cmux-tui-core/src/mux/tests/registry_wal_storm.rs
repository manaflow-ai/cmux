//! A commit storm keeps the registry's WAL file under its bound
//! (REGISTRY WAL, PR 2: the log restart rule).
//!
//! A session build, a restore or an agent burst changes the session with no
//! pause. One daemon built a session of 826 workspaces (about 4000 changes in
//! 53 to 160 s) and left a `workspace-registry.sqlite3-wal` of 864 to 1366 MB
//! beside a 45 MB database: the WAL syncer's PASSIVE checkpoints ran beside
//! the commits, so none of them ended with every frame copied, the WAL never
//! restarted from its first frame, and `journal_size_limit` never cut it.
//!
//! The test runs a real `Mux` on an on-disk registry, renames one workspace
//! with no pause until the commits wrote three times the size limit in WAL
//! frames, asks for a flush after each change as the server's reply funnel
//! does, and reads the WAL file's high-water mark from `write_path` stats.
//! Bytes, not times. Arms: 1, 60 and 826 workspaces (the session size rule).

use super::*;
use crate::workspace_registry::WORKSPACE_REGISTRY_FILE;
use crate::workspace_registry::wal_durability::{WAL_SIZE_LIMIT_BYTES, wal_index_frames};

/// WAL frame bytes the storm writes: the limit three times.
const STORM_FRAME_BYTES: u64 = 3 * WAL_SIZE_LIMIT_BYTES;
/// The WAL file's bound this test asserts: the limit and 4 MiB, the step to
/// the next try when a reader of another thread stopped one checkpoint. The
/// syncer starts a try at a quarter of the limit.
const WAL_FILE_BOUND_BYTES: u64 = WAL_SIZE_LIMIT_BYTES + 4 * 1024 * 1024;
/// A storm that needs more changes than this writes too little per change
/// for this test: it then says so and does not pass.
const MAX_CHANGES: u64 = 50_000;

fn a_change_storm_keeps_the_wal_file_under_its_bound(workspaces: usize) {
    let root = std::env::temp_dir()
        .join(format!("cmux-wal-storm-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("wal-storm", &root);
    // The worker would checkpoint and seal on its own ticks, which commit.
    mux.stop_journal_maintenance();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.request_registry_flush();
    for index in 1..workspaces {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
        mux.request_registry_flush();
    }
    let target = mux.with_state(|state| state.workspaces[0].id);
    let built = mux.write_path_stats();

    let started = Instant::now();
    let mut changes = 0;
    let written = loop {
        assert!(mux.rename_workspace(target, format!("storm {changes}")), "rename {changes}");
        // Each answered request asks for a flush (`server/connection_frame.rs`).
        mux.request_registry_flush();
        changes += 1;
        let written =
            mux.write_path_stats().registry_wal_frame_bytes - built.registry_wal_frame_bytes;
        if written >= STORM_FRAME_BYTES || changes >= MAX_CHANGES {
            break written;
        }
    };
    let seconds = started.elapsed().as_secs_f64();
    let after = mux.write_path_stats();
    let tries = mux.registry_connection.wal_restart_tries_for_test();
    let holds = mux.registry_connection.wal_restart_holds_for_test();
    let longest_hold = holds.iter().map(|(from, to)| *to - *from).max().unwrap_or_default();
    println!(
        "registry_wal_storm: workspaces={workspaces} changes={changes} seconds={seconds:.1} \
         wal_frame_bytes={written} wal_file_bytes_after_build={} wal_file_bytes={} \
         wal_file_high_water_bytes={} bound={WAL_FILE_BOUND_BYTES} restart_tries={tries} \
         lock_holds={} longest_hold_ms={}",
        built.registry_wal_file_bytes,
        after.registry_wal_file_bytes,
        after.registry_wal_file_high_water_bytes,
        holds.len(),
        longest_hold.as_millis(),
    );
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        written >= STORM_FRAME_BYTES,
        "{changes} renames wrote only {written} bytes of WAL frames: not a storm of \
         {STORM_FRAME_BYTES} bytes"
    );
    // One try of the syncer per restart (each 16 MiB of the build and the
    // storm), with room for tries a reader of another thread made miss (the
    // next comes 4 MiB on). Never one per change, and no change waits for one.
    assert!(tries <= 96, "{tries} tries of the WAL restart rule for {changes} changes");
    assert!(
        after.registry_wal_file_high_water_bytes <= WAL_FILE_BOUND_BYTES,
        "{changes} changes with no pause ({written} bytes of WAL frames) on {workspaces} \
         workspaces grew the registry's WAL file to {} bytes; the bound is \
         {WAL_FILE_BOUND_BYTES}",
        after.registry_wal_file_high_water_bytes,
    );
}

#[cfg(unix)]
#[test]
fn a_change_storm_keeps_the_wal_file_under_its_bound_on_1_workspace() {
    a_change_storm_keeps_the_wal_file_under_its_bound(1);
}

#[cfg(unix)]
#[test]
fn a_change_storm_keeps_the_wal_file_under_its_bound_on_60_workspaces() {
    a_change_storm_keeps_the_wal_file_under_its_bound(60);
}

#[cfg(unix)]
#[test]
fn a_change_storm_keeps_the_wal_file_under_its_bound_on_826_workspaces() {
    a_change_storm_keeps_the_wal_file_under_its_bound(826);
}

#[cfg(unix)]
#[test]
fn a_clean_stop_copies_the_registrys_wal_into_the_database() {
    // `Mux::shutdown` ends with one checkpoint of the registry's WAL, so
    // the next start finds every commit in the database file. A small WAL:
    // no checkpoint ran before the stop.
    let root = std::env::temp_dir()
        .join(format!("cmux-wal-stop-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("wal-stop", &root);
    mux.stop_journal_maintenance();
    mux.new_workspace(None, Some((80, 24))).unwrap();
    let target = mux.with_state(|state| state.workspaces[0].id);
    for change in 0..8 {
        assert!(mux.rename_workspace(target, format!("stop {change}")), "rename {change}");
    }
    let database = std::fs::read_dir(&root)
        .unwrap()
        .map(|entry| entry.unwrap().path().join(WORKSPACE_REGISTRY_FILE))
        .find(|path| path.exists())
        .expect("the registry database");
    let (frames_before, copied_before) = wal_index_frames(&database);
    mux.shutdown();
    let (frames, copied) = wal_index_frames(&database);
    println!(
        "registry_wal_stop: wal_frames_before={frames_before} copied_before={copied_before} \
         wal_frames={frames} copied={copied}"
    );
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        copied_before < frames_before,
        "the WAL was already copied before the stop ({copied_before} of {frames_before} frames)"
    );
    assert_eq!(copied, frames, "the stop copied {copied} of {frames} WAL frames");
}
