//! Projected terminal views: shared owners, geometry authority, exit detach, and size policy.

use super::*;

fn projected_terminal_view(mux: &Arc<Mux>, source: &Arc<Surface>) -> Arc<Surface> {
    let terminal_id =
        source.terminal_public_id().cloned().expect("test terminal has a public content identity");
    let pane = mux.with_state(|state| state.pane_of(source.id).unwrap());
    mux.resource_project_terminal_selected(
        crate::ResourceSelectors {
            terminal: Some(terminal_id.to_string()),
            ..Mux::ordinary_resource_selectors()
        },
        mux.ordinary_pane_selectors(pane).unwrap(),
        usize::MAX,
        None,
        None,
        &WorkspaceMutation::daemon_local("test-terminal-projection"),
    )
    .unwrap();
    mux.with_state(|state| {
        state
            .placements_of_content(&ContentPublicId::Terminal(terminal_id))
            .iter()
            .copied()
            .find(|placement| *placement != source.id)
            .and_then(|placement| state.surfaces.get(&placement))
            .cloned()
            .expect("projected terminal view is materialized")
    })
}

#[test]
fn projected_views_share_one_graphics_and_cell_pixel_owner() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    wait_for_kitty_image_budget(&mux);
    assert_eq!(mux.kitty_image_budget.lock().unwrap().entries.len(), 1);

    let projected = projected_terminal_view(&mux, &source);
    wait_for_kitty_image_budget(&mux);
    assert!(source.shares_terminal_runtime(&projected));
    assert_eq!(mux.kitty_image_budget.lock().unwrap().entries.len(), 1);

    let applications = Arc::new(AtomicUsize::new(0));
    *mux.cell_pixel_operation.lock().unwrap() = Some(Arc::new({
        let applications = applications.clone();
        move |surface, target, _deadline| {
            applications.fetch_add(1, Ordering::AcqRel);
            surface.set_cell_pixel_size(target.0, target.1).map(|changed| changed.then_some(0))
        }
    }));
    let update = mux.set_cell_pixel_size(9, 18);
    assert!(update.failures.is_empty());
    assert_eq!(applications.load(Ordering::Acquire), 1);
    assert_eq!(source.test_cell_pixel_size(), (9, 18));
    assert_eq!(projected.test_cell_pixel_size(), (9, 18));

    assert!(mux.close_surface(source.id).unwrap());
    wait_for_kitty_image_budget(&mux);
    assert_eq!(mux.kitty_image_budget.lock().unwrap().entries.len(), 1);

    close_terminal_runtime_for_test(&mux, &source);
    wait_for_kitty_image_budget(&mux);
    assert!(mux.kitty_image_budget.lock().unwrap().entries.is_empty());
}

// Shared sizing (docs/shared-terminal-sizing.md) replaced the explicit
// geometry-authority model: a view that joins is activity, so under the
// `latest` policy (pinned here; the default is `smallest`) the newest view with a viewport sets the grid,
// and a claim (focus or input) moves it back.
#[test]
fn terminal_views_follow_the_latest_activity() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);

    assert!(mux.resize_surface_for_client(surface.id, 0, 120, 40).unwrap());
    assert_eq!(surface.size(), (120, 40));
    assert!(mux.client_size_participates(surface.id, 0));
    assert_eq!(mux.claim_terminal_geometry(surface.id, 0), Some(false));

    assert!(mux.resize_surface_for_client(surface.id, 7, 60, 20).unwrap());
    assert_eq!(surface.size(), (60, 20));
    assert!(mux.client_size_participates(surface.id, 7));
    assert!(!mux.client_size_participates(surface.id, 0));

    // A later report from a non-owner is a viewport hint only.
    assert!(!mux.resize_surface_for_client(surface.id, 0, 130, 45).unwrap());
    assert_eq!(surface.size(), (60, 20));

    assert_eq!(mux.claim_terminal_geometry(surface.id, 0), Some(true));
    assert_eq!(surface.size(), (130, 45));
    assert!(!mux.client_size_participates(surface.id, 7));
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(state.owners, ["c0"]);
    assert_eq!(
        state.participants.iter().map(|row| row.participant.id.as_str()).collect::<Vec<_>>(),
        ["c0", "c7"]
    );
}

