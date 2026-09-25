use super::*;

fn mux() -> Arc<Mux> {
    let root = std::env::temp_dir()
        .join(format!("cmux-cloud-grant-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let files = [("CMUX_CLOUD_WELCOME_INSTANCE_PATH", "instance", "original-instance")];
    let mut options = SurfaceOptions::default();
    options.extra_env.extend([
        ("CMUX_CLOUD_WELCOME".into(), "1".into()),
        ("CMUX_CLOUD_WELCOME_SHOWN".into(), String::new()),
    ]);
    for (key, file, value) in files {
        let path = root.join(file);
        std::fs::write(&path, value).unwrap();
        options.extra_env.push((key.into(), path.to_string_lossy().into_owned()));
    }
    Mux::new_for_test("cloud-bootstrap", options)
}

#[test]
fn cloud_bootstrap_defers_shell_and_serializes_first_attachments() {
    let mux = mux();
    assert!(mux.reserve_cloud_initial_workspace().unwrap());
    let first = mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert!(state.surfaces.is_empty());
        state.workspaces[0].id
    });
    assert!(mux.rename_workspace(first, "my project".into()));
    let renders = Arc::new(AtomicUsize::new(0));
    let threads = (0..8)
        .map(|_| {
            let mux = mux.clone();
            let renders = renders.clone();
            std::thread::spawn(move || {
                mux.start_cloud_initial_terminal_with_renderer(true, || {
                    renders.fetch_add(1, Ordering::Relaxed);
                    Ok(b"CLOUD-GUIDE\r\n".to_vec())
                })
                .unwrap();
            })
        })
        .collect::<Vec<_>>();
    for thread in threads {
        thread.join().unwrap();
    }
    let before = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    assert_eq!(before.terminals.len(), 1);
    assert_eq!(renders.load(Ordering::Relaxed), 1);
    mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
        .unwrap();
    assert!(mux.reserve_cloud_initial_workspace().unwrap());
    let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    assert_eq!(before, after);
    let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
    assert_eq!(
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .matches("CLOUD-GUIDE")
            .count(),
        1
    );
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].id, first);
        assert_eq!(state.workspaces[0].name, "my project");
    });
}

#[test]
fn cloud_bootstrap_does_not_claim_preexisting_or_deleted_workspaces() {
    let existing = mux();
    let workspace = existing.create_empty_workspace(None, None, None).unwrap();
    assert!(existing.close_workspace(workspace.workspace));
    assert!(!existing.reserve_cloud_initial_workspace().unwrap());
    existing.start_cloud_initial_terminal(true).unwrap();
    assert!(existing.with_state(|state| state.workspaces.is_empty()));

    let deleted = mux();
    deleted.reserve_cloud_initial_workspace().unwrap();
    let first = deleted.with_state(|state| state.workspaces[0].id);
    assert!(deleted.close_workspace(first));
    // Simulate startup's reservation recovery before a later attach.
    assert!(deleted.reserve_cloud_initial_workspace().unwrap());
    assert!(deleted.with_state(|state| state.workspaces.is_empty()));
    deleted.start_cloud_initial_terminal(true).unwrap();
    deleted.reserve_cloud_initial_workspace().unwrap();
    assert!(deleted.with_state(|state| state.workspaces.is_empty()));
}

#[test]
fn cloud_bootstrap_leaves_user_startup_content_untouched() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let first = mux.with_state(|state| state.workspaces[0].id);
    mux.create_terminal_in_workspace(first, Some(vec!["user-command".into()]), None, None, None)
        .unwrap();
    let before = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
        .unwrap();
    let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    assert_eq!(before, after);
}

#[test]
fn cloud_bootstrap_yields_to_public_creation_during_rendering() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let first = mux.with_state(|state| state.workspaces[0].id);
    mux.start_cloud_initial_terminal_with_renderer(true, || {
        // Public resource callers enter the execution fence directly. This
        // races at the exact gap between rendering and materialization.
        let selectors = mux.ordinary_workspace_selectors(first).unwrap();
        let fields = Map::from_iter([("argv".into(), serde_json::json!(["user-agent"]))]);
        mux.commit_resource_topology_operation(
            ResourceOperation::WorkspaceRun,
            selectors,
            fields,
            None,
            &WorkspaceMutation::local("fixture-user"),
        )
        .unwrap();
        Ok(b"CLOUD-GUIDE\r\n".to_vec())
    })
    .unwrap();
    let surface = mux.with_state(|state| {
        assert_eq!(state.surfaces.len(), 1);
        state.surfaces.values().next().unwrap().clone()
    });
    assert_eq!(surface.spawn_argv(), Some(vec!["user-agent".into()]));
    assert!(
        !surface
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .contains("CLOUD-GUIDE")
    );
    mux.start_cloud_initial_terminal_with_renderer(true, || panic!("user content owns the slot"))
        .unwrap();
}

