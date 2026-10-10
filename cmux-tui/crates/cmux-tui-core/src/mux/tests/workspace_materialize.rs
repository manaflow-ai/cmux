//! Workspace commit order, empty workspace materialization, and targeted closes.

use super::*;

#[test]
fn concurrent_workspace_commits_publish_in_exact_revision_order() {
    let mux = test_mux();
    let events = mux.subscribe();
    let mut workers = Vec::new();
    for index in 0..16 {
        let mux = mux.clone();
        workers.push(std::thread::spawn(move || {
            mux.create_empty_workspace(
                Some(format!("workspace-{index}")),
                Some(format!("00000000-0000-4000-8000-{index:012x}")),
                None,
            )
            .unwrap()
        }));
    }
    let mut committed =
        workers.into_iter().map(|worker| worker.join().unwrap().revision).collect::<Vec<_>>();
    committed.sort_unstable();
    assert_eq!(committed, (1..=16).collect::<Vec<_>>());

    let mut published = Vec::new();
    while published.len() < 16 {
        match events.recv().unwrap() {
            MuxEvent::TreeDelta(delta) => {
                published.push(delta.workspace_revision.unwrap());
            }
            MuxEvent::TreeSelectionChanged => {}
            event => panic!("unexpected event: {event:?}"),
        }
    }
    assert_eq!(published, (1..=16).collect::<Vec<_>>());
    mux.with_state(|state| {
        assert_eq!(state.workspace_revision, 16);
        assert_eq!(state.workspaces.len(), 16);
    });
}

#[test]
fn committed_workspace_delta_is_emitted_inside_registry_ordering_fence() {
    let mux = test_mux();
    let weak_mux = Arc::downgrade(&mux);
    let (observed_tx, observed_rx) = std::sync::mpsc::sync_channel(1);
    *mux.workspace_delta_before_emit.lock().unwrap() = Some(Arc::new(move |revision| {
        let mux = weak_mux.upgrade().expect("mux remains alive through publication");
        let emitted_while_locked = mux.workspace_registry.try_lock().is_err();
        observed_tx.send((revision, emitted_while_locked)).unwrap();
    }));

    let placement = mux.create_empty_workspace(None, None, None).unwrap();
    *mux.workspace_delta_before_emit.lock().unwrap() = None;

    assert_eq!(observed_rx.recv().unwrap(), (placement.revision, true));
}

#[test]
fn new_tab_materializes_selected_empty_workspace() {
    let mux = test_mux();
    let placement = mux.create_empty_workspace(Some("gui".into()), None, None).unwrap();
    let surface = mux.new_tab(None, Some("/tmp".into()), Some((80, 24))).unwrap();
    assert_eq!(surface.spawn_cwd().as_deref(), Some("/tmp"));
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].id, placement.workspace);
        assert_eq!(state.workspaces[0].screens.len(), 1);
        assert_eq!(state.pane_of(surface.id), state.active_pane());
        assert_eq!(state.workspace_revision, 1);
    });
}

#[test]
fn concurrent_new_tabs_materialize_one_empty_workspace_screen() {
    let mux = test_mux();
    let placement = mux.create_empty_workspace(Some("gui".into()), None, None).unwrap();
    let barrier = Arc::new(std::sync::Barrier::new(9));
    let mut threads = Vec::new();
    for _ in 0..8 {
        let mux = mux.clone();
        let barrier = barrier.clone();
        threads.push(std::thread::spawn(move || {
            barrier.wait();
            mux.new_tab(None, None, Some((80, 24))).unwrap()
        }));
    }
    barrier.wait();
    let surfaces = threads.into_iter().map(|thread| thread.join().unwrap()).collect::<Vec<_>>();

    mux.with_state(|state| {
        let workspace = state.workspace_by_id(placement.workspace).unwrap();
        assert_eq!(workspace.screens.len(), 1);
        let pane = workspace.screens[0].active_pane;
        assert_eq!(state.panes[&pane].tabs.len(), surfaces.len());
    });
    for surface in surfaces {
        surface.kill();
    }
}