#[test]
fn geometry_authority_moves_between_views_of_one_terminal() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(source.id);
    let projected = projected_terminal_view(&mux, &source);

    assert!(source.shares_terminal_runtime(&projected));
    assert!(mux.resize_surface_for_client(source.id, 0, 110, 35).unwrap());
    assert_eq!(source.size(), (110, 35));
    assert!(mux.resize_surface_for_client(projected.id, 0, 60, 20).unwrap());
    assert_eq!(source.size(), (60, 20));

    assert_eq!(mux.claim_terminal_geometry(source.id, 0), Some(true));
    assert_eq!(source.size(), (110, 35));
    assert_eq!(projected.size(), (110, 35));

    assert_eq!(mux.claim_terminal_geometry(projected.id, 0), Some(true));
    assert_eq!(source.size(), (60, 20));
    assert_eq!(projected.size(), (60, 20));
    assert!(!mux.client_size_participates(source.id, 0));
    assert!(mux.client_size_participates(projected.id, 0));
}

#[test]
fn terminal_runtime_events_fan_out_only_to_materialized_views() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let projected = projected_terminal_view(&mux, &source);
    let events = mux.subscribe();
    let expected = HashSet::from([source.id, projected.id]);

    let collect_two = |map: fn(MuxEvent) -> Option<SurfaceId>| {
        (0..2)
            .map(|_| events.recv_timeout(Duration::from_secs(1)).unwrap())
            .filter_map(map)
            .collect::<HashSet<_>>()
    };

    mux.emit_terminal_output(source.id);
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::SurfaceOutput(surface) => Some(surface),
            _ => None,
        }),
        expected
    );
    mux.emit_terminal_title(source.id, Arc::from("shared title"));
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::TitleChanged { surface, .. } => Some(surface),
            _ => None,
        }),
        expected
    );
    mux.emit_terminal_bell(source.id);
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::Bell(surface) => Some(surface),
            _ => None,
        }),
        expected
    );
    mux.emit_terminal_resized(source.id, 100, 30, Some(7));
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::SurfaceResized { surface, .. } => Some(surface),
            _ => None,
        }),
        expected
    );
    mux.emit_terminal_scroll(source.id, 4, false);
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::ScrollChanged { surface, .. } => Some(surface),
            _ => None,
        }),
        expected
    );
    mux.emit_terminal_exited(source.id);
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::SurfaceExited(surface) => Some(surface),
            _ => None,
        }),
        expected
    );

    mux.set_default_colors(DefaultColors {
        fg: Some(crate::Rgb { r: 0x11, g: 0x22, b: 0x33 }),
        ..Default::default()
    });
    assert_eq!(
        collect_two(|event| match event {
            MuxEvent::SurfaceOutput(surface) => Some(surface),
            _ => None,
        }),
        expected
    );
    assert!(matches!(events.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));

    mux.remove_surface_runtime_for_test(source.id).unwrap();
    mux.remove_surface_runtime_for_test(projected.id).unwrap();
    mux.emit_terminal_output(source.id);
    assert!(matches!(events.try_recv(), Err(std::sync::mpsc::TryRecvError::Empty)));
}

#[cfg(unix)]
/// The Mac holds only public `term_…` ids. A running terminal whose views
/// were all closed stays attachable only if `resolve-terminal` answers for
/// that id: the compatibility tree lists tabs, not terminals, so a
/// detached terminal was unresolvable by construction (#12362).
#[test]
fn resolve_terminal_accepts_the_public_id_of_a_detached_terminal() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let public_id = source
        .terminal_public_id()
        .cloned()
        .expect("hosted terminal has a public content identity");
    let host = mux
        .resource_terminal_host_identity(&source)
        .expect("hosted terminal has a durable process identity");
    let workspace = mux.surface_workspace(source.id).expect("the new workspace hosts the terminal");
    mux.create_empty_workspace(None, Some("018f6e21-7b70-7e70-8000-000000012362".into()), None)
        .unwrap();
    assert!(mux.close_workspace_at_revision(workspace, None).unwrap().is_some());
    assert_eq!(mux.resolve_terminal(&host.terminal_id).unwrap().unwrap().surface, None);
    assert!(
        mux.surface(source.id).is_some(),
        "closing a workspace detaches its terminals; it never kills them"
    );

    let resolved = mux
        .resolve_terminal(public_id.as_str())
        .expect("a public terminal id is a valid resolver input")
        .expect("the detached terminal is still registered");
    assert_eq!(resolved.terminal.terminal_id, host.terminal_id);
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Running);
    assert_eq!(resolved.surface, None);
}