#[test]
fn cloud_bootstrap_retries_failed_creation_without_an_extra_workspace() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let first = mux.with_state(|state| state.workspaces[0].key.clone());
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(true).unwrap();
    assert!(
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .is_err()
    );
    assert!(!mux.workspace_registry.lock().unwrap().cloud_bootstrap().unwrap().unwrap().finished);
    mux.workspace_registry.lock().unwrap().set_resource_patch_failure(false).unwrap();
    mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
        .unwrap();
    mux.with_state(|state| {
        assert_eq!(state.workspaces.len(), 1);
        assert_eq!(state.workspaces[0].key, first);
    });
    assert_eq!(
        mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap().terminals.len(),
        1
    );
    let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
    assert_eq!(
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .matches("CLOUD-GUIDE")
            .count(),
        1
    );
}

#[test]
fn cloud_bootstrap_retries_renderer_failure_before_creating_a_terminal() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    assert!(
        mux.start_cloud_initial_terminal_with_renderer(true, || {
            anyhow::bail!("fixture renderer failure")
        })
        .is_err()
    );
    assert!(mux.with_state(|state| state.surfaces.is_empty()));
    mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
        .unwrap();
    let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
    assert!(
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .contains("CLOUD-GUIDE")
    );
    mux.start_cloud_initial_terminal_with_renderer(true, || panic!("must not render twice"))
        .unwrap();
}

#[test]
fn cloud_bootstrap_retries_failed_spawn_without_reusing_dead_terminal_identity() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let workspace = mux.with_state(|state| state.workspaces[0].key.clone());
    mux.surface_options.lock().unwrap().cols = 10_000;
    assert!(
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .is_err()
    );
    assert!(mux.with_state(|state| state.surfaces.is_empty()));
    let failed = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    assert_eq!(failed.terminals.len(), 1);
    assert_eq!(failed.terminals[0].lifecycle, TerminalLifecycle::Exited);
    mux.surface_options.lock().unwrap().cols = 80;
    mux.start_cloud_initial_terminal_with_renderer(true, || panic!("reuse prepared output"))
        .unwrap();
    let after = mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap();
    let running = after
        .terminals
        .iter()
        .filter(|terminal| terminal.lifecycle == TerminalLifecycle::Running)
        .collect::<Vec<_>>();
    assert_eq!(running.len(), 1);
    assert_eq!(running[0].workspace_key, workspace);
    assert_ne!(running[0].terminal_id, failed.terminals[0].terminal_id);
    let surface = mux.with_state(|state| {
        assert_eq!(state.surfaces.len(), 1);
        state.surfaces.values().next().unwrap().clone()
    });
    assert_eq!(
        surface
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .matches("CLOUD-GUIDE")
            .count(),
        1
    );
    mux.start_cloud_initial_terminal_with_renderer(true, || panic!("already delivered")).unwrap();
    assert_eq!(after, mux.workspace_registry.lock().unwrap().terminal_snapshot().unwrap());
}

#[test]
fn cloud_bootstrap_preserves_explicit_argv_and_skips_ineligible_shells() {
    let mux = mux();
    let command = vec!["codex".into(), "exec".into(), "keep this input".into()];
    mux.surface_options.lock().unwrap().command = Some(command.clone());
    mux.reserve_cloud_initial_workspace().unwrap();
    mux.start_cloud_initial_terminal_with_renderer(true, || {
        panic!("agent startup must stay quiet")
    })
    .unwrap();
    let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
    assert_eq!(surface.spawn_argv(), Some(command));
    assert!(
        !surface
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .contains("CLOUD-GUIDE")
    );

    let quiet = Mux::new_for_test("later-machine", SurfaceOptions::default());
    quiet.reserve_cloud_initial_workspace().unwrap();
    quiet
        .start_cloud_initial_terminal_with_renderer(false, || panic!("ineligible machine"))
        .unwrap();
}

#[test]
fn cloud_bootstrap_rechecks_grant_and_suppression_for_prepared_output() {
    for suppressed in [false, true] {
        let mux = mux();
        mux.reserve_cloud_initial_workspace().unwrap();
        // Resume the durable prepare/commit boundary before a process has
        // started. A post-spawn projection failure must preserve, not erase,
        // output already accepted by that terminal.
        let mut prepared =
            mux.workspace_registry.lock().unwrap().cloud_bootstrap().unwrap().unwrap();
        prepared.prepared_output = Some(b"CLOUD-GUIDE\r\n".to_vec());
        prepared.prepared_instance = cloud_instance(&mux.surface_options.lock().unwrap());
        mux.workspace_registry.lock().unwrap().save_cloud_bootstrap(&prepared).unwrap();
        if suppressed {
            mux.surface_options
                .lock()
                .unwrap()
                .extra_env
                .push(("CMUX_CLOUD_WELCOME".into(), "0".into()));
        } else {
            // A fork can copy pending output, but the supervisor binds the
            // resumed daemon to a different platform instance before boot.
            let options = mux.surface_options.lock().unwrap();
            let path = &options
                .extra_env
                .iter()
                .find(|(key, _)| key == "CMUX_CLOUD_WELCOME_INSTANCE_PATH")
                .unwrap()
                .1;
            std::fs::write(path, "forked-instance").unwrap();
        }
        mux.start_cloud_initial_terminal_with_renderer(suppressed, || panic!("already prepared"))
            .unwrap();
        let surface = mux.with_state(|state| state.surfaces.values().next().unwrap().clone());
        assert!(
            !surface
                .with_terminal(|terminal| terminal.plain_text())
                .unwrap()
                .unwrap()
                .contains("CLOUD-GUIDE")
        );
    }
}

