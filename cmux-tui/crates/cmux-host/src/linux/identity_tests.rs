use super::*;

fn session(home: &Path) -> PathBuf {
    home.join(".local/state/cmux/remote/sessions/Y2xvdWQ")
}

/// A rebind must not leave the shape cmux-tui refuses at startup: a
/// lifecycle fence with no `auth/`.
#[test]
fn drop_remote_identity_removes_the_whole_session_with_its_lifecycle_fence() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let session = session(home);
    fs::create_dir_all(session.join("auth")).unwrap();
    fs::write(session.join("auth/devices.json"), "{}").unwrap();
    fs::write(session.join("lifecycle-fence.json"), "{}").unwrap();
    fs::write(session.join("runtime.json"), "{}").unwrap();
    let remote = home.join(".local/state/cmux/remote");
    fs::create_dir_all(remote.join("connections")).unwrap();
    fs::create_dir_all(remote.join("private")).unwrap();

    drop_remote_identity(home).unwrap();

    assert!(!session.join("lifecycle-fence.json").exists());
    assert!(!remote.join("sessions").exists());
    assert!(!remote.join("connections").exists());
    // Client-side state beside the sessions is not the daemon's.
    assert!(remote.join("private").is_dir());
    // Idempotent: a second bind finds nothing to drop.
    drop_remote_identity(home).unwrap();
}

/// A stranded session from an older agent (fence, no `auth/`) is
/// repaired by the next bind too.
#[test]
fn drop_remote_identity_clears_a_fence_left_without_auth() {
    let dir = tempfile::tempdir().unwrap();
    let session = session(dir.path());
    fs::create_dir_all(&session).unwrap();
    fs::write(session.join("lifecycle-fence.json"), "{}").unwrap();

    drop_remote_identity(dir.path()).unwrap();

    assert!(!session.exists());
}

#[test]
fn drop_remote_identity_unlinks_a_symlinked_sessions_dir_without_following_it() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let outside = dir.path().join("outside");
    fs::create_dir_all(outside.join("Y2xvdWQ/auth")).unwrap();
    let remote = home.join(".local/state/cmux/remote");
    fs::create_dir_all(&remote).unwrap();
    symlink(&outside, remote.join("sessions")).unwrap();

    drop_remote_identity(&home).unwrap();

    assert!(fs::symlink_metadata(remote.join("sessions")).is_err());
    assert!(outside.join("Y2xvdWQ/auth").is_dir());
}

#[test]
fn drop_remote_identity_refuses_a_symlinked_component_above_sessions() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let outside = dir.path().join("outside");
    fs::create_dir_all(outside.join("sessions/Y2xvdWQ/auth")).unwrap();
    fs::create_dir_all(home.join(".local/state/cmux")).unwrap();
    symlink(&outside, home.join(".local/state/cmux/remote")).unwrap();

    assert!(drop_remote_identity(&home).is_err());
    assert!(outside.join("sessions/Y2xvdWQ/auth").is_dir());
}

#[test]
fn drop_remote_identity_unlinks_nested_symlinks_without_following_them() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let outside = dir.path().join("outside");
    fs::create_dir_all(outside.join("keep")).unwrap();
    let session = session(&home);
    fs::create_dir_all(session.join("auth")).unwrap();
    symlink(&outside, session.join("auth/link")).unwrap();

    drop_remote_identity(&home).unwrap();

    assert!(!session.exists());
    assert!(outside.join("keep").is_dir());
}

#[test]
fn drop_remote_identity_without_remote_state_is_a_no_op() {
    let dir = tempfile::tempdir().unwrap();
    drop_remote_identity(dir.path()).unwrap();
    drop_remote_identity(&dir.path().join("missing-home")).unwrap();
}
