use super::*;

fn opened(path: &Path) -> File {
    OpenOptions::new().create(true).truncate(false).read(true).write(true).open(path).unwrap()
}

/// A pepper load that fails after it took the pepper lock (the pepper path is a folder) lets
/// the lock go, also while a child the server forked meanwhile keeps its descriptor: else
/// the next registry open waits for that child.
#[test]
fn a_failed_pepper_load_leaves_its_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("pepper_lock");
    fs::create_dir(dir.path().join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
    let lock_path = dir.path().join(RESOURCE_EFFECT_PEPPER_LOCK_FILE);
    let lock = opened(&lock_path);
    let keeper = crate::fork_tests::Keeper::fork();
    let loaded = pepper_under_lock(dir.path(), lock, &lock_path);
    let free = crate::fork_tests::free(&lock_path);
    drop(keeper);
    assert!(loaded.is_err(), "a folder at the pepper path is no pepper");
    assert!(free, "a failed pepper load left its lock held");
}

/// A machine-id load that fails after it took the id lock (the id file cannot be made
/// private: a link to a file of another owner) lets the lock go, also while a child the
/// server forked meanwhile keeps its descriptor.
#[test]
fn a_failed_machine_id_load_leaves_its_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("machine_id_lock");
    std::os::unix::fs::symlink("/etc/hosts", dir.path().join(MACHINE_ID_FILE)).unwrap();
    let lock_path = dir.path().join(MACHINE_ID_LOCK_FILE);
    let lock = opened(&lock_path);
    let keeper = crate::fork_tests::Keeper::fork();
    let loaded = machine_id_under_lock(dir.path(), lock, &lock_path);
    let free = crate::fork_tests::free(&lock_path);
    drop(keeper);
    assert!(loaded.is_err(), "a file of another owner cannot be made private");
    assert!(free, "a failed machine-id load left its lock held");
}
