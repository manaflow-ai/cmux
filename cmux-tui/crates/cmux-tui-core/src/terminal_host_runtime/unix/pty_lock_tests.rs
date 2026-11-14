use super::*;

#[test]
fn pty_lock_is_exclusive_and_removed_only_when_released() {
    let dir = std::env::temp_dir().join(format!(
        "cmux-pty-lock-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap();
    let record = dir.join("t.json");
    let held = PtyOwnershipLock::acquire(&record, "t", "i").unwrap();
    let path = lock_path(&record, "t", "i");
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
    // flock locks belong to the open file description: a second open in
    // this process conflicts exactly like another process would.
    assert!(PtyOwnershipLock::acquire(&record, "t", "i").is_err());
    remove_released(&record, "t", "i");
    assert!(path.exists(), "a held fence was removed");
    drop(held);
    let again = PtyOwnershipLock::acquire(&record, "t", "i").unwrap();
    drop(again);
    remove_released(&record, "t", "i");
    assert!(!path.exists());

    // The sweep removes released fences only.
    let held = PtyOwnershipLock::acquire(&record, "t", "held").unwrap();
    drop(PtyOwnershipLock::acquire(&record, "t", "released").unwrap());
    fs::write(dir.join("t.json"), b"{}").unwrap();
    sweep_released_pty_locks(&dir);
    assert!(lock_path(&record, "t", "held").exists(), "the sweep removed a held fence");
    assert!(!lock_path(&record, "t", "released").exists());
    assert!(dir.join("t.json").exists(), "the sweep removed a non-fence file");
    drop(held);
    let _ = fs::remove_dir_all(dir);
}

/// A replacement host that opened a released fence just before the sweep removed it
/// takes its lock on that file, also while a child the server forked meanwhile still has
/// the sweep's descriptor: else its launch fails as "another terminal host still owns the
/// PTY" instead of retrying on the new file.
#[test]
fn a_swept_fence_is_free_while_a_forked_child_keeps_the_sweeps_descriptor() {
    let dir = std::env::temp_dir().join(format!(
        "cmux-pty-lock-fork-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    fs::create_dir_all(&dir).unwrap();
    let record = dir.join("t.json");
    drop(PtyOwnershipLock::acquire(&record, "t", "i").unwrap());
    let path = lock_path(&record, "t", "i");
    let early = open_lock_file(&path, false).unwrap();
    let sweep = open_lock_file(&path, false).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    remove_released_file(sweep, &path);
    // SAFETY: flock on a descriptor `early` keeps open through the call.
    let taken = unsafe { libc::flock(early.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0;
    drop(keeper);
    assert!(!path.exists(), "the sweep removed the released fence");
    assert!(taken, "the sweep's lock stayed held through a forked child's copy");
    let _ = fs::remove_dir_all(dir);
}
