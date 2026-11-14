use super::*;

/// A wait for a host's exit lets go of the lease it took, also while a child the server
/// forked meanwhile has the descriptor: else the next liveness probe reads the dead host
/// as live, and its record, proof and endpoint stay.
#[test]
fn a_finished_wait_leaves_the_lease_free_while_a_forked_child_keeps_its_descriptor() {
    let dir = crate::fork_tests::Scratch::new("lease");
    let path = dir.path().join("host.live");
    fs::write(&path, b"").unwrap();
    let marker = File::open(&path).unwrap();
    let keeper = crate::fork_tests::Keeper::fork();
    wait_lease_exclusive(&marker).unwrap();
    drop(marker);
    let free = crate::fork_tests::free(&path);
    drop(keeper);
    assert!(free, "the wait left the lease held");
}
