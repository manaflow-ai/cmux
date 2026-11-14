use super::*;

/// A wait for a runner to end lets go of the lock it took, also while a child the daemon
/// forked meanwhile has the descriptor: else the task's liveness probe reads the ended runner
/// as running (the cap counts it, its chat's folder is not swept).
#[test]
fn a_finished_wait_leaves_the_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("task.lock");
    std::fs::write(&path, b"").unwrap();
    let file = std::fs::File::open(&path).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    wait_released(file).unwrap();
    let free = crate::fork_tests::free(&path);
    drop(keeper);
    assert!(free, "the wait left the runner's lock held");
}