#[test]
fn hosted_terminal_exit_atomically_detaches_every_projected_view() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    let projected = projected_terminal_view(&mux, &source);
    let terminal_id = source
        .terminal_public_id()
        .cloned()
        .expect("hosted terminal has a public content identity");
    let host = mux
        .resource_terminal_host_identity(&source)
        .expect("hosted terminal has a durable process identity");
    let runtime_id = source.terminal_runtime_id().expect("hosted terminal has a runtime");
    let placements = HashSet::from([source.id, projected.id]);
    let tab_ids = mux.with_state(|state| {
        placements
            .iter()
            .map(|surface| state.resource_indexes.tab_ids[surface].clone())
            .collect::<Vec<_>>()
    });
    let before_revision = mux.workspace_registry.lock().unwrap().resource_revision().unwrap();
    let events = mux.subscribe();

    source.record_process_end_for_test(TerminalExit::now(
        crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
    ));
    mux.surface_exited(source.id);

    mux.with_state(|state| {
        assert!(
            state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).is_empty(),
            "an exited runtime retained a projected view"
        );
        assert!(
            !state.terminal_catalog.contains_key(&terminal_id),
            "an exited runtime remained catalog-owned"
        );
        assert!(
            !state.terminal_catalog_by_runtime.contains_key(&runtime_id),
            "an exited runtime retained its reverse catalog entry"
        );
    });
    let resolved = mux.resolve_terminal(&host.terminal_id).unwrap().unwrap();
    assert_eq!(resolved.surface, None);
    assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
    let waited = mux.wait_for_terminal_exit(&terminal_id, Some(Duration::ZERO)).unwrap();
    assert_eq!(waited["state"], "exited");

    let batches = mux.resource_events_after(before_revision).unwrap().batches;
    assert_eq!(batches.len(), 1, "exit lifecycle and topology split across revisions");
    let changes = batches[0].changes.as_array().unwrap();
    let exited_row = changes
        .iter()
        .find(|change| {
            change["kind"] == "upsert"
                && change["resource"] == "terminal"
                && change["id"] == terminal_id.as_str()
        })
        .expect("atomic exit publishes the exited terminal row")["value"]
        .clone();
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let snapshot_row = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .expect("the exited terminal stays in the snapshot")
        .clone();
    for key in ["tab_id", "tab_ids"] {
        assert_eq!(
            exited_row[key], snapshot_row[key],
            "the exit delta and the snapshot at its revision disagree on {key}"
        );
    }
    assert_eq!(exited_row["tab_ids"], serde_json::json!([]));
    for tab_id in tab_ids {
        assert!(
            changes.iter().any(|change| {
                change["kind"] == "delete"
                    && change["resource"] == "tab"
                    && change["id"] == tab_id.as_str()
            }),
            "atomic exit omitted projected tab {tab_id}"
        );
    }

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut exited = HashSet::new();
    while exited != placements {
        assert!(Instant::now() < deadline, "not every projected view observed terminal exit");
        if let Ok(MuxEvent::SurfaceExited(surface)) = events.recv_timeout(Duration::from_millis(20))
        {
            exited.insert(surface);
        }
    }
    mux.shutdown();
}

#[test]
fn receipted_creation_atomically_uses_client_local_fallback_and_replays_it() {
    let mux = test_mux();
    let fallback = mux.new_workspace(None, Some((80, 24))).unwrap();
    let fallback_pane = mux.with_state(|state| state.pane_of(fallback.id).unwrap());
    let primary = mux.split(fallback_pane, SplitDir::Right, Some((40, 24))).unwrap();
    let primary_pane = mux.with_state(|state| state.pane_of(primary.id).unwrap());
    let candidates = vec![
        mux.resource_selectors_for_pane(Some(primary_pane)).unwrap(),
        mux.resource_selectors_for_pane(Some(fallback_pane)).unwrap(),
    ];
    assert!(mux.close_pane(primary_pane).unwrap());

    let mutation = WorkspaceMutation::daemon(
        "selector-fallback-receipt-00000001".to_string(),
        "selector-fallback-test".to_string(),
    )
    .unwrap();
    let fields = Map::from_iter([
        ("direction".to_string(), serde_json::json!("right")),
        ("cols".to_string(), serde_json::json!(40)),
        ("rows".to_string(), serde_json::json!(24)),
    ]);
    let (created, replayed) = mux
        .receipted_surface_creation(
            ResourceOperation::PaneSplit,
            candidates.clone(),
            fields.clone(),
            &mutation,
        )
        .unwrap();
    assert!(!replayed);
    assert_ne!(created, fallback.id);
    assert!(mux.with_state(|state| state.pane_of(created).is_some()));

    assert!(mux.close_pane(fallback_pane).unwrap());
    let (replayed_surface, replayed) = mux
        .receipted_surface_creation(ResourceOperation::PaneSplit, candidates, fields, &mutation)
        .unwrap();
    assert!(replayed);
    assert_eq!(replayed_surface, created);
    mux.close_surface(created).unwrap();
}

