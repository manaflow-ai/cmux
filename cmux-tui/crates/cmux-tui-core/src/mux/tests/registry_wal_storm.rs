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
use crate::workspace_registry::wal_durability::WAL_SIZE_LIMIT_BYTES;

/// WAL frame bytes the storm writes: the limit three times.
const STORM_FRAME_BYTES: u64 = 3 * WAL_SIZE_LIMIT_BYTES;
/// The WAL file's bound: the limit, plus the 4 MiB step between two tries to
/// restart the WAL (far above one commit's frames).
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

    let started = std::time::Instant::now();
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
    println!(
        "registry_wal_storm: workspaces={workspaces} changes={changes} seconds={seconds:.1} \
         wal_frame_bytes={written} wal_file_bytes_after_build={} wal_file_bytes={} \
         wal_file_high_water_bytes={} bound={WAL_FILE_BOUND_BYTES}",
        built.registry_wal_file_bytes,
        after.registry_wal_file_bytes,
        after.registry_wal_file_high_water_bytes,
    );
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert!(
        written >= STORM_FRAME_BYTES,
        "{changes} renames wrote only {written} bytes of WAL frames: not a storm of \
         {STORM_FRAME_BYTES} bytes"
    );
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
