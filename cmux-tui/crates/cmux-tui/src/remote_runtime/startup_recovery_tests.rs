//! Each test leaves a session's remote state the way a production Cloud
//! machine was found crash-looping, shows the daemon refuses to start over it,
//! runs the startup self-recovery the session owner runs, and starts again.

use super::*;

fn options(state_root: &Path, session: &str) -> DaemonRuntimeOptions {
    DaemonRuntimeOptions {
        session: session.into(),
        state_dir: Some(state_root.to_path_buf()),
        link_socket: None,
        admin_socket: None,
        direct_websocket: None,
        allow_insecure_non_loopback: false,
        trusted_carrier_websocket: false,
        workspace_http: None,
        relays: Vec::new(),
        iroh: false,
        advertised_routes: Vec::new(),
        resume_lease: Duration::from_secs(2),
        replaceable_sidecar: true,
    }
}

fn start(
    directory: &Path,
    state_root: &Path,
    session: &str,
) -> anyhow::Result<DaemonRuntimeHandle> {
    start_daemon_runtime(directory.join("missing-mux.sock"), options(state_root, session))
}

/// Runs a daemon, then leaves its state as a kill or hard stop does: the
/// runtime record of the live lifecycle and no shutdown outcome.
fn crashed_daemon_state(directory: &Path, state_root: &Path, session: &str) -> (PathBuf, String) {
    let runtime = start(directory, state_root, session).expect("first daemon start");
    let state_dir = runtime.info().state_dir.clone();
    let lifecycle_id = runtime.info().lifecycle_id.clone().expect("lifecycle id");
    let record = fs::read(state_dir.join("runtime.json")).unwrap();
    runtime.shutdown().unwrap();
    fs::write(state_dir.join("runtime.json"), record).unwrap();
    fs::remove_file(state_dir.join("shutdown.json")).unwrap();
    (state_dir, lifecycle_id)
}

fn refusal(directory: &Path, state_root: &Path, session: &str) -> String {
    match start(directory, state_root, session) {
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("the daemon started over its predecessor's evidence");
        }
        Err(error) => format!("{error:#}"),
    }
}

fn recovers_and_starts(directory: &Path, state_root: &Path, session: &str) -> Vec<String> {
    let actions =
        recover_inactive_daemon_state(session, Some(state_root), None, None).expect("recovery");
    assert!(!actions.is_empty(), "the recovery took no action");
    let runtime = start(directory, state_root, session)
        .unwrap_or_else(|error| panic!("start after recovery {actions:?}: {error:#}"));
    runtime.shutdown().unwrap();
    // A second start needs nothing more.
    assert!(
        recover_inactive_daemon_state(session, Some(state_root), None, None).unwrap().is_empty()
    );
    start(directory, state_root, session).unwrap().shutdown().unwrap();
    actions
}

/// A fork or checkpoint clone: the supervisor drops `auth/`, the parent's
/// fence and live runtime record stay.
#[test]
fn startup_self_recovery_clears_a_clones_fence_without_authorization() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "self-recovery-clone";
    let (state_dir, _) = crashed_daemon_state(directory.path(), &state_root, session);
    fs::remove_dir_all(state_dir.join("auth")).unwrap();

    let error = refusal(directory.path(), &state_root, session);
    assert!(error.contains("explicit migration"), "{error}");

    recovers_and_starts(directory.path(), &state_root, session);
}

/// A modern predecessor's runtime record with no outcome and no fence.
#[test]
fn startup_self_recovery_clears_a_runtime_record_without_outcome() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "self-recovery-missing-outcome";
    let (state_dir, _) = crashed_daemon_state(directory.path(), &state_root, session);
    fs::remove_file(state_dir.join("lifecycle-fence.json")).unwrap();

    let error = refusal(directory.path(), &state_root, session);
    assert!(error.contains("did not publish an outcome"), "{error}");

    recovers_and_starts(directory.path(), &state_root, session);
}

/// A failed outcome of an earlier lifecycle beside a later runtime record.
#[test]
fn startup_self_recovery_clears_an_outcome_of_another_lifecycle() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "self-recovery-wrong-lifecycle";
    let (state_dir, lifecycle_id) = crashed_daemon_state(directory.path(), &state_root, session);
    persist_shutdown_outcome(
        &state_dir,
        &DaemonShutdownOutcome {
            version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
            lifecycle_id: format!("before-{lifecycle_id}"),
            status: DaemonShutdownStatus::Failed,
        },
    )
    .unwrap();

    let error = refusal(directory.path(), &state_root, session);
    assert!(error.contains("different daemon lifecycle"), "{error}");

    recovers_and_starts(directory.path(), &state_root, session);
}

