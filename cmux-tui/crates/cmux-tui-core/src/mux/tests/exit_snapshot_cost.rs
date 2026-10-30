//! A terminal's exit snapshot reads its own tabs, not the whole topology.
//!
//! Lawrence 2026-10-29: after a reboot every host is gone, and adoption
//! records each terminal's end. Each record loaded the full resource
//! topology to find one terminal's tabs, so adoption grew with
//! lost terminals x topology (1.5 s of 2.8 s for 462 losses on a nightly
//! registry). Counted in SQLite VM steps, which are deterministic.

use std::sync::atomic::{AtomicU64, Ordering};

use super::*;

fn exit_snapshot_steps(mux: &Arc<Mux>, terminal_id: &str) -> u64 {
    let steps = Arc::new(AtomicU64::new(0));
    let counter = steps.clone();
    // Lock order: registry, then connection (pinned for the call), then state.
    let registry = mux.workspace_registry.lock().unwrap();
    let connection = mux.registry_connection.get();
    connection
        .progress_handler(
            16,
            Some(move || {
                counter.fetch_add(16, Ordering::Relaxed);
                false
            }),
        )
        .unwrap();
    let state = mux.state.lock().unwrap();
    let snapshot = terminal_exit_snapshot_in_state(&registry, &state, terminal_id).unwrap();
    drop(state);
    connection.progress_handler(0, None::<fn() -> bool>).unwrap();
    assert_eq!(snapshot["tab_ids"].as_array().map(Vec::len), Some(1), "{snapshot}");
    steps.load(Ordering::Relaxed)
}

#[cfg(unix)]
#[test]
fn exit_snapshot_cost_does_not_grow_with_other_workspaces() {
    const TERMINAL: &str = "0000000000004000800000000000005c";
    const INCARNATION: &str = "1000000000004000800000000000005c";
    const OTHERS: usize = 60;
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-exit-snapshot-cost-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = Mux::open_persistent("exit-snapshot-cost", SurfaceOptions::default(), &root).unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let alone = exit_snapshot_steps(&mux, TERMINAL);
    for index in 0..OTHERS {
        mux.create_empty_workspace(Some(format!("other-{index}")), None, None).unwrap();
    }
    let crowded = exit_snapshot_steps(&mux, TERMINAL);
    assert!(
        crowded.saturating_sub(alone) < 256,
        "one terminal's exit snapshot reads the whole topology: {alone} -> {crowded} VM \
         steps with {OTHERS} more workspaces"
    );
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
