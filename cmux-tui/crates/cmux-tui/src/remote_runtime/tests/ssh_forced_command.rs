//! An SSH route whose key forces `remote-link` (the Cloud carrier key,
//! `command="cmux-tui remote-link --stdio ..."`) never runs `remote-probe` or
//! an install over that key: anything the client asks runs the link instead.
//! A dead dialer on that route still moves selection to the next route.

use super::*;

/// Bounds a step that waits for an event (a real handshake, a selection
/// result). A passing run never waits this long.
const HANG_GUARD: Duration = Duration::from_secs(30);

/// A stand-in `ssh` that logs its arguments, prints `stdout`, and exits with
/// `status`.
fn fake_ssh(directory: &Path, stdout: &str, status: u8) -> (SshProviderConfig, PathBuf) {
    let script = directory.join("ssh");
    let log = directory.join("ssh.log");
    write_executable(
        &script,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nprintf '%s' '{stdout}'\nexit {status}\n",
            log.display(),
        ),
    );
    let ssh = SshProviderConfig {
        ssh_binary: script.to_string_lossy().into_owned(),
        ..SshProviderConfig::default()
    };
    (ssh, log)
}

fn logged_lines(log: &Path, needle: &str) -> usize {
    fs::read_to_string(log).unwrap_or_default().lines().filter(|line| line.contains(needle)).count()
}

#[tokio::test]
async fn forced_command_reconnect_route_is_never_probed() {
    let directory = tempfile::tempdir().unwrap();
    // A probe answer is never read: if the client did probe, the run would
    // pass the bootstrap and the probe count below would catch it.
    let (ssh, log) = fake_ssh(directory.path(), "", 0);
    let mut options = reconnect_test_options(vec![
        test_route("wss://initial.example/v1/link"),
        test_route("ssh://cmux@10.0.0.7"),
    ]);
    options.providers = test_providers(ssh.clone());
    options.ssh = ssh;
    options.ssh_bootstrap.forced_command = true;
    options.ssh_bootstrap.attempt_timeout = HANG_GUARD;
    let source = RuntimeReconnectGroups::new(options, 0);

    assert_eq!(
        source.resolution_timeout(Duration::from_millis(20)),
        Duration::from_millis(40),
        "a forced-command SSH route must not reserve a remote-probe budget"
    );
    // The group describes its route without the user name.
    assert_eq!(
        source.next_group().await.unwrap().description(),
        sanitized_route(&Url::parse("ssh://cmux@10.0.0.7").unwrap())
    );
    assert_eq!(logged_lines(&log, "remote-probe"), 0, "a forced-command route was probed");
}

#[tokio::test]
async fn forced_command_bootstrap_spawns_nothing() {
    let directory = tempfile::tempdir().unwrap();
    let missing = directory.path().join("no-such-ssh");
    let ssh = SshProviderConfig {
        ssh_binary: missing.to_string_lossy().into_owned(),
        ..SshProviderConfig::default()
    };
    let endpoint = Url::parse("ssh://cmux@10.0.0.7").unwrap();
    let mut options = SshBootstrapOptions {
        auto_install: true,
        upgrade: false,
        attempt_timeout: HANG_GUARD,
        forced_command: true,
    };

    bootstrap_initial_ssh_route(&endpoint, &ssh, options, false, None)
        .await
        .expect("a forced-command route ran the SSH bootstrap");

    options.forced_command = false;
    bootstrap_initial_ssh_route(&endpoint, &ssh, options, false, None)
        .await
        .expect_err("the control run must reach the missing ssh binary");
}

/// Fault: the forced-command route's dialer dies (ssh exits 255, as it does
/// when its `ProxyCommand`, `cmux wg dial`, cannot reach the machine). The
/// client ran the link directly, never a probe, and selection moved on to
/// the next route instead of failing the start.
#[tokio::test]
async fn forced_command_route_with_a_dead_dialer_falls_back_to_the_next_route() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_auth =
        AuthDatabase::load_or_create(directory.path().join("daemon"), "forced-command", true)
            .unwrap();
    let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
    let unix_path = directory.path().join("daemon.sock");
    let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

    let (ssh, log) = fake_ssh(directory.path(), "", 255);
    let providers = test_providers(ssh.clone());
    let routes = [Url::parse("ssh://cmux@10.0.0.7").unwrap(), unix_test_route(&unix_path)]
        .into_iter()
        .map(|route| ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap())
        .collect();
    let mut options = reconnect_test_options(routes);
    options.providers = providers;
    options.ssh = ssh;
    options.auth = ClientAuthMode::Carrier;
    options.ssh_bootstrap.forced_command = true;
    options.ssh_bootstrap.attempt_timeout = HANG_GUARD;
    options.reconnect.maximum_attempts = Some(1);
    options.reconnect.full_jitter = false;
    options.reconnect.attempt_timeout = HANG_GUARD;
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);

    let (connection, selected) =
        tokio::time::timeout(HANG_GUARD, connect_first_available(&options, shutdown_rx))
            .await
            .expect("selection hung on the dead forced-command route")
            .expect("the next route did not connect after the dialer died");

    assert_eq!(selected, format!("unix://{}", unix_path.display()));
    assert_eq!(logged_lines(&log, "remote-probe"), 0, "a forced-command route was probed");
    assert!(
        logged_lines(&log, "remote-link --stdio") >= 1,
        "the forced-command route never dialed the link: {:?}",
        fs::read_to_string(&log).unwrap_or_default()
    );
    connection.close().await.unwrap();
    server.shutdown().await.unwrap();
}
