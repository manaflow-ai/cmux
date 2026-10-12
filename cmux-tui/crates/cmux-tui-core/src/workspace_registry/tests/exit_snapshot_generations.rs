use super::*;

/// A respawned terminal keeps its id but starts a new generation; its next
/// loss must store a new exit snapshot (cx-6so.49 L2), while a replayed
/// store for the same generation stays a no-op (the exit latch).
#[test]
fn a_new_generation_replaces_the_exit_snapshot_and_the_same_generation_does_not() {
    const INCARNATION_TWO: &str = "20000000000040008000000000000002";
    let mut registry = WorkspaceRegistry::in_memory("exit-snapshot-generations").unwrap();
    commit_terminal_topology(&mut registry, "exit-snapshot-generations-seed");
    let terminal_id = terminal_resource(TERMINAL_ONE);
    let output: &[u8] = b"first run\r\n";
    append_terminal_output_for_test(&mut registry, &terminal_id, INCARNATION_ONE, &[output]);
    let first = vt_replay_blob_for_test(&terminal_id, 100, 30, b"first loss");
    assert!(
        registry.put_terminal_exit_snapshot(terminal_id.as_str(), INCARNATION_ONE, &first).unwrap()
    );

    append_terminal_output_for_test(&mut registry, &terminal_id, INCARNATION_TWO, &[output]);
    let second = vt_replay_blob_for_test(&terminal_id, 90, 20, b"second loss");
    assert!(
        registry
            .put_terminal_exit_snapshot(terminal_id.as_str(), INCARNATION_TWO, &second)
            .unwrap()
    );
    let replayed = vt_replay_blob_for_test(&terminal_id, 80, 24, b"replayed");
    assert!(
        !registry
            .put_terminal_exit_snapshot(terminal_id.as_str(), INCARNATION_TWO, &replayed)
            .unwrap()
    );

    let latest = registry.terminal_exit_snapshot(terminal_id.as_str()).unwrap().unwrap();
    assert_eq!(latest.generation, INCARNATION_TWO);
    assert_eq!(latest.replay_bytes.as_slice(), b"second loss");
    assert_eq!((latest.cols, latest.rows), (90, 20));
}
