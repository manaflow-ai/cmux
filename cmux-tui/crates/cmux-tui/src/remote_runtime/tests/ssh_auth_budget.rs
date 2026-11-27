//! SSH authentication does not count against the startup budget (issue
//! 38157). A person typing a password on a slow host used to run the
//! 90 s startup deadline out before the carrier could start.

use super::*;

/// The fake master "authenticates" (a person typing) for longer than the
/// whole startup budget, then fails as a wrong password does. The startup
/// must wait for that answer and report it, not its own deadline.
#[test]
fn startup_deadline_waits_for_ssh_authentication() {
    let directory = tempfile::tempdir().unwrap();
    let script = directory.path().join("ssh");
    let log = directory.path().join("ssh.log");
    write_executable(
        &script,
        format!(
            "#!/bin/sh\nfor argument in \"$@\"; do\n  if [ \"$argument\" = ControlMaster=yes ]; then\n    echo master >> '{log}'\n    sleep 3\n    exit 255\n  fi\ndone\necho direct >> '{log}'\nexit 255\n",
            log = log.display()
        ),
    );
    let ssh = SshProviderConfig {
        ssh_binary: script.to_string_lossy().into_owned(),
        connection_share: cmux_remote::ssh_control::SshConnectionShare::new(),
        ..SshProviderConfig::default()
    };
    let providers = Arc::new(
        client_provider_registry(ssh.clone(), BTreeMap::new(), IrohPathMode::Auto, None, false)
            .unwrap(),
    );
    let routes = vec![
        ResolvedRouteCandidate::resolve(
            Url::parse("ssh://person@password-host").unwrap(),
            BTreeMap::new(),
            &providers,
        )
        .unwrap(),
    ];
    let startup_timeout = Duration::from_secs(1);
    let error = start_client_runtime(ClientRuntimeOptions {
        routes,
        providers,
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Carrier,
        device_name: "ssh-auth-budget-test".into(),
        session: SessionId([38; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy::default(),
        startup_timeout,
        state_dir: directory.path().join("client"),
        local_socket: Some(directory.path().join("client.sock")),
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: false,
            upgrade: false,
            forced_command: false,
            attempt_timeout: startup_timeout,
        },
    })
    .err()
    .expect("a failed authentication fails the startup");
    let message = format!("{error:#}");
    assert!(!message.contains("did not become ready"), "{message}");
    assert!(message.contains("ssh exited 255"), "{message}");
    // One authentication, and no retry that would prompt again.
    assert_eq!(fs::read_to_string(&log).unwrap(), "master\n");
}

/// Cancelling a reconnect must also cancel a master awaiting authentication.
#[tokio::test]
async fn reconnect_authentication_stops_on_shutdown() {
    let directory = tempfile::tempdir().unwrap();
    let script = directory.path().join("ssh");
    write_executable(&script, "#!/bin/sh\nexec sleep 30\n".to_string());
    let endpoint = Url::parse("ssh://person@password-host").unwrap();
    let mut options = reconnect_test_options(vec![test_route(endpoint.as_str())]);
    options.ssh = SshProviderConfig {
        ssh_binary: script.to_string_lossy().into_owned(),
        connection_share: cmux_remote::ssh_control::SshConnectionShare::new(),
        ..SshProviderConfig::default()
    };
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let prepared = [AtomicBool::new(true)];
    let attempt = RuntimeReconnectRouteAttempt {
        options: &options,
        prepared_ssh: &prepared,
        shutdown: Some(shutdown_rx),
    };
    let connect = attempt.connect(
        0,
        ConnectRequest {
            endpoint,
            session: options.session,
            lane_policy: options.lane_policy,
            routing: BTreeMap::new(),
        },
        AuthKind::Carrier,
    );
    tokio::pin!(connect);
    tokio::select! {
        result = &mut connect => panic!("authentication unexpectedly finished: {:?}", result.err()),
        () = tokio::time::sleep(Duration::from_millis(100)) => {}
    }
    shutdown_tx.send(true).unwrap();
    let error = tokio::time::timeout(Duration::from_secs(2), connect)
        .await
        .expect("shutdown must interrupt authentication")
        .err()
        .expect("cancelled reconnect must fail");
    assert!(error.to_string().contains("SSH reconnect interrupted"), "{error}");
}