#[test]
fn concurrent_empty_workspace_terminal_inherits_the_first_terminals_cwd() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(Some("shared".into()), None, None).unwrap();
    let first_reserved = Arc::new(AtomicBool::new(false));
    let (first_reserved_tx, first_reserved_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let release_rx = Arc::new(Mutex::new(release_rx));
    mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new({
        let first_reserved = Arc::clone(&first_reserved);
        move |_| {
            if !first_reserved.swap(true, Ordering::SeqCst) {
                first_reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }
    })));

    let first = std::thread::spawn({
        let mux = mux.clone();
        move || {
            mux.create_terminal_surface_in_workspace(
                &Actor::Daemon,
                workspace.workspace,
                None,
                Some("/tmp".into()),
                None,
                Some((80, 24)),
            )
            .unwrap()
        }
    });
    first_reserved_rx.recv().unwrap();
    let second = std::thread::spawn({
        let mux = mux.clone();
        move || {
            mux.create_terminal_surface_in_workspace(
                &Actor::Daemon,
                workspace.workspace,
                None,
                None,
                None,
                Some((80, 24)),
            )
            .unwrap()
        }
    });
    release_tx.send(()).unwrap();

    let (first_surface, _) = first.join().unwrap();
    let (second_surface, _) = second.join().unwrap();
    assert_eq!(first_surface.spawn_cwd().as_deref(), Some("/tmp"));
    assert_eq!(second_surface.spawn_cwd().as_deref(), Some("/tmp"));
    mux.set_resource_terminal_reservation_hook_for_test(None);
    mux.shutdown();
}

#[test]
fn new_terminal_inherits_the_selected_hosted_terminals_reported_cwd() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(Some("cwd".into()), None, None).unwrap();
    let (first, _) = mux
        .create_terminal_surface_in_workspace(
            &Actor::Daemon,
            workspace.workspace,
            None,
            Some("/tmp".into()),
            None,
            Some((80, 24)),
        )
        .unwrap();
    assert!(first.terminal_runtime_id().is_some(), "the selected terminal is hosted");

    // The shell reported a `cd` on this host with OSC 7. A terminal created
    // from the selected pane starts there, not in the launch directory.
    first.set_test_pwd(Some("file://localhost/usr".into()));
    let (second, _) = mux
        .create_terminal_surface_in_workspace(
            &Actor::Daemon,
            workspace.workspace,
            None,
            None,
            None,
            Some((80, 24)),
        )
        .unwrap();
    assert_eq!(second.spawn_cwd().as_deref(), Some("/usr"));

    // A report naming another host cannot choose a spawn directory here;
    // the selected terminal's authenticated launch directory stays the fallback.
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.focus_pane(pane);
    mux.select_tab(Some(pane), Some(0), None);
    first.set_test_pwd(Some("file://other-host/etc".into()));
    let (third, _) = mux
        .create_terminal_surface_in_workspace(
            &Actor::Daemon,
            workspace.workspace,
            None,
            None,
            None,
            Some((80, 24)),
        )
        .unwrap();
    assert_eq!(third.spawn_cwd().as_deref(), Some("/tmp"));
    mux.shutdown();
}