#[test]
fn cloud_bootstrap_rejects_missing_platform_identity_even_with_a_copied_grant() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let options = mux.surface_options.lock().unwrap().clone();
    let path = &options
        .extra_env
        .iter()
        .find(|(key, _)| key == "CMUX_CLOUD_WELCOME_INSTANCE_PATH")
        .unwrap()
        .1;
    std::fs::remove_file(path).unwrap();
    assert!(!cloud_welcome_output_allowed(&options, &Value::Null));
    assert!(!cloud_welcome_output_allowed(&options, &Value::String(String::new())));
    assert!(!cloud_welcome_output_allowed(&options, &Value::String("original-instance".into())));
    assert!(
        mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
            .is_err()
    );
    assert!(mux.with_state(|state| state.surfaces.is_empty()));
    assert!(!mux.workspace_registry.lock().unwrap().cloud_bootstrap().unwrap().unwrap().finished);
    std::fs::write(path, "original-instance").unwrap();
    mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
        .unwrap();
}
#[test]
fn cloud_bootstrap_targets_the_reserved_workspace_without_changing_focus() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let first = mux.with_state(|state| state.workspaces[0].id);
    let later = mux.new_workspace(Some("another project".into()), None).unwrap();
    let focused = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    mux.start_cloud_initial_terminal_with_renderer(true, || Ok(b"CLOUD-GUIDE\r\n".to_vec()))
        .unwrap();
    assert_eq!(mux.with_state(|state| state.workspaces[state.active_workspace].id), focused);
    assert!(
        !later
            .with_terminal(|terminal| terminal.plain_text())
            .unwrap()
            .unwrap()
            .contains("CLOUD-GUIDE")
    );
    let starter = mux.with_state(|state| {
        state.workspaces.iter().find(|workspace| workspace.id == first).unwrap().key.clone()
    });
    assert_eq!(
        mux.workspace_registry
            .lock()
            .unwrap()
            .terminal_snapshot()
            .unwrap()
            .terminals
            .iter()
            .filter(|terminal| terminal.workspace_key == starter)
            .count(),
        1
    );
}

#[test]
fn cloud_bootstrap_first_open_binds_machine_and_exact_reserved_workspace() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let first = mux.with_state(|state| state.workspaces[0].public_id.to_string());
    let unrelated = mux.create_empty_workspace(None, None, None).unwrap();
    let other = mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .find(|workspace| workspace.id == unrelated.workspace)
            .unwrap()
            .public_id
            .to_string()
    });
    let skipped = mux
        .open_cloud_initial_terminal_with_renderer(true, Some("vm-first"), Some(&other), || {
            panic!("a later workspace cannot consume the initial grant")
        })
        .unwrap();
    assert!(skipped["created_path"].is_null());
    assert!(mux.with_state(|state| state.surfaces.is_empty()));
    let first_open = mux
        .open_cloud_initial_terminal_with_renderer(true, Some("vm-first"), Some(&first), || {
            Ok(b"CLOUD-GUIDE\r\n".to_vec())
        })
        .unwrap();
    assert_eq!(first_open["created_path"]["workspace_id"], first);
    let replay = mux
        .open_cloud_initial_terminal_with_renderer(true, Some("vm-first"), Some(&first), || {
            panic!("the durable receipt owns repeat attachments")
        })
        .unwrap();
    assert_eq!(replay["created_path"], first_open["created_path"]);
    let copied = mux
        .open_cloud_initial_terminal_with_renderer(
            true,
            Some("another-machine"),
            Some(&first),
            || panic!("copied machine state cannot accept the original grant"),
        )
        .unwrap();
    assert!(copied["created_path"].is_null());
}

#[test]
fn cloud_bootstrap_closed_starter_is_not_recreated_or_replayed() {
    let mux = mux();
    mux.reserve_cloud_initial_workspace().unwrap();
    let first = mux.with_state(|state| state.workspaces[0].public_id.to_string());
    mux.open_cloud_initial_terminal_with_renderer(false, Some("vm-first"), Some(&first), || {
        panic!("ineligible first user")
    })
    .unwrap();
    let surface = mux.with_state(|state| *state.surfaces.keys().next().unwrap());
    mux.close_surface(surface).unwrap();
    let replay = mux
        .open_cloud_initial_terminal_with_renderer(true, Some("vm-first"), Some(&first), || {
            panic!("a closed first terminal never rearms the welcome")
        })
        .unwrap();
    assert!(replay["created_path"].is_null());
    assert!(mux.with_state(|state| state.surfaces.is_empty()));
}