#[test]
fn receipted_creation_rejects_fallbacks_that_drop_to_backend_selection() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
    let pane_selectors = mux.resource_selectors_for_pane(Some(pane)).unwrap();
    let session_selectors = crate::ResourceSelectors {
        machine: pane_selectors.machine.clone(),
        session: pane_selectors.session.clone(),
        ..crate::ResourceSelectors::default()
    };
    let mutation = WorkspaceMutation::daemon(
        "selector-fallback-receipt-00000002".to_string(),
        "selector-fallback-test".to_string(),
    )
    .unwrap();

    let error = mux
        .receipted_surface_creation(
            ResourceOperation::TabCreateTerminal,
            vec![pane_selectors, session_selectors],
            Map::new(),
            &mutation,
        )
        .unwrap_err();

    assert_eq!(error.to_string(), "creation selector fallbacks require pane selectors");
    assert_eq!(mux.with_state(|state| state.surfaces.len()), 1);
    mux.close_surface(surface.id).unwrap();
}

#[cfg(unix)]
#[test]
fn failed_atomic_exit_retries_without_exposing_partial_topology() {
    const TERMINAL: &str = "0000000000004000800000000000003f";
    const INCARNATION: &str = "1000000000004000800000000000003f";
    let mux = test_mux();
    let workspace = mux
        .create_empty_workspace(
            Some("failed-atomic-exit".into()),
            Some("018f6e21-7b70-7e70-8000-00000000103f".into()),
            None,
        )
        .unwrap();
    let surface =
        mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let public_id =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();

    mux.surface(surface).unwrap().record_process_end_for_test(TerminalExit::now(
        crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
    ));
    mux.surface_exited(surface);

    mux.with_state(|state| {
        assert_eq!(
            state.placements_of_content(&ContentPublicId::Terminal(public_id.clone())),
            &[surface],
            "failed transaction exposed a partial detach"
        );
        assert!(state.terminal_catalog.contains_key(&public_id));
    });
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_record(TERMINAL)
            .unwrap()
            .unwrap()
            .lifecycle,
        TerminalLifecycle::Running
    );
    assert!(mux.terminal_exit_detaches.contains(TERMINAL));

    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        let detached = mux.resolve_terminal(TERMINAL).unwrap().unwrap().surface.is_none();
        let retry_finished = !mux.terminal_exit_detaches.contains(TERMINAL);
        if detached && retry_finished {
            break;
        }
        assert!(Instant::now() < deadline, "atomic exit retry did not detach the terminal");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        mux.resolve_terminal(TERMINAL).unwrap().unwrap().terminal.lifecycle,
        TerminalLifecycle::Exited
    );
    assert!(
        mux.terminal_exit_detaches.wait_until_finished(TERMINAL, deadline),
        "terminal detach retry worker did not release its ownership"
    );
}

#[test]
fn opting_out_holds_the_grid_until_automatic_sizing_is_restored() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    mux.resize_surface_for_client(surface.id, 0, 100, 30).unwrap();
    assert_eq!(surface.size(), (100, 30));

    // `counts_override:false` (legacy "disable sizing") leaves nobody
    // counting, so the grid is held rather than resized.
    assert_eq!(mux.set_client_size_participation(surface.id, 0, false), Some(true));
    assert!(!mux.resize_surface_for_client(surface.id, 0, 70, 20).unwrap());
    assert_eq!(surface.size(), (100, 30));
    let state = mux.terminal_size_state(surface.id).unwrap();
    assert_eq!(state.reason, TerminalSizingReason::Held);

    assert_eq!(mux.release_terminal_geometry(surface.id), Some(true));
    assert_eq!(surface.size(), (70, 20));
}

