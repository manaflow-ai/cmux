use std::time::Duration;

use {super::*, crate::local_actor::TuiMuxOps};

fn args(values: &[&str]) -> Args {
    parse_args_result(values.iter().map(|value| value.to_string())).unwrap()
}

#[test]
fn startup_value_scanner_rejects_missing_values() {
    for option in STARTUP_VALUE_OPTIONS.iter().copied() {
        let args = [option].map(str::to_string);
        assert_eq!(startup_option_value_end(&args, 0), None, "{option} accepted no value");
    }

    for option in ["--socket", "--session", "--machine"] {
        let mut args = [option].map(str::to_string).to_vec();
        rewrite_server_start(&mut args);
        assert_eq!(args, [option].map(str::to_string));
    }
}

#[test]
fn local_owner_event_dispatches_reload_to_the_shared_mutation_path() {
    let applied = std::cell::Cell::new(false);

    dispatch_local_owner_event(&cmux_tui_core::MuxEvent::ConfigReloadRequested, || {
        applied.set(true);
    });

    assert!(applied.get());
}

#[test]
fn local_owner_reload_subscription_ignores_unrelated_event_overflow() {
    let mux = Mux::new("owner-reload-overflow", SurfaceOptions::default());
    let events = local_owner_reload_events(&mux);

    for surface in 0..=4_096 {
        mux.emit(cmux_tui_core::MuxEvent::Bell(surface));
    }
    mux.emit(cmux_tui_core::MuxEvent::ConfigReloadRequested);

    assert!(matches!(events.recv().unwrap(), cmux_tui_core::MuxEvent::ConfigReloadRequested));
    assert!(!events.overflowed());
}

#[test]
fn local_owner_event_loop_stop_wakes_without_a_mux_event() {
    let mux = Arc::new(Mux::new("owner-event-stop", SurfaceOptions::default()));
    let event_loop = start_local_owner_event_loop(&mux);
    let stop = event_loop.stop_handle();
    let (done_tx, done_rx) = std::sync::mpsc::sync_channel(1);

    stop.close();
    std::thread::spawn(move || done_tx.send(event_loop.finish()).unwrap());
    let stopped_without_event = match done_rx.recv_timeout(Duration::from_secs(1)) {
        Ok(result) => {
            result.unwrap();
            true
        }
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => false,
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            panic!("owner event loop join observer disconnected")
        }
    };
    if !stopped_without_event {
        mux.emit(cmux_tui_core::MuxEvent::ConfigReloadRequested);
        done_rx.recv_timeout(Duration::from_secs(2)).unwrap().unwrap();
    }

    assert!(stopped_without_event, "owner event loop required a mux event to stop");
}

#[test]
fn interactive_owner_event_loop_defers_reload_completion_to_the_app() {
    let mux = Arc::new(Mux::new("interactive-owner-reload", SurfaceOptions::default()));
    let event_loop = start_local_owner_event_loop(&mux);
    let worker_mux = mux.clone();
    let (result_tx, result_rx) = std::sync::mpsc::sync_channel(1);
    let worker = std::thread::spawn(move || {
        result_tx.send(worker_mux.request_config_reload()).unwrap();
    });

    assert!(matches!(
        result_rx.recv_timeout(Duration::from_millis(100)),
        Err(std::sync::mpsc::RecvTimeoutError::Timeout)
    ));
    let request = mux.begin_config_reload_application();
    mux.complete_config_reload_application(request);
    result_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
    worker.join().unwrap();
    event_loop.finish().unwrap();
}

#[test]
fn interactive_owner_uses_only_the_app_reload_path() {
    assert_eq!(background_owner_reload_completion(false), None);
    assert_eq!(background_owner_reload_completion(true), Some(true));
}

