use super::super::*;

fn host_id(mux: &Arc<Mux>, surface: &Arc<Surface>) -> String {
    mux.resource_terminal_host_identity(surface).expect("test terminal is hosted").terminal_id
}

fn lifecycle(mux: &Arc<Mux>, terminal_id: &str) -> TerminalLifecycle {
    mux.resolve_terminal(terminal_id).unwrap().unwrap().terminal.lifecycle
}

/// Ending N terminals one close at a time rebuilt and committed the whole
/// session projection N times: O(N^2) teardown (1,000 terminals took
/// 147 s). The teardown is one projection and one commit.
#[test]
fn end_all_terminals_commits_one_resource_revision() {
    const TERMINALS: usize = 4;
    let mux = Mux::new_for_test("terminal-end-batch", SurfaceOptions::default());
    let mut terminal_ids = (0..TERMINALS)
        .map(|index| {
            let surface =
                mux.new_workspace(Some(format!("batch-{index}")), Some((80, 24))).unwrap();
            host_id(&mux, &surface)
        })
        .collect::<Vec<_>>();
    terminal_ids.sort();
    let before = mux.with_state(|state| state.resource_revision);

    let mut ended = mux.end_all_terminals().unwrap();

    ended.sort();
    assert_eq!(ended, terminal_ids);
    let revisions = mux.with_state(|state| state.resource_revision) - before;
    assert_eq!(
        revisions, 1,
        "ending {TERMINALS} terminals must commit one resource revision, got {revisions}"
    );
    for terminal_id in &terminal_ids {
        assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Tombstoned);
    }
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), TERMINALS, "emptied workspaces stay");
        assert!(state.terminal_catalog.is_empty());
        assert!(state.surfaces.is_empty());
    });
    assert_eq!(mux.terminal_host_closes.pending(), 0);
}

#[cfg(unix)]
fn terminal_hex(prefix: &str, index: usize) -> String {
    format!("{prefix}000000000040008000{index:012x}")
}

#[cfg(unix)]
fn tab_count(mux: &Arc<Mux>) -> usize {
    mux.with_state(|state| state.panes.values().map(|pane| pane.tabs.len()).sum())
}

/// The full stop (`shutdown-daemon end_terminals`) of a restored session
/// of `terminals` workspaces, each with one terminal that ended before
/// this daemon started: its tab is dead and it has no runtime here. That
/// is every terminal of the person's session after an app update (826
/// workspaces, 798 terminals: 628 parked, 170 dead, 0 live). Eight of
/// them hold a kept tab (parked); the others lost their host.
///
/// Counts with no clock: the stop is one resource revision and each
/// terminal is tombstoned, each dead tab is gone, each workspace stays.
/// It prints the time for the record; the time is not asserted.
#[cfg(unix)]
fn stop_of_a_restored_session(terminals: usize) {
    use crate::state::kept_tab_store::KeptTab;
    use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

    const PARKED: usize = 8;
    let root = std::env::temp_dir().join(format!(
        "cmux-stop-restored-{terminals}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let session = "stop-restored";
    let options = SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(&root, session)),
        ..SurfaceOptions::default()
    };
    let mux = Mux::open_persistent(session, options.clone(), &root).unwrap();
    let mut terminal_ids = Vec::new();
    let mut parked = Vec::new();
    for index in 0..terminals {
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let (id, incarnation) = (terminal_hex("00", index), terminal_hex("10", index));
        let surface = mux
            .seed_running_terminal_with_on_exit_for_test(
                &id,
                &incarnation,
                &workspace.key,
                TerminalOnExit::Close,
            )
            .unwrap();
        if index < PARKED {
            parked.push(surface);
        }
        terminal_ids.push(id);
    }
    let kept = mux.with_state(|state| {
        parked
            .iter()
            .map(|surface| KeptTab {
                tab_id: state.resource_indexes.tab_ids[surface].to_string(),
                ..Default::default()
            })
            .collect::<Vec<_>>()
    });
    mux.commit_kept_tabs(&kept).unwrap();
    for surface in &parked {
        mux.surface(*surface).unwrap().record_process_end_for_test(TerminalExit::now(
            TerminalExitOutcome::Signal { signal: libc::SIGTERM, core_dumped: false },
        ));
        mux.surface_exited(*surface);
    }
    mux.shutdown();
    drop(mux);

    let mux = Mux::open_persistent(session, options, &root).unwrap();
    for terminal_id in &terminal_ids {
        assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Exited, "{terminal_id}");
    }
    mux.with_state(|state| {
        assert!(state.terminal_catalog.is_empty(), "a restored ended terminal has no runtime");
        assert_eq!(state.workspaces.len(), terminals);
    });
    assert_eq!(tab_count(&mux), terminals, "each ended terminal keeps its dead tab");
    terminal_ids.sort();
    let revision = || mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
    let before = revision();

    let began = Instant::now();
    let mut ended = mux.end_all_terminals().unwrap();
    let stop_ms = began.elapsed().as_secs_f64() * 1000.0;

    let revisions = revision() - before;
    eprintln!(
        "stop-restored terminals={terminals} revisions={revisions} stop_ms={stop_ms:.1} \
             ms_per_terminal={:.3}",
        stop_ms / terminals as f64
    );
    ended.sort();
    assert_eq!(ended, terminal_ids);
    assert_eq!(
        revisions, 1,
        "the stop of {terminals} ended terminals must commit one resource revision, got \
             {revisions}"
    );
    for terminal_id in &terminal_ids {
        assert_eq!(lifecycle(&mux, terminal_id), TerminalLifecycle::Tombstoned);
    }
    assert_eq!(tab_count(&mux), 0, "each dead tab is gone");
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), terminals, "emptied workspaces stay");
        assert!(state.surfaces.is_empty());
    });
    assert_eq!(mux.terminal_host_closes.pending(), 0);
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// The per-terminal close rebuilt and committed the whole session once
/// for each ended terminal with no runtime: 66.5 s to stop the person's
/// session (DAEMON LISTS STOP 800, 2026-11-10), 2.1 s at 60 workspaces.
#[cfg(unix)]
#[test]
fn stop_of_a_restored_session_is_one_commit() {
    stop_of_a_restored_session(60);
}

/// The same at the person's session size.
#[cfg(unix)]
#[test]
#[ignore = "826 terminals take minutes to make; run with --include-ignored"]
fn stop_of_a_restored_session_is_one_commit_at_826() {
    stop_of_a_restored_session(826);
}
