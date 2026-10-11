//! View close side tables, replayed closes, and failed browser attach.

use super::*;

#[test]
fn closing_a_view_preserves_terminal_side_tables_until_explicit_close() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    // A second tab keeps the pane live after the terminal view detaches.
    let second = mux.new_tab(Some(pane), None, None).unwrap();
    let host =
        mux.resource_terminal_host_identity(&first).expect("test terminal has a host identity");

    mux.report_agent(first.id, AgentState::Working, AgentSource::Socket, Some("conf".to_string()))
        .unwrap();
    mux.post_notification(
        "Build".to_string(),
        "ok".to_string(),
        NotificationLevel::Warning,
        Some(first.id),
    )
    .unwrap();
    assert_eq!(mux.list_agents(Some(first.id), None).len(), 1);
    assert!(mux.surface_notification(first.id).is_some());

    mux.close_surface(first.id).unwrap();

    assert_eq!(mux.list_agents(Some(first.id), None).len(), 1);
    assert_eq!(mux.list_agents(None, None).len(), 1);
    assert!(mux.surface_notification(first.id).is_some());
    assert!(mux.surface(first.id).is_some());
    assert!(mux.with_state(|state| state.surfaces.contains_key(&second.id)));

    let detached_report = mux
        .report_agent(
            first.id,
            AgentState::Blocked,
            AgentSource::Hook,
            Some("detached-hook".to_string()),
        )
        .expect("the terminal host identity remains valid without a view");
    assert_eq!(detached_report.state, AgentState::Blocked);
    assert_eq!(detached_report.session.as_deref(), Some("detached-hook"));

    mux.close_terminal(&host.terminal_id, &host.incarnation).unwrap();
    assert!(mux.list_agents(None, None).is_empty());
    assert_eq!(mux.resource_agent_projection_count_for_test().unwrap(), 1);
    assert_eq!(
        crate::resource_api::public_session_snapshot(&mux).unwrap()["agents"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert!(mux.surface_notification(first.id).is_none());
    assert!(mux.surface(first.id).is_none());
}

#[test]
fn replayed_host_close_does_not_acquire_public_resource_effects() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let host =
        mux.resource_terminal_host_identity(&surface).expect("test terminal has a host identity");
    let public_id = match &surface.resource_identity().unwrap().content_id {
        ContentPublicId::Terminal(public_id) => public_id.clone(),
        ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
    };
    let mutation = WorkspaceMutation::daemon("lost-host-close-reply", "legacy-client").unwrap();
    let resource_revision = mux.with_state(|state| state.resource_revision);

    let host_close = mux
        .workspace_registry
        .lock()
        .unwrap()
        .close_terminal(&mutation, None, None, &host.terminal_id, Some(&host.incarnation))
        .unwrap();
    assert!(!host_close.replayed);
    assert_eq!(
        mux.workspace_registry.lock().unwrap().terminal_resource_id(&host.terminal_id).unwrap(),
        Some(public_id.clone())
    );

    let retry = mux
        .close_terminal_with_mutation(
            &host.terminal_id,
            Some(&host.incarnation),
            None,
            None,
            &mutation,
        )
        .unwrap();

    assert_eq!(retry.terminal_revision, host_close.revision);
    assert_eq!(mux.with_state(|state| state.resource_revision), resource_revision);
    assert!(mux.surface(surface.id).is_some());
    assert_eq!(
        mux.workspace_registry.lock().unwrap().terminal_resource_id(&host.terminal_id).unwrap(),
        Some(public_id)
    );
}

#[test]
fn replayed_resource_close_does_not_acquire_terminal_effects() {
    let mux = test_mux();
    let surface = mux.new_workspace(None, None).unwrap();
    let host =
        mux.resource_terminal_host_identity(&surface).expect("test terminal has a host identity");
    let public_id = match &surface.resource_identity().unwrap().content_id {
        ContentPublicId::Terminal(public_id) => public_id.clone(),
        ContentPublicId::Browser(_) => panic!("workspace opened a browser"),
    };
    let host_close = mux
        .workspace_registry
        .lock()
        .unwrap()
        .close_terminal(
            &WorkspaceMutation::daemon("closed-host", "legacy-client").unwrap(),
            None,
            None,
            &host.terminal_id,
            Some(&host.incarnation),
        )
        .unwrap();
    let mutation =
        WorkspaceMutation::daemon("lost-resource-close-reply", "resource-client").unwrap();
    let fingerprint = serde_json::json!({
        "op":"close-terminal",
        "terminal_id":host.terminal_id,
        "incarnation":host.incarnation,
    });
    let resource_revision = mux.with_state(|state| state.resource_revision);
    let resource_close = mux
        .workspace_registry
        .lock()
        .unwrap()
        .commit_resource_patch(
            &mutation,
            "terminal.close",
            &fingerprint,
            None,
            Some(resource_revision),
            &ResourcePatch { changes: Vec::new() },
            &serde_json::json!({}),
            &serde_json::json!([]),
        )
        .unwrap();

    let retry = mux
        .close_terminal_with_mutation(
            &host.terminal_id,
            Some(&host.incarnation),
            None,
            None,
            &mutation,
        )
        .unwrap();

    assert!(retry.already_closed);
    assert_eq!(retry.terminal_revision, host_close.revision);
    assert_eq!(mux.with_state(|state| state.resource_revision), resource_close.revision);
    assert!(mux.surface(surface.id).is_some());
    assert_eq!(
        mux.workspace_registry.lock().unwrap().terminal_resource_id(&host.terminal_id).unwrap(),
        Some(public_id)
    );
}

#[test]
fn failed_browser_surface_attach_kills_worker() {
    let mux = test_mux();
    let opts = mux.surface_options.lock().unwrap().clone();
    let surface = browser::new_surface(
        999,
        "https://example.test".to_string(),
        (10, 5),
        (8, 16),
        &opts,
        Arc::downgrade(&mux),
    )
    .unwrap();
    let browser = surface.as_browser().expect("browser surface");
    let done = browser.take_worker_done_for_test();

    assert!(matches!(
        mux.attach_browser_surface_to_pane_or_kill(123_456, &surface, 1),
        BrowserSurfaceAttach::MissingPane
    ));
    assert!(browser.is_dead());
    done.recv_timeout(Duration::from_secs(1)).expect("browser worker exited after failed attach");
}