/// After filesystem errors: a socket where `shutdown.json` belongs and a
/// regular file where the admin socket belongs.
#[test]
fn startup_self_recovery_moves_aside_state_with_wrong_file_types() {
    use std::os::unix::fs::FileTypeExt as _;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "self-recovery-file-types";
    let runtime = start(directory.path(), &state_root, session).unwrap();
    let info = runtime.info().clone();
    runtime.shutdown().unwrap();
    let state_dir = info.state_dir.clone();
    fs::remove_file(state_dir.join("shutdown.json")).unwrap();
    drop(std::os::unix::net::UnixListener::bind(state_dir.join("shutdown.json")).unwrap());
    fs::write(&info.admin_socket, b"not a socket").unwrap();

    let error = refusal(directory.path(), &state_root, session);
    assert!(!error.is_empty());

    let fingerprint = info.daemon_fingerprint.clone();
    let actions = recovers_and_starts(directory.path(), &state_root, session);
    assert!(actions.iter().any(|action| action.contains("moved them")), "{actions:?}");
    let kept: Vec<_> =
        fs::read_dir(state_root.join(REMOTE_STATE_RECOVERY_DIR)).unwrap().flatten().collect();
    assert_eq!(kept.len(), 1, "{kept:?}");
    let kept = kept[0].path();
    assert!(fs::symlink_metadata(kept.join("shutdown.json")).unwrap().file_type().is_socket());
    assert!(kept.join("admin.sock").is_file());
    // The authorization state stayed: same identity, so paired clients still trust it.
    let runtime = start(directory.path(), &state_root, session).unwrap();
    assert_eq!(runtime.info().daemon_fingerprint, fingerprint);
    runtime.shutdown().unwrap();
}

/// A socket inside `auth/`: the whole session state moves aside.
#[test]
fn startup_self_recovery_moves_aside_state_whose_authorization_is_damaged() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "self-recovery-auth-file-types";
    let runtime = start(directory.path(), &state_root, session).unwrap();
    let state_dir = runtime.info().state_dir.clone();
    runtime.shutdown().unwrap();
    let devices = state_dir.join("auth").join("devices.json");
    fs::remove_file(&devices).unwrap();
    drop(std::os::unix::net::UnixListener::bind(&devices).unwrap());

    let error = refusal(directory.path(), &state_root, session);
    assert!(!error.is_empty());

    let actions = recovers_and_starts(directory.path(), &state_root, session);
    assert!(actions.iter().any(|action| action.contains("new identity")), "{actions:?}");
    let kept: Vec<_> =
        fs::read_dir(state_root.join(REMOTE_STATE_RECOVERY_DIR)).unwrap().flatten().collect();
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert!(kept[0].path().join("auth").is_dir(), "the moved state lost its authorization");
}

/// Nothing changes while a predecessor socket still answers.
#[test]
fn startup_self_recovery_refuses_while_a_predecessor_socket_answers() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "self-recovery-live-predecessor";
    let (state_dir, _) = crashed_daemon_state(directory.path(), &state_root, session);
    fs::remove_dir_all(state_dir.join("auth")).unwrap();
    let (_, _, admin_socket) = daemon_paths(session, Some(&state_root)).unwrap();
    let _ = fs::remove_file(&admin_socket);
    let _live = std::os::unix::net::UnixListener::bind(&admin_socket).unwrap();
    let runtime_before = fs::read(state_dir.join("runtime.json")).unwrap();

    let error = recover_inactive_daemon_state(session, Some(&state_root), None, None)
        .expect_err("recovered over a live predecessor");
    assert!(format!("{error:#}").contains(&admin_socket.display().to_string()), "{error:#}");
    assert_eq!(fs::read(state_dir.join("runtime.json")).unwrap(), runtime_before);
    assert!(!state_dir.join("auth").exists());

    // A file-type problem moves nothing while the socket answers either.
    fs::write(state_dir.join("lifecycle-fence.json.tmp"), b"").unwrap();
    fs::remove_file(state_dir.join("lifecycle-fence.json")).unwrap();
    std::os::unix::fs::symlink("lifecycle-fence.json.tmp", state_dir.join("lifecycle-fence.json"))
        .unwrap();
    recover_inactive_daemon_state(session, Some(&state_root), None, None)
        .expect_err("moved state aside under a live predecessor");
    assert!(state_dir.join("runtime.json").exists());
}