#[test]
fn workspace_mutation_close_waits_for_targeted_terminal_commit_and_replays() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
    let unrelated = mux.create_empty_workspace(Some("unrelated".into()), None, None).unwrap();
    let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let release_rx = Arc::new(Mutex::new(release_rx));
    *mux.terminal_create_after_workspace_reservation.lock().unwrap() = Some(Arc::new({
        move || {
            reserved_tx.send(()).unwrap();
            release_rx.lock().unwrap().recv().unwrap();
        }
    }));

    let create = std::thread::spawn({
        let mux = mux.clone();
        move || {
            mux.create_terminal_surface_in_workspace(
                &Actor::Daemon,
                workspace.workspace,
                None,
                None,
                None,
                Some((80, 24)),
            )
        }
    });
    reserved_rx.recv().unwrap();
    assert!(mux.workspace_lifecycle(workspace.workspace).try_lock().is_err());
    let unrelated_lifecycle = mux.workspace_lifecycle(unrelated.workspace);
    assert!(unrelated_lifecycle.try_lock().is_ok());

    let (close_started_tx, close_started_rx) = std::sync::mpsc::sync_channel(1);
    let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
    let close_mutation = WorkspaceMutation::daemon("close-target", "browser").unwrap();
    let close = std::thread::spawn({
        let mux = mux.clone();
        let close_mutation = close_mutation.clone();
        move || {
            close_started_tx.send(()).unwrap();
            let result = mux.close_workspace_with_mutation(
                Some(workspace.workspace),
                None,
                None,
                Some(2),
                &close_mutation,
            );
            close_done_tx.send(result).unwrap();
        }
    });
    close_started_rx.recv().unwrap();
    for _ in 0..1_000 {
        std::thread::yield_now();
    }
    assert!(matches!(close_done_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

    release_tx.send(()).unwrap();
    let (surface, placement) = create.join().unwrap().unwrap();
    assert_eq!(placement.workspace, workspace.workspace);
    let result = close_done_rx.recv().unwrap().unwrap();
    assert_eq!(result.workspace, Some(workspace.workspace));
    assert_eq!(result.revision, 3);
    assert!(!result.replayed);
    close.join().unwrap();
    let replay = mux
        .close_workspace_with_mutation(
            Some(workspace.workspace),
            None,
            None,
            Some(2),
            &close_mutation,
        )
        .unwrap();
    assert_eq!(replay.revision, result.revision);
    assert!(replay.replayed);
    let host = mux
        .resource_terminal_host_identity(&surface)
        .expect("closed workspace terminal keeps its host identity");
    let terminal_id = surface.terminal_public_id().cloned().unwrap();
    let terminal = mux
        .workspace_registry
        .lock()
        .unwrap()
        .terminal_record(&host.terminal_id)
        .unwrap()
        .expect("closing a workspace must not tombstone its terminal");
    assert_eq!(terminal.lifecycle, TerminalLifecycle::Running);
    assert!(mux.with_state(|state| {
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id)).is_empty()
    }));
    assert!(mux.surface(surface.id).is_some());
    *mux.terminal_create_after_workspace_reservation.lock().unwrap() = None;
    surface.kill();
    mux.shutdown();
}

