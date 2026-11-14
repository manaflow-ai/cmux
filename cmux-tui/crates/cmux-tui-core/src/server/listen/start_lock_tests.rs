use super::*;

/// A server start lets go of the start lock, also while a child another daemon thread forked
/// meanwhile has the descriptor: else the next start or CLI `ensure_owner` waits for that
/// child, and past `START_LOCK_DEADLINE` fails with a timeout.
#[test]
fn a_dropped_start_lock_is_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("socket_start_lock");
    let path = dir.path().join("server.sock.start.lock");
    let deadline = Instant::now() + Duration::from_secs(5);
    let lock = SocketStartLock::acquire_with(&path, deadline, &mut || {}, &|_, _| true).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    drop(lock);
    let free = crate::fork_tests::free(&path);
    drop(keeper);
    assert!(free, "a dropped start lock stayed held through a forked child's copy");
}
