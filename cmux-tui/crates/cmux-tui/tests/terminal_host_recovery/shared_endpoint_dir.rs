//! Every daemon of one uid binds its terminal hosts' sockets in the same
//! `/tmp/cmux-th-<uid>` directory, whatever its HOME or state directory
//! (`sun_path` is about 100 bytes on macOS, so the endpoint stays short).
//! Records and liveness proofs stay in each daemon's own state directory, and
//! a daemon reaches the shared directory only through the endpoint of a
//! record it owns. This test proves that one daemon's recovery and cleanup
//! leave another daemon's host and socket untouched.

use super::*;
use std::os::unix::fs::FileTypeExt;

#[test]
fn a_daemon_prunes_only_its_own_hosts_in_the_shared_endpoint_directory() {
    let a = RecoveryHarness::start("shared-th-dir-a");
    let mut b = RecoveryHarness::start("shared-th-dir-b");
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