#[test]
fn pane_and_screen_close_wait_for_targeted_terminal_commit() {
    for close_screen in [false, true] {
        let mux = test_mux();
        let initial = mux.new_workspace(None, Some((80, 24))).unwrap();
        let (workspace, pane, screen) = mux.with_state(|state| {
            let pane = state.pane_of(initial.id).unwrap();
            let (wi, si) = state.screen_of(pane).unwrap();
            (state.workspaces[wi].id, pane, state.workspaces[wi].screens[si].id)
        });
        let (reserved_tx, reserved_rx) = std::sync::mpsc::sync_channel(1);
        let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
        let release_rx = Arc::new(Mutex::new(release_rx));
        mux.set_resource_terminal_reservation_hook_for_test(Some(Arc::new({
            move |_| {
                reserved_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        })));

        let create = std::thread::spawn({
            let mux = mux.clone();
            move || {
                mux.create_terminal_surface_in_workspace(
                    &Actor::Daemon,
                    workspace,
                    None,
                    None,
                    None,
                    Some((80, 24)),
                )
            }
        });
        reserved_rx.recv().unwrap();

        let (close_started_tx, close_started_rx) = std::sync::mpsc::sync_channel(1);
        let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
        let close = std::thread::spawn({
            let mux = mux.clone();
            move || {
                close_started_tx.send(()).unwrap();
                let result =
                    if close_screen { mux.close_screen(screen) } else { mux.close_pane(pane) };
                close_done_tx.send(result).unwrap();
            }
        });
        close_started_rx.recv().unwrap();
        for _ in 0..1_000 {
            std::thread::yield_now();
        }
        assert!(matches!(close_done_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

        release_tx.send(()).unwrap();
        let (created, placement) = create.join().unwrap().unwrap();
        assert_eq!(placement.workspace, workspace);
        assert!(close_done_rx.recv().unwrap().unwrap());
        close.join().unwrap();
        // The close took the created tab too, so the emptied workspace closed.
        mux.with_state(|state| {
            assert!(state.workspaces.iter().all(|item| item.id != workspace));
        });
        mux.set_resource_terminal_reservation_hook_for_test(None);
        initial.kill();
        created.kill();
        mux.shutdown();
    }
}

#[test]
fn key_close_cannot_rebind_a_live_durable_workspace_identity() {
    let mux = test_mux();
    let key = "018f6e21-7b70-7e70-8000-000000001021".to_string();
    let original =
        mux.create_empty_workspace(Some("original".into()), Some(key.clone()), None).unwrap();
    let original_lifecycle = mux.workspace_lifecycle(original.workspace);
    let original_guard = original_lifecycle.lock().unwrap();

    let selector_resolved = Arc::new(AtomicBool::new(false));
    let (resolved_tx, resolved_rx) = std::sync::mpsc::sync_channel(1);
    *mux.workspace_close_after_selector_resolution.lock().unwrap() = Some(Arc::new({
        move || {
            if !selector_resolved.swap(true, Ordering::SeqCst) {
                resolved_tx.send(()).unwrap();
            }
        }
    }));
    let (close_done_tx, close_done_rx) = std::sync::mpsc::sync_channel(1);
    let close = std::thread::spawn({
        let mux = mux.clone();
        let key = key.clone();
        move || {
            close_done_tx
                .send(mux.close_workspace_selector_at_revision(
                    &Actor::Daemon,
                    None,
                    Some(&key),
                    None,
                ))
                .unwrap();
        }
    });
    resolved_rx.recv().unwrap();

    {
        let mut state = mux.state.lock().unwrap();
        let index = state.workspace_index(original.workspace).unwrap();
        state.remove_workspace(index);
        state.workspace_revision = state.workspace_revision.saturating_add(1);
    }
    let replacement_error =
        mux.create_empty_workspace(Some("replacement".into()), Some(key), None).unwrap_err();
    assert!(replacement_error.to_string().contains("is already bound to public id"));
    drop(original_guard);

    let close_result = close_done_rx.recv().unwrap();
    close.join().unwrap();
    *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
    assert!(close_result.unwrap_err().to_string().contains("unknown workspace key"));
    mux.shutdown();
}

#[test]
fn provider_ownership_handoff_waits_for_an_entered_ordinary_close() {
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("ordinary".into()),
            Some("018f6e21-7b70-7e70-8000-00000000aa07".into()),
            None,
        )
        .unwrap();
    let entered = Arc::new(AtomicBool::new(false));
    let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let release_rx = Arc::new(Mutex::new(release_rx));
    *mux.workspace_close_after_selector_resolution.lock().unwrap() = Some(Arc::new({
        move || {
            if !entered.swap(true, Ordering::SeqCst) {
                entered_tx.send(()).unwrap();
                release_rx.lock().unwrap().recv().unwrap();
            }
        }
    }));

    let close = std::thread::spawn({
        let mux = mux.clone();
        move || mux.close_workspace_at_revision(workspace.workspace, None)
    });
    entered_rx.recv().unwrap();

    let (marked_tx, marked_rx) = std::sync::mpsc::sync_channel(1);
    let mark = std::thread::spawn({
        let mux = mux.clone();
        move || {
            mux.mark_workspaces_provider_managed_internal();
            marked_tx.send(()).unwrap();
        }
    });
    for _ in 0..1_000 {
        std::thread::yield_now();
    }
    assert!(matches!(marked_rx.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

    release_tx.send(()).unwrap();
    assert_eq!(close.join().unwrap().unwrap(), Some(2));
    marked_rx.recv().unwrap();
    mark.join().unwrap();

    let managed = mux
        .create_empty_workspace(
            Some("managed".into()),
            Some("018f6e21-7b70-7e70-8000-00000000aa02".into()),
            None,
        )
        .unwrap();
    assert!(!mux.rename_workspace(managed.workspace, "raw rename".into()));
    assert!(!mux.close_workspace(managed.workspace));

    *mux.workspace_close_after_selector_resolution.lock().unwrap() = None;
    mux.shutdown();
}

#[test]
fn create_terminal_targets_inactive_empty_workspace() {
    let mux = test_mux();
    let target = mux.create_empty_workspace(Some("target".into()), None, None).unwrap();
    let active = mux.create_empty_workspace(Some("active".into()), None, None).unwrap();
    let placement = mux
        .create_terminal_in_workspace(target.workspace, None, None, None, Some((80, 24)))
        .unwrap();
    mux.with_state(|state| {
        assert_eq!(state.active_workspace, 1);
        assert_eq!(state.workspaces[1].id, active.workspace);
        assert!(state.workspaces[1].screens.is_empty());
        assert_eq!(placement.workspace, target.workspace);
        assert_eq!(state.workspaces[0].screens.len(), 1);
        assert_eq!(state.pane_of(placement.surface), Some(placement.pane));
        assert_eq!(state.workspace_revision, 2);
    });
}

#[test]
fn create_terminal_in_existing_pane_emits_selection_resync() {
    let mux = test_mux();
    let initial = mux.new_workspace(None, Some((80, 24))).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].id);
    let events = mux.subscribe();

    let placement =
        mux.create_terminal_in_workspace(workspace, None, None, None, Some((80, 24))).unwrap();

    assert_ne!(placement.surface, initial.id);
    let deadline = Instant::now() + Duration::from_secs(1);
    let mut saw_added = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        match events.recv_timeout(remaining).expect("tab events arrive before timeout") {
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::TabAdded, surface, .. })
                if surface == Some(placement.surface) =>
            {
                saw_added = true;
            }
            MuxEvent::TreeSelectionChanged if saw_added => break,
            MuxEvent::TreeSelectionChanged => {
                panic!("selection resync arrived before the tab-added delta")
            }
            _ => {}
        }
    }
}

