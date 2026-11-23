use super::*;

#[test]
fn private_socket_remote_mux_owner_derives_its_own_socket() {
    let socket = Path::new("/tmp/cmux-tui-501/work.sock");
    assert_eq!(
        mux_owner_args("work", socket, true, None),
        ["--headless", "--session", "work", "--terminal-reap-grace-seconds", "30"]
            .map(OsString::from)
    );
    assert_eq!(
        mux_owner_args("work", socket, false, None),
        [
            "--headless",
            "--session",
            "work",
            "--terminal-reap-grace-seconds",
            "30",
            "--socket",
            "/tmp/cmux-tui-501/work.sock",
        ]
        .map(OsString::from)
    );
}

#[test]
fn a_state_dir_gives_the_mux_owner_its_own_state_root() {
    let socket = Path::new("/srv/state/sessions/d29yaw/mux.sock");
    assert_eq!(
        mux_owner_args("work", socket, false, Some(Path::new("/srv/state"))),
        [
            "--headless",
            "--session",
            "work",
            "--terminal-reap-grace-seconds",
            "30",
            "--socket",
            "/srv/state/sessions/d29yaw/mux.sock",
            "--state",
            "/srv/state/workspace",
        ]
        .map(OsString::from)
    );
}

/// A paired server's brain daemon is down: remote-link refuses and starts
/// neither a mux owner at the brain's socket nor a sidecar.
#[test]
fn explicit_mux_socket_is_attach_only() {
    let directory = tempfile::tempdir().unwrap();
    let session = "server-attach";
    let (session_state, link, _) =
        crate::remote_runtime::daemon_paths(session, Some(directory.path())).unwrap();
    let brain = directory.path().join("brain-daemon.sock");
    let error = super::super::ensure_daemon(
        session,
        Some(directory.path()),
        &session_state,
        &link,
        Some(&brain),
    )
    .expect_err("remote-link started a daemon at an explicit mux socket");
    assert!(error.to_string().contains("is not running"), "{error:#}");
    assert!(!brain.exists(), "a mux owner was started at the explicit socket");
    assert!(!link.exists(), "a sidecar was started for a missing explicit daemon");
}