#[test]
fn the_in_process_frontend_joins_shared_sizing_with_a_device_name() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();

    mux.resize_surface_for_client(surface.id, 0, 100, 30).unwrap();

    let id = mux.terminal_view_participant_id(surface.id, 0).unwrap();
    let state = mux.terminal_size_state(surface.id).unwrap();
    let participant = &state.participant(&id).unwrap().participant;
    assert_eq!(participant.device_kind, TerminalDeviceKind::Tui);
    assert!(
        participant.device_name.as_deref().is_some_and(|name| !name.is_empty()),
        "other viewers name this TUI after its host, or cmux-tui"
    );
}

#[test]
fn removing_the_owner_viewport_elects_the_next_owner() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(source.id);
    let projected = projected_terminal_view(&mux, &source);

    mux.resize_surface_for_client(source.id, 7, 55, 18).unwrap();
    mux.resize_surface_for_client(projected.id, 0, 96, 28).unwrap();
    assert_eq!(source.size(), (96, 28));
    assert!(mux.client_size_participates(projected.id, 0));

    // The owner leaves; the grid follows the remaining view instead of
    // freezing at the departed owner's size.
    mux.remove_surface_size_client(projected.id, 0);
    assert_eq!(source.size(), (55, 18));
    assert!(!mux.client_size_participates(projected.id, 0));
    assert!(mux.client_size_participates(source.id, 7));
    let state = mux.terminal_size_state(source.id).unwrap();
    assert_eq!(state.owners, ["c7"]);
    assert_eq!(state.reason, TerminalSizingReason::Latest);
}

#[test]
fn only_owner_reports_seed_future_terminal_geometry() {
    let mux = test_mux();
    let source = mux.new_workspace(None, Some((80, 24))).unwrap();

    mux.resize_surface_for_client(source.id, 0, 111, 33).unwrap();
    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (111, 33));

    mux.resize_surface_for_client(source.id, 7, 50, 15).unwrap();
    assert_eq!(mux.set_terminal_size_counts(source.id, "c7", Some(false)), Some(true));
    assert_eq!(source.size(), (111, 33));
    assert_eq!(mux.new_workspace(None, None).unwrap().size(), (111, 33));
}

#[test]
fn terminal_size_policy_changes_publish_size_state() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    mux.pin_latest_size_policy_for_test(surface.id);
    let workspace = mux.surface_workspace(surface.id).unwrap();
    mux.resize_surface_for_client(surface.id, 0, 150, 30).unwrap();
    mux.resize_surface_for_client(surface.id, 7, 118, 42).unwrap();
    assert_eq!(surface.size(), (118, 42));
    let events = mux.subscribe();

    mux.set_workspace_size_policy(
        workspace,
        Some(TerminalSizingPolicy::new(
            crate::sizing_policy::TerminalSizingMode::Smallest,
            Vec::new(),
            None,
        )),
    )
    .unwrap();
    assert_eq!(surface.size(), (118, 30));
    let published = (0..8)
        .filter_map(|_| events.recv_timeout(Duration::from_secs(1)).ok())
        .find_map(|event| match event {
            MuxEvent::SizeStateChanged { surface: event_surface, state, .. }
                if event_surface == surface.id =>
            {
                Some(state)
            }
            _ => None,
        })
        .expect("policy change publishes size state");
    assert_eq!(published.reason, TerminalSizingReason::Smallest);
    assert_eq!(published.owners, ["c0", "c7"]);
    let generation = published.generation;

    // A terminal override beats the workspace default.
    let state = mux
        .set_terminal_size_policy(
            surface.id,
            Some(TerminalSizingPolicy::new(
                crate::sizing_policy::TerminalSizingMode::Fixed,
                Vec::new(),
                Some(TerminalGridSize::new(100, 25)),
            )),
        )
        .unwrap();
    assert_eq!(state.generation, generation + 1);
    assert_eq!(state.reason, TerminalSizingReason::Fixed);
    assert_eq!(surface.size(), (100, 25));

    // Clearing the override falls back to the workspace default.
    let state = mux.set_terminal_size_policy(surface.id, None).unwrap();
    assert_eq!(state.reason, TerminalSizingReason::Smallest);
    assert_eq!(surface.size(), (118, 30));
}