#[test]
fn run_materializes_active_empty_workspace() {
    let mux = test_mux();
    let placement = mux
        .create_empty_workspace(
            Some("gui".into()),
            Some("018f6e21-7b70-7e70-8000-000000001019".into()),
            None,
        )
        .unwrap();
    let run = mux
        .run_command_surface(
            vec!["/bin/echo".into(), "ready".into()],
            None,
            false,
            Some("/tmp".into()),
            Some("runner".into()),
            Some((80, 24)),
        )
        .unwrap();

    assert_eq!(run.workspace, placement.workspace);
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].id, placement.workspace);
        assert_eq!(state.workspaces[0].screens.len(), 1);
        assert_eq!(state.workspace_revision, 1);
    });
    mux.shutdown();
}

#[test]
fn run_new_workspace_accepts_a_stable_caller_key() {
    let mux = test_mux();
    let key = "019c0000-0000-7000-8000-000000000001".to_string();
    let run = mux
        .run_command_surface_with_options(
            vec!["/bin/echo".into(), "ready".into()],
            RunCommandOptions {
                pane: None,
                new_workspace: true,
                workspace_key: Some(key.clone()),
                cwd: Some("/tmp".into()),
                name: Some("cloud-workspace".into()),
                size: Some((80, 24)),
            },
        )
        .unwrap();

    mux.with_state(|state| {
        let workspace = state.workspace_by_key(&key).expect("workspace uses caller key");
        assert_eq!(workspace.id, run.workspace);
        assert_eq!(workspace.name, "cloud-workspace");
    });
    let duplicate = mux
        .run_command_surface_with_options(
            vec!["/bin/echo".into(), "duplicate".into()],
            RunCommandOptions {
                pane: None,
                new_workspace: true,
                workspace_key: Some(key),
                cwd: None,
                name: None,
                size: Some((80, 24)),
            },
        )
        .expect_err("duplicate stable key must fail");
    assert!(duplicate.to_string().contains("already exists"));
    mux.with_state(|state| assert_eq!(state.workspaces.len(), 1));
    mux.shutdown();
}

