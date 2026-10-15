//! Every daemon of one uid binds its terminal hosts' sockets under the same
//! `/tmp/cmux-th-<uid>` directory, whatever its HOME or state directory
//! (`sun_path` is about 100 bytes on macOS, so the endpoint stays short), in
//! the flat directory today; a record may also name a per-install
//! subdirectory (one per session; each build has its own app session,
//! cx-t2sqm.13), where a later build binds (cx-t2sqm.18).
//! Records and liveness proofs stay in each daemon's own state directory, and
//! a daemon reaches the shared directory only through the endpoint of a
//! record it owns. This test proves that one daemon's recovery and cleanup
//! leave another daemon's host and socket untouched.

use super::*;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};

#[test]
fn a_daemon_prunes_only_its_own_hosts_in_the_shared_endpoint_directory() {
    let a = RecoveryHarness::start("shared-th-dir-a");
    let mut b = RecoveryHarness::start_without_respawn("shared-th-dir-b");
    // Same session name, different state directories.
    assert_eq!(a.session, b.session);
    assert_ne!(a.host_root(), b.host_root());

    let (a_terminal, _) = run_cat_workspace(&a.socket, 1, "daemon-a");
    let (b_terminal, _) = run_cat_workspace(&b.socket, 1, "daemon-b");
    let (a_path, a_record) = wait_for_host_records(&a.host_root(), 1).remove(0);
    let (_, b_record) = wait_for_host_records(&b.host_root(), 1).remove(0);
    let a_endpoint = PathBuf::from(&a_record.endpoint);
    let b_endpoint = PathBuf::from(&b_record.endpoint);
    assert_eq!(a_endpoint.parent(), b_endpoint.parent(), "the endpoint directory is not shared");
    assert_ne!(a_endpoint, b_endpoint);

    // Daemon B loses its host while it is down, then restarts and prunes the
    // dead record and its socket.
    b.signal_daemon(libc::SIGSTOP);
    // SAFETY: the record PID is daemon B's own terminal host.
    assert_eq!(unsafe { libc::kill(b_record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    b.sigkill();
    b.restart();
    wait_for_no_host_records_within(&b.host_root(), test_timeout(Duration::from_secs(15)));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while b_endpoint.exists() {
        assert!(Instant::now() < deadline, "daemon B left its dead host's socket");
        std::thread::sleep(Duration::from_millis(10));
    }

    // Daemon B never adopted daemon A's host and did not touch its socket.
    assert!(!tree_terminal_ids(&b.socket).contains(&a_terminal));
    assert!(tree_terminal_ids(&a.socket).contains(&a_terminal));
    assert!(!tree_terminal_ids(&a.socket).contains(&b_terminal));
    assert!(
        fs::symlink_metadata(&a_endpoint).is_ok_and(|metadata| metadata.file_type().is_socket()),
        "daemon B's cleanup removed daemon A's host socket"
    );
    assert_eq!(
        terminal_host_record_liveness(&a_path, &a_record).unwrap(),
        TerminalHostLiveness::Live
    );

    // Daemon A's host still serves its terminal and its renderers.
    let resolved = request(
        &a.socket,
        serde_json::json!({"id": 2, "cmd": "resolve-terminal", "terminal_id": &a_terminal}),
    );
    let surface = resolved["surface"].as_u64().unwrap();
    let marker = format!("shared-dir-survivor-{}", std::process::id());
    request(
        &a.socket,
        serde_json::json!({"id": 3, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&a.socket, surface, &marker).contains(&marker));
    let grant = request(
        &a.socket,
        serde_json::json!({"id": 4, "cmd": "mint-terminal-renderer", "surface": surface, "ttl_ms": 10_000}),
    );
    connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .expect("daemon A's host stopped accepting renderers");
}

/// cx-t2sqm.13: daemons of two installs (two sessions: each build has its
/// own app session) bind their hosts' sockets in two per-install
/// directories under the shared `/tmp/cmux-th-<uid>`, so one build's socket
/// cleanup never reaches another build's sockets; both endpoints stay short.
/// This build accepts the per-install path but binds flat by default (two
/// phases, cx-t2sqm.18); the debug seam makes it bind per-install here, and
/// a restarted daemon adopts a host at that path.
#[test]
fn hosts_of_two_installs_bind_in_two_install_directories() {
    let mut a = RecoveryHarness::start_unstarted("install-dir-a");
    a.extra_env.push(("CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT".into(), "1".into()));
    a.restart();
    let mut b = RecoveryHarness::start_unstarted("install-dir-b");
    b.session = "host-recovery-other-install".into();
    b.extra_env.push(("CMUX_TUI_TEST_HOST_INSTALL_ENDPOINT".into(), "1".into()));
    b.restart();
    assert_ne!(a.session, b.session);

    run_cat_workspace(&a.socket, 1, "install-a");
    run_cat_workspace(&b.socket, 1, "install-b");
    let (_, a_record) = wait_for_host_records(&a.host_root(), 1).remove(0);
    let (_, b_record) = wait_for_host_records(&b.host_root(), 1).remove(0);
    let a_endpoint = PathBuf::from(&a_record.endpoint);
    let b_endpoint = PathBuf::from(&b_record.endpoint);
    let a_dir = a_endpoint.parent().unwrap();
    let b_dir = b_endpoint.parent().unwrap();
    assert_ne!(a_dir, b_dir, "two installs share a socket directory");
    assert_eq!(a_dir.parent(), b_dir.parent(), "the install directories are not siblings");
    // SAFETY: getuid has no preconditions.
    let shared = PathBuf::from(format!("/tmp/cmux-th-{}", unsafe { libc::getuid() }));
    assert_eq!(a_dir.parent(), Some(shared.as_path()));
    for endpoint in [&a_endpoint, &b_endpoint] {
        assert!(endpoint.as_os_str().len() < 104, "endpoint too long for sun_path: {endpoint:?}");
        assert!(
            fs::symlink_metadata(endpoint).is_ok_and(|metadata| metadata.file_type().is_socket()),
            "no host socket at {endpoint:?}"
        );
    }
    let mode = fs::symlink_metadata(a_dir).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700, "the install directory is not private");

    // A daemon that binds flat (the default) adopts the per-install host
    // after a restart: the record validates and the host keeps serving.
    let (a_terminal, a_host) = (a_record.terminal_id.clone(), a_record.host_pid);
    a.extra_env.clear();
    a.sigkill();
    a.restart();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    let surface = loop {
        let resolved = request(
            &a.socket,
            serde_json::json!({"id": 5, "cmd": "resolve-terminal", "terminal_id": &a_terminal}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "the per-install host was not adopted: {resolved}");
        std::thread::sleep(Duration::from_millis(50));
    };
    let marker = format!("install-dir-adopted-{}", std::process::id());
    request(
        &a.socket,
        serde_json::json!({"id": 6, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&a.socket, surface, &marker).contains(&marker));
    assert_eq!(wait_for_host_records(&a.host_root(), 1)[0].1.host_pid, a_host);
}
