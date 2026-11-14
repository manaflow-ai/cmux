use super::*;

/// A `held` look at a free run lock leaves it free, also while a child the server forked
/// meanwhile has the look's descriptor: else the next `start` cannot take the run's lock
/// and runs the setup without it (no fd 7 for the shell).
#[test]
fn a_held_look_leaves_the_run_lock_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("worktree_setup");
    fs::write(dir.path().join(LOCK_FILE), b"").unwrap();
    let look = File::open(dir.path().join(LOCK_FILE)).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    let looked = held_on(look);
    let run = hold(dir.path());
    drop(keeper);
    assert!(!looked, "a free run lock read as held");
    assert!(run.is_some(), "the look left the run lock held");
}