#[cfg(unix)]
#[test]
fn remote_shutdown_failure_still_stops_the_mux_and_removes_the_socket() {
    let socket_path = std::env::temp_dir().join(format!(
        "cmux-remote-shutdown-{}-{}.sock",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::write(&socket_path, b"test socket marker").unwrap();
    let mux = Mux::new("remote-shutdown-failure", SurfaceOptions::default());

    let error = finish_server_shutdown(
        Some(()),
        &mux,
        &socket_path,
        Err::<Option<()>, _>(anyhow::anyhow!("injected remote shutdown failure")),
        Ok(()),
    )
    .unwrap_err()
    .to_string();

    assert!(error.contains("injected remote shutdown failure"), "{error}");
    assert!(mux.daemon_shutdown_requested());
    assert!(!socket_path.exists());
}

#[cfg(unix)]
#[test]
fn normal_server_cleanup_disarms_the_fallback_guard() {
    let socket_path = std::env::temp_dir().join(format!(
        "cmux-normal-shutdown-{}-{}.sock",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::write(&socket_path, b"test socket marker").unwrap();
    let mux = Mux::new("normal-shutdown", SurfaceOptions::default());
    let mut cleanup = ServedMuxCleanup::new(mux.clone(), socket_path.clone());

    finish_server_shutdown(
        Some(()),
        &mux,
        &socket_path,
        Ok::<Option<()>, anyhow::Error>(None),
        Ok(()),
    )
    .unwrap();
    cleanup.disarm();

    assert!(cleanup.mux.is_none());
    assert!(mux.daemon_shutdown_requested());
    assert!(!socket_path.exists());
}

#[cfg(unix)]
#[test]
fn absent_socket_recovery_only_shows_reset_when_supported() {
    let messages = &localization::catalog_for_locale("en_US.UTF-8").startup;
    let state_root = Path::new("/tmp/cmux state");
    let supported = absent_socket_schema_recovery(
        messages,
        "future-session",
        Some(state_root),
        ResetStateRecoverySupport::Supported,
    );
    assert!(supported.contains("no server is listening on this socket"), "{supported}");
    assert!(supported.contains("reset-state"), "{supported}");
    assert!(supported.contains("--state '/tmp/cmux state'"), "{supported}");

    let main_supported = absent_socket_schema_recovery(
        messages,
        "main",
        Some(state_root),
        ResetStateRecoverySupport::Supported,
    );
    assert!(
        main_supported.contains("cmux session 'main' reset-state --state '/tmp/cmux state'"),
        "{main_supported}"
    );

    let unsupported = absent_socket_schema_recovery(
        messages,
        "future-session",
        Some(state_root),
        ResetStateRecoverySupport::Unsupported,
    );
    assert!(unsupported.contains("no server is listening on this socket"), "{unsupported}");
    assert!(unsupported.contains("scoped saved-state reset is not supported"), "{unsupported}");
    assert!(!unsupported.contains("reset-state"), "{unsupported}");
}

#[cfg(unix)]
#[test]
fn remote_host_colors_stay_client_local_across_concurrent_attaches() {
    let dark = cmux_tui_core::DefaultColors {
        fg: Some(cmux_tui_core::Rgb { r: 0xee, g: 0xee, b: 0xee }),
        bg: Some(cmux_tui_core::Rgb { r: 0x11, g: 0x11, b: 0x11 }),
        ..Default::default()
    };
    let light = cmux_tui_core::DefaultColors {
        fg: Some(cmux_tui_core::Rgb { r: 0x22, g: 0x22, b: 0x22 }),
        bg: Some(cmux_tui_core::Rgb { r: 0xee, g: 0xee, b: 0xee }),
        ..Default::default()
    };
    let mux = Mux::new(
        format!("remote-host-color-test-{}", std::process::id()),
        SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() },
    );
    mux.set_default_colors(dark);
    let authoritative = mux.new_workspace(None, Some((12, 4))).unwrap();
    let socket = cmux_tui_core::server::serve(mux.clone(), None).unwrap();

    let existing = Session::Remote(RemoteSession::connect(&socket).unwrap());
    let session::SurfaceAttach::Attached(existing_surface) =
        existing.try_surface_sized(authoritative.id, Some((12, 4))).unwrap()
    else {
        panic!("existing client did not attach");
    };
    let light_client = Session::Remote(RemoteSession::connect(&socket).unwrap());
    let session::SurfaceAttach::Attached(light_surface) =
        light_client.try_surface_sized(authoritative.id, Some((12, 4))).unwrap()
    else {
        panic!("light client did not attach");
    };

    let host_probe_called = std::cell::Cell::new(false);
    let FrontendSessionPreparation { session: _light_session, colors: light_projection } =
        prepare_frontend_session(light_client, dark, || {
            host_probe_called.set(true);
            light
        });
    assert!(host_probe_called.get(), "frontend startup must invoke the host-color probe");
    assert_eq!(
        mux.default_colors(),
        dark,
        "a second client's host colors must not mutate the shared session"
    );
    let mut existing_render = ghostty_vt::RenderState::new().unwrap();
    assert_eq!(
        existing_surface.render_frame(&mut existing_render).unwrap().frame.default_colors.0,
        dark.bg.unwrap(),
        "the already-attached dark client must stay dark"
    );
    assert_eq!(
        config::ChromeTheme::for_defaults(config::ChromeMode::Auto, light_projection),
        config::ChromeTheme::light(),
        "the light client may still project compatible local chrome"
    );

    let application_background = cmux_tui_core::Rgb { r: 0x17, g: 0x1b, b: 0x2e };
    authoritative.write_bytes(b"\x1b]11;#171b2e\x1b\\\n").unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let mut existing_render = ghostty_vt::RenderState::new().unwrap();
        let existing_background =
            existing_surface.render_frame(&mut existing_render).unwrap().frame.default_colors.0;
        let mut light_render = ghostty_vt::RenderState::new().unwrap();
        let light_background =
            light_surface.render_frame(&mut light_render).unwrap().frame.default_colors.0;
        if existing_background == application_background
            && light_background == application_background
        {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "application-authored OSC defaults did not reach both client projections"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn static_machine_catalog_notices_use_the_selected_locale() {
    const CHILD_ENV: &str = "CMUX_STATIC_MACHINE_NOTICE_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("tests::static_machine_catalog_notices_use_the_selected_locale")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese static machine notice child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let runtime = MachineRuntime::new(PathBuf::from("/tmp/static-machine-notice.sock"), vec![]);
    let active = runtime.initial_key();
    let connections = MachineConnectionHub::new(runtime.connection_connectors());
    let mut controller = StaticMachineController { runtime, active, connections, pending: None };

    assert_eq!(
        controller.perform(MachineRequest::Create).unwrap().ui.notice.as_deref(),
        Some("このマシンカタログではマシンを作成できません")
    );
    assert_eq!(
        controller
            .perform(MachineRequest::SelectProviderScope("team".into()))
            .unwrap()
            .ui
            .notice
            .as_deref(),
        Some("このマシンカタログにはプロバイダーアクションがありません")
    );
}

#[test]
fn static_machine_creation_does_not_connect_until_selected() {
    let suffix =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let socket = std::env::temp_dir()
        .join(format!("cmux-unselected-machine-{}-{suffix}.sock", std::process::id()));
    let runtime = MachineRuntime::with_creation_sources(
        socket,
        vec![],
        vec![config::MachineCreationSourceConfig {
            id: "docker".into(),
            name: "Docker".into(),
            subtitle: "container prototype".into(),
        }],
    );
    let active = runtime.initial_key();
    let connections = MachineConnectionHub::new(runtime.connection_connectors());
    let mut controller = StaticMachineController { runtime, active, connections, pending: None };

    let action =
        controller.perform(MachineRequest::CreateFrom { source_id: "docker".into() }).unwrap();
    let created = action
        .ui
        .snapshot
        .machines
        .iter()
        .find(|machine| machine.id == "prototype:docker:1")
        .unwrap()
        .key;

    assert_eq!(
        action.ui.connection_phase(created),
        machine::MachineConnectionPhase::Disconnected,
        "created machine transport must not open until the row is selected"
    );
    assert!(action.replacement.is_none(), "creation must not replace the active session");
}

#[test]
fn static_machine_controller_retains_committed_connection_leases() {
    use std::sync::atomic::AtomicUsize;

    struct CountedLease(Arc<AtomicUsize>);

    impl Drop for CountedLease {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    let dropped = Arc::new(AtomicUsize::new(0));
    let connects = Arc::new(AtomicUsize::new(0));
    let connector = |key: machine::MachineKey| {
        let dropped = Arc::clone(&dropped);
        let connects = Arc::clone(&connects);
        let connector: machine_runtime::MachineConnectFn = Arc::new(move || {
            connects.fetch_add(1, Ordering::SeqCst);
            Ok(MachineConnection {
                session: Session::Local(Mux::new(
                    format!("machine-hub-{}", key.0),
                    SurfaceOptions::default(),
                )),
                _lease: Some(Box::new(CountedLease(Arc::clone(&dropped)))),
            })
        });
        (key, connector)
    };
    let first = machine::MachineKey(1);
    let second = machine::MachineKey(2);
    let connections = MachineConnectionHub::new([connector(first), connector(second)]);

    connections.connect(first).unwrap();
    connections.connect(second).unwrap();
    connections.connect(first).unwrap();
    assert_eq!(
        dropped.load(Ordering::SeqCst),
        0,
        "switching must keep every connected machine lease warm"
    );
    assert_eq!(connects.load(Ordering::SeqCst), 2, "returning to a machine reuses its session");

    connections.close();
    assert_eq!(dropped.load(Ordering::SeqCst), 2, "all leases close with the connection hub");
}

#[test]
fn presented_connection_survives_warm_pool_eviction() {
    use std::sync::atomic::AtomicUsize;

    struct CountedLease(Arc<AtomicUsize>);

    impl Drop for CountedLease {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    let dropped = Arc::new(AtomicUsize::new(0));
    let connector = |key: machine::MachineKey| {
        let dropped = Arc::clone(&dropped);
        let connector: machine_runtime::MachineConnectFn = Arc::new(move || {
            Ok(MachineConnection {
                session: Session::Local(Mux::new(
                    format!("machine-hub-presented-{}", key.0),
                    SurfaceOptions::default(),
                )),
                _lease: Some(Box::new(CountedLease(Arc::clone(&dropped)))),
            })
        });
        (key, connector)
    };
    let first = machine::MachineKey(1);
    let second = machine::MachineKey(2);
    let third = machine::MachineKey(3);
    let connections = MachineConnectionHub::with_warm_limit(
        [connector(first), connector(second), connector(third)],
        2,
    );

    // `first` is presented but has the OLDEST use stamp once the others
    // connect - exactly the shape where plain LRU would evict the
    // session still on screen mid-switch.
    connections.connect(first).unwrap();
    connections.note_presented(Some(first));
    connections.connect(second).unwrap();
    connections.connect(third).unwrap();
    assert_eq!(dropped.load(Ordering::SeqCst), 1, "one eviction past the limit");

    let (_, reused) = connections.connect_tracked(first).unwrap();
    assert!(reused, "the presented machine's connection must survive eviction");

    connections.close();
}

#[test]
fn connection_hub_evicts_least_recently_used_beyond_the_warm_limit() {
    use std::sync::atomic::AtomicUsize;

    struct CountedLease(Arc<AtomicUsize>);

    impl Drop for CountedLease {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    let dropped = Arc::new(AtomicUsize::new(0));
    let connects = Arc::new(AtomicUsize::new(0));
    let connector = |key: machine::MachineKey| {
        let dropped = Arc::clone(&dropped);
        let connects = Arc::clone(&connects);
        let connector: machine_runtime::MachineConnectFn = Arc::new(move || {
            connects.fetch_add(1, Ordering::SeqCst);
            Ok(MachineConnection {
                session: Session::Local(Mux::new(
                    format!("machine-hub-lru-{}", key.0),
                    SurfaceOptions::default(),
                )),
                _lease: Some(Box::new(CountedLease(Arc::clone(&dropped)))),
            })
        });
        (key, connector)
    };
    let first = machine::MachineKey(1);
    let second = machine::MachineKey(2);
    let third = machine::MachineKey(3);
    let connections = MachineConnectionHub::with_warm_limit(
        [connector(first), connector(second), connector(third)],
        2,
    );

    let (_, reused) = connections.connect_tracked(first).unwrap();
    assert!(!reused, "first connect opens fresh");
    connections.connect(second).unwrap();
    assert_eq!(dropped.load(Ordering::SeqCst), 0, "two warm connections fit the limit");

    connections.connect(third).unwrap();
    assert_eq!(
        dropped.load(Ordering::SeqCst),
        1,
        "a third connection evicts the least recently used one"
    );

    // `second` stayed warm; returning to it is a reuse, not a reconnect.
    let (_, reused) = connections.connect_tracked(second).unwrap();
    assert!(reused, "recently used connections survive eviction");
    assert_eq!(connects.load(Ordering::SeqCst), 3);

    // `first` was evicted back to Disconnected; its connector reconnects.
    let (_, reused) = connections.connect_tracked(first).unwrap();
    assert!(!reused, "evicted machines reconnect through their connector");
    assert_eq!(connects.load(Ordering::SeqCst), 4);
    assert_eq!(dropped.load(Ordering::SeqCst), 2, "reconnecting evicted the next oldest");

    connections.close();
    assert_eq!(dropped.load(Ordering::SeqCst), 4, "all leases close with the connection hub");
}

#[cfg(unix)]
#[test]
fn unix_provider_uses_the_edge_supplied_bearer() {
    use std::os::unix::net::UnixListener;
    use std::time::{SystemTime, UNIX_EPOCH};

    let suffix = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let socket = std::env::temp_dir()
        .join(format!("cmux-provider-token-{}-{suffix}.sock", std::process::id()));
    let listener = UnixListener::bind(&socket).unwrap();
    let connector = provider_connector_with_unix_token(
        ProviderLaunch::Unix(socket.clone()),
        CapturedProviderToken::from_value(OsString::from("edge-fixed-token")),
    )
    .unwrap();

    let connection = connector.connect().unwrap();
    let (_server, _) = listener.accept().unwrap();
    let (token, control, _) = connection.into_parts();
    assert_eq!(token.expose(), "edge-fixed-token");

    drop(control);
    drop(listener);
    std::fs::remove_file(socket).unwrap();
}

#[cfg(unix)]
#[test]
fn provider_token_errors_never_echo_the_secret() {
    let secret = "do-not-print\nthis-secret";
    let error = parse_provider_token(OsString::from(secret)).unwrap_err().to_string();
    assert_eq!(error, "machine-provider credential is invalid");
    assert!(!error.contains(secret));
    assert!(!error.contains("do-not-print"));
}

#[cfg(target_os = "linux")]
fn initial_environment_contains(needle: &[u8]) -> bool {
    unsafe {
        let mut cursor = environ;
        while !cursor.is_null() && !(*cursor).is_null() {
            if CStr::from_ptr(*cursor)
                .to_bytes()
                .windows(needle.len())
                .any(|window| window == needle)
            {
                return true;
            }
            cursor = cursor.add(1);
        }
    }
    false
}

#[cfg(target_os = "linux")]
#[test]
fn linux_provider_authority_process_is_non_dumpable_and_scrubs_env() {
    const CHILD_MARKER: &str = "CMUX_TEST_PROVIDER_DUMPABLE_CHILD";
    const TOKEN: &str = "test-provider-token";
    const AUTHORITY: &str = "provider-workspace-authority-linux-test-00000001";
    if std::env::var_os(CHILD_MARKER).is_some() {
        assert!(initial_environment_contains(TOKEN.as_bytes()));
        assert!(initial_environment_contains(AUTHORITY.as_bytes()));
        harden_provider_secret_process().unwrap();
        let dumpable = unsafe { libc::prctl(libc::PR_GET_DUMPABLE, 0, 0, 0, 0) };
        assert_eq!(dumpable, 0);
        let authority =
            CapturedProviderWorkspaceAuthority::capture().into_authority().unwrap().unwrap();
        assert_eq!(format!("{authority:?}"), "ProviderWorkspaceAuthority([redacted])");
        remove_secret_environment_variable(MACHINE_PROVIDER_TOKEN_ENV);
        assert!(std::env::var_os(MACHINE_PROVIDER_TOKEN_ENV).is_none());
        assert!(std::env::var_os(PROVIDER_WORKSPACE_AUTHORITY_ENV).is_none());
        assert!(!initial_environment_contains(TOKEN.as_bytes()));
        assert!(!initial_environment_contains(AUTHORITY.as_bytes()));
        match std::fs::read("/proc/self/environ") {
            Ok(process_environment) => {
                assert!(
                    !process_environment
                        .windows(TOKEN.len())
                        .any(|window| window == TOKEN.as_bytes())
                );
                assert!(
                    !process_environment
                        .windows(AUTHORITY.len())
                        .any(|window| window == AUTHORITY.as_bytes())
                );
            }
            Err(error) => assert_eq!(error.kind(), io::ErrorKind::PermissionDenied),
        }
        return;
    }

    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "tests::linux_provider_authority_process_is_non_dumpable_and_scrubs_env",
            "--nocapture",
        ])
        .env(CHILD_MARKER, "1")
        .env(MACHINE_PROVIDER_TOKEN_ENV, TOKEN)
        .env(PROVIDER_WORKSPACE_AUTHORITY_ENV, AUTHORITY)
        .status()
        .unwrap();
    assert!(status.success());
}

#[test]
fn provider_resolution_rejects_conflicts_and_limits_static_overlay() {
    let mut config = config::Config::default();
    let parsed = args(&["--machine-provider", "/tmp/provider.sock", "--cloud"]);
    let error = resolve_provider_launch(&parsed, &config).unwrap_err().to_string();
    assert!(error.contains("choose only one provider mode"), "{error}");

    let parsed =
        args(&["--machine-provider-command", "provider", "--", "--cloud-host", "edge.example.com"]);
    let error = resolve_provider_launch(&parsed, &config).unwrap_err().to_string();
    assert!(error.contains("choose only one provider mode"), "{error}");

    config.machines.push(config::MachineConfig {
        id: "local-agents".into(),
        name: "Local agents".into(),
        subtitle: String::new(),
        target: config::MachineTargetConfig::Unix {
            socket: PathBuf::from("/tmp/local-agents.sock"),
        },
    });
    assert!(matches!(
        resolve_provider_launch(&args(&["--cloud"]), &config).unwrap(),
        Some(ProviderLaunch::Cloud(_))
    ));
    let error =
        resolve_provider_launch(&args(&["--machine-provider", "/tmp/provider.sock"]), &config)
            .unwrap_err()
            .to_string();
    assert!(error.contains("only be combined with the local cloud"), "{error}");
}

#[test]
fn startup_help_localizes_the_machine_agent_entrypoint() {
    let english = usage_for_platform(localization::catalog_for_locale("en_US.UTF-8"), true);
    assert!(english.contains("cmux machine-agent"));
    assert!(english.contains("Share one local session through the configured host"));
    assert!(english.contains("cmux daemon <ACTION>"));
    assert!(english.contains("Stop a replaceable SSH sidecar explicitly"));
    let japanese = usage_for_platform(localization::catalog_for_locale("ja_JP.UTF-8"), true);
    assert!(japanese.contains("cmux machine-agent"));
    assert!(japanese.contains("設定したホスト経由でローカルセッションを共有"));
    assert!(japanese.contains("cmux daemon <操作>"));
    assert!(japanese.contains("置換可能な SSH サイドカーを明示的に停止"));
    assert!(!japanese.contains("Share one local session"));
    assert!(!japanese.contains("Stop authenticated remote access explicitly"));
}

#[test]
fn provider_mode_rejects_server_and_attach_options_before_connecting() {
    let parsed = args(&[
        "attach",
        "--cloud",
        "--session",
        "agents",
        "--socket",
        "/tmp/session.sock",
        "--headless",
        "--ws",
        "127.0.0.1:7681",
        "--ws-token",
        "secret",
        "--ws-insecure-bind",
        "--remote-ws",
        "127.0.0.1:8443",
        "--term",
        "xterm-direct",
    ]);

    let error = validate_provider_process_args(&parsed).unwrap_err().to_string();
    for conflict in [
        "attach",
        "--session",
        "--socket",
        "--headless",
        "--ws",
        "--ws-token",
        "--ws-insecure-bind",
        "remote daemon options",
        "--term",
    ] {
        assert!(error.contains(conflict), "missing {conflict:?} in {error:?}");
    }
}

#[test]
fn existing_session_reuse_preserves_machine_client_mode() {
    let mut config = config::Config::default();
    assert_eq!(session_client_mode(&config), SessionClientMode::Plain);

    config.machine_sidebar.enabled = true;
    assert_eq!(session_client_mode(&config), SessionClientMode::Machines);

    config.machine_sidebar.enabled = false;
    config.machines.push(config::MachineConfig {
        id: "build-host".into(),
        name: "Build host".into(),
        subtitle: String::new(),
        target: config::MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/build-host.sock") },
    });
    assert_eq!(session_client_mode(&config), SessionClientMode::Machines);
}
