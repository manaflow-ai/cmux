use super::*;

/// A count's lock is free once the count is written, also while a child the server forked
/// meanwhile has the descriptor: else `server-stats` reads the count as 0 and the next
/// hook's count waits.
#[test]
fn a_written_count_leaves_its_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("hook_queue");
    let path = dir.path().join("dropped-events");
    let count = open_spool_file(&path).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    add_count_in(count, 2).unwrap();
    let free = crate::fork_tests::free(&path);
    drop(keeper);
    assert!(free, "the count left its lock held");
    add_count(&path, 3).unwrap();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "5\n");
}
