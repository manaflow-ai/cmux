use super::*;

#[test]
fn mark_restarts_after_git_maintenance_removes_a_listed_lock() {
    let state = tempfile::tempdir().unwrap();
    let git = state.path().join(crate::git_swap::LOCAL_DIR);
    fs::create_dir_all(state.path().join("upper")).unwrap();
    fs::create_dir_all(git.join("objects")).unwrap();
    std::os::unix::fs::symlink(&git, state.path().join("upper/.git")).unwrap();
    let edited = git.join("HEAD");
    let lock = git.join("objects/maintenance.lock");
    fs::write(&edited, "old head").unwrap();
    fs::write(&lock, "maintenance").unwrap();
    let before = mark(state.path()).unwrap();
    let after = mark_with_metadata(state.path(), &mut |path| {
        if path == lock {
            // HEAD was already hashed. A retry must discard that partial hash too.
            fs::write(&edited, "new head, written during the scan").unwrap();
            fs::remove_file(&lock).unwrap();
        }
        fs::symlink_metadata(path)
    })
    .unwrap();
    assert_ne!(before, after);
    assert_eq!(after, mark(state.path()).unwrap());
}

#[test]
fn mark_keeps_failing_for_an_unreadable_path() {
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(state.path().join("upper")).unwrap();
    fs::write(state.path().join("upper/edit"), "keep this edit").unwrap();
    for (kind, attempts) in [(io::ErrorKind::NotFound, 3), (io::ErrorKind::PermissionDenied, 1)] {
        let mut calls = 0;
        let error = mark_with_metadata(state.path(), &mut |_| {
            calls += 1;
            Err(io::Error::new(kind, "unreadable edit"))
        })
        .unwrap_err();
        assert_eq!(error.kind(), kind);
        assert_eq!(calls, attempts);
    }
}

#[test]
fn mark_refuses_a_missing_swapped_repository() {
    let state = tempfile::tempdir().unwrap();
    fs::create_dir(state.path().join("upper")).unwrap();
    std::os::unix::fs::symlink(
        state.path().join(crate::git_swap::LOCAL_DIR),
        state.path().join("upper/.git"),
    )
    .unwrap();
    assert_eq!(mark(state.path()).unwrap_err().kind(), io::ErrorKind::NotFound);
}
