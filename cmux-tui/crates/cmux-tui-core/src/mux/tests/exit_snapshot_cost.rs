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

/// The startup prefetch warms the index pages a lost terminal's end writes
/// (Lawrence 2026-10-30: 60% of a reboot's adoption was cold reads of
/// those pages). Every journal subject and terminal event an end appends is
/// one the prefetch reads first; a new subject kind an end starts writing
/// must be added to the prefetch.
#[cfg(unix)]
#[test]
fn startup_prefetch_covers_every_page_a_terminal_end_writes() {
    use crate::workspace_registry::terminal_end_prefetch::terminal_end_prefetch_keys;

    const TERMINAL: &str = "0000000000004000800000000000005d";
    const INCARNATION: &str = "1000000000004000800000000000005d";
    let root = std::env::temp_dir()
        .join(format!("cmux-mux-end-prefetch-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = Mux::open_persistent("end-prefetch", SurfaceOptions::default(), &root).unwrap();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let (keys, journal_head, event_head) = {
        let _registry = mux.workspace_registry.lock().unwrap();
        let connection = mux.registry_connection.get();
        let keys = terminal_end_prefetch_keys(&connection).unwrap();
        let journal_head: i64 = connection
            .query_row("SELECT COALESCE(MAX(sequence), 0) FROM session_journal", [], |row| {
                row.get(0)
            })
            .unwrap();
        let event_head: i64 = connection
            .query_row("SELECT COALESCE(MAX(revision), 0) FROM terminal_events", [], |row| {
                row.get(0)
            })
            .unwrap();
        (keys, journal_head, event_head)
    };

    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1_234,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());

    let written = {
        let _registry = mux.workspace_registry.lock().unwrap();
        let connection = mux.registry_connection.get();
        let mut statement = connection
            .prepare(
                "SELECT kind, id FROM journal_subject_index
                 WHERE sequence > ?1 AND kind IN ('terminal', 'tab', 'pane', 'screen', 'workspace')
                 UNION SELECT 'terminal_events', terminal_id FROM terminal_events
                 WHERE revision > ?2",
            )
            .unwrap();
        statement
            .query_map([journal_head, event_head], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    assert!(
        written.iter().any(|(kind, _)| kind == "terminal"),
        "the end appended no terminal subject: {written:?}"
    );
    let missing = written.iter().filter(|key| !keys.contains(key)).collect::<Vec<_>>();
    assert!(missing.is_empty(), "the end writes pages the prefetch never reads: {missing:?}");
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
