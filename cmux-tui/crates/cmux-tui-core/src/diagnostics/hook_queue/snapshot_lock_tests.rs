use super::*;

/// A `server-stats` look at a count leaves its lock free, also while a child the server
/// forked meanwhile has the look's descriptor: else the next hook's count waits for that
/// child.
#[test]
fn a_count_look_leaves_its_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("hook_queue_look");
    let path = dir.path().join("dropped-events");
    std::fs::write(&path, "2\n").unwrap();
    let look = open_for_reading(&path).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    let count = shared_count(look);
    let free = crate::fork_tests::free(&path);
    drop(keeper);
    assert_eq!(count, Some(2));
    assert!(free, "a count look left its lock held");
}
