use super::*;

/// A look at a free brain lock leaves it free, also while a child the server forked
/// meanwhile has the look's descriptor: else a brain that starts then exits as a second
/// brain, and the next look reports a brain that is not there.
#[test]
fn a_look_at_a_free_brain_lock_leaves_it_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("chief_brains");
    let lock = dir.path().join("host.lock");
    std::fs::write(&lock, b"").unwrap();
    let look = std::fs::File::open(&lock).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    let held = lock_held_on(look);
    let free = crate::fork_tests::free(&lock);
    drop(keeper);
    assert!(!held, "a free brain lock read as held");
    assert!(free, "the look left the brain lock held");
}
