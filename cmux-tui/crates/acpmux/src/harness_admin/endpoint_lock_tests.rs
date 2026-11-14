use super::*;

/// An endpoint add lets go of its lock, also while a child the daemon forked meanwhile has
/// the descriptor: else the next add or remove waits until that child execs.
#[test]
fn a_dropped_endpoint_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = tempfile::tempdir().unwrap();
    let held = lock_endpoint_adds(dir.path()).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    drop(held);
    let free = crate::fork_tests::free(&dir.path().join(".endpoint-add.lock"));
    drop(keeper);
    assert!(free, "a dropped endpoint lock stayed held through a forked child's copy");
}