#[test]
fn new_browser_tab_materializes_selected_empty_workspace() {
    let mux = test_mux();
    let target = mux.create_empty_workspace(Some("browser".into()), None, None).unwrap();
    let surface = mux.new_browser_tab("about:blank".into(), None, Some((80, 24))).unwrap();

    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].id, target.workspace);
        assert_eq!(state.workspaces[0].screens.len(), 1);
        assert_eq!(state.pane_of(surface.id), Some(state.workspaces[0].screens[0].active_pane));
        assert_eq!(state.workspace_revision, 1);
    });
    mux.shutdown();
}

#[test]
fn concurrent_browser_tabs_materialize_one_empty_workspace_screen() {
    let mux = test_mux();
    let target = mux.create_empty_workspace(Some("browser".into()), None, None).unwrap();
    let barrier = Arc::new(std::sync::Barrier::new(9));
    let mut threads = Vec::new();
    for index in 0..8 {
        let mux = mux.clone();
        let barrier = barrier.clone();
        threads.push(std::thread::spawn(move || {
            barrier.wait();
            mux.new_browser_tab(format!("about:blank#{index}"), None, Some((80, 24)))
        }));
    }
    barrier.wait();
    let surfaces = threads
        .into_iter()
        .map(|thread| thread.join().unwrap().expect("concurrent browser creation"))
        .collect::<Vec<_>>();

    mux.with_state(|state| {
        let workspace = state.workspace_by_id(target.workspace).unwrap();
        assert_eq!(workspace.screens.len(), 1);
        let pane = workspace.screens[0].active_pane;
        assert_eq!(state.panes[&pane].tabs.len(), surfaces.len());
    });
    mux.shutdown();
}

#[test]
fn browser_tab_in_existing_workspace_pane_emits_selection_resync() {
    let mux = test_mux();
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let first = mux
        .create_browser_surface_in_workspace(
            workspace.workspace,
            "about:blank#first".into(),
            Some((80, 24)),
            None,
        )
        .unwrap();
    let events = mux.subscribe();

    let second = mux
        .create_browser_surface_in_workspace(
            workspace.workspace,
            "about:blank#second".into(),
            Some((80, 24)),
            None,
        )
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut saw_added = false;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let event = events.recv_timeout(remaining).expect("tab events arrive before timeout");
        match event {
            MuxEvent::TreeDelta(TreeDelta { kind: TreeDeltaKind::TabAdded, surface, .. })
                if surface == Some(second.id) =>
            {
                saw_added = true;
            }
            MuxEvent::TreeSelectionChanged if saw_added => break,
            MuxEvent::TreeSelectionChanged => {
                panic!("selection resync arrived before the tab-added delta")
            }
            _ => {
                // The browser worker may emit state telemetry between the
                // synchronous tree events. It does not affect their order.
            }
        }
    }
    first.kill();
    second.kill();
}

#[test]
fn concurrent_browser_and_terminal_share_empty_workspace_screen() {
    let mux = test_mux();
    let target = mux.create_empty_workspace(Some("mixed".into()), None, None).unwrap();
    let barrier = Arc::new(std::sync::Barrier::new(3));
    let browser = {
        let mux = mux.clone();
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            barrier.wait();
            mux.new_browser_tab("about:blank".into(), None, Some((80, 24)))
        })
    };
    let terminal = {
        let mux = mux.clone();
        let barrier = barrier.clone();
        std::thread::spawn(move || {
            barrier.wait();
            mux.create_terminal_in_workspace(target.workspace, None, None, None, Some((80, 24)))
        })
    };
    barrier.wait();
    let browser = browser.join().unwrap().expect("concurrent browser creation");
    let terminal = terminal.join().unwrap().expect("concurrent terminal creation");

    mux.with_state(|state| {
        let workspace = state.workspace_by_id(target.workspace).unwrap();
        assert_eq!(workspace.screens.len(), 1);
        let pane = workspace.screens[0].active_pane;
        assert_eq!(state.panes[&pane].tabs.len(), 2);
        assert_eq!(state.pane_of(browser.id), Some(pane));
        assert_eq!(state.pane_of(terminal.surface), Some(pane));
    });
    mux.shutdown();
}

#[test]
fn move_workspace_reorders_and_tracks_active_workspace() {
    let mux = test_mux();
    let events = mux.subscribe();
    mux.new_workspace(Some("one".into()), None).unwrap();
    mux.new_workspace(Some("two".into()), None).unwrap();
    mux.new_workspace(Some("three".into()), None).unwrap();
    let (ws1, ws2, ws3) =
        mux.with_state(|s| (s.workspaces[0].id, s.workspaces[1].id, s.workspaces[2].id));

    assert_eq!(mux.move_workspace_at_revision(ws3, 2, Some(3)).unwrap(), Some((3, false)));
    assert!(!mux.move_workspace(ws3, 2));
    assert!(mux.move_workspace(ws3, 0));
    let mut deltas = events.try_iter().filter_map(|event| match event {
        MuxEvent::TreeDelta(delta) => Some(delta),
        _ => None,
    });
    let moved = deltas
        .find(|delta| delta.kind == TreeDeltaKind::WorkspaceMoved)
        .expect("workspace-moved delta");
    assert_eq!(moved.workspace, ws3);
    assert_eq!(moved.index, Some(0));
    assert_eq!(moved.workspace_revision, Some(4));
    mux.with_state(|s| {
        assert_eq!(s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(), vec![ws3, ws1, ws2]);
        assert_eq!(s.active_workspace, 0);
        assert_eq!(s.workspace_index(ws3), Some(0));
        assert_eq!(s.workspace_index(ws1), Some(1));
        assert_eq!(s.workspace_index(ws2), Some(2));
    });

    assert!(mux.move_workspace(ws1, 99));
    mux.with_state(|s| {
        assert_eq!(s.workspaces.iter().map(|ws| ws.id).collect::<Vec<_>>(), vec![ws3, ws2, ws1]);
        assert_eq!(s.active_workspace, 0);
        assert_eq!(s.workspace_index(ws1), Some(2));
    });
}

#[test]
fn move_workspace_right_uses_insertion_index() {
    let mux = test_mux();
    mux.new_workspace(Some("one".into()), None).unwrap();
    mux.new_workspace(Some("two".into()), None).unwrap();
    mux.new_workspace(Some("three".into()), None).unwrap();
    let (ws1, ws2, ws3) = mux.with_state(|state| {
        (state.workspaces[0].id, state.workspaces[1].id, state.workspaces[2].id)
    });

    assert_eq!(mux.move_workspace_at_revision(ws1, 1, Some(3)).unwrap(), Some((3, false)));
    mux.with_state(|state| {
        assert_eq!(
            state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
            vec![ws1, ws2, ws3]
        );
    });

    assert_eq!(mux.move_workspace_at_revision(ws1, 2, Some(3)).unwrap(), Some((4, true)));
    mux.with_state(|state| {
        assert_eq!(
            state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
            vec![ws2, ws1, ws3]
        );
    });

    assert_eq!(mux.move_workspace_at_revision(ws1, 3, Some(4)).unwrap(), Some((5, true)));
    mux.with_state(|state| {
        assert_eq!(
            state.workspaces.iter().map(|workspace| workspace.id).collect::<Vec<_>>(),
            vec![ws2, ws3, ws1]
        );
    });
}
