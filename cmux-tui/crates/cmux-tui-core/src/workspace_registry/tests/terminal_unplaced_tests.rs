use std::collections::HashSet;

use super::*;

fn ids(list: &[&str]) -> HashSet<String> {
    list.iter().map(|id| (*id).to_string()).collect()
}

/// The time a terminal was first seen unplaced survives a reopen (an owner
/// restart), a placed terminal loses it, and one the restarted owner has
/// not adopted yet (in neither set) keeps it.
#[test]
fn unplaced_since_survives_a_reopen_and_clears_when_placed() {
    let root = temp_root("terminal-unplaced");
    {
        let mut registry = WorkspaceRegistry::open(&root, "terminal-unplaced").unwrap();
        seed_workspace(&mut registry, "one");
        reserve_terminal(&mut registry, TERMINAL_ONE, 0);
        let since = registry
            .sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 1_000)
            .unwrap()
            .since_ms;
        assert_eq!(since[TERMINAL_ONE], 1_000);
        // A later pass keeps the first time.
        let since = registry
            .sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 5_000)
            .unwrap()
            .since_ms;
        assert_eq!(since[TERMINAL_ONE], 1_000);
    }
    let mut registry = WorkspaceRegistry::open(&root, "terminal-unplaced").unwrap();
    // Not adopted yet: in neither set, the row stays.
    let adopting = registry.sync_terminal_unplaced(&ids(&[]), &ids(&[]), 9_000).unwrap();
    assert!(adopting.since_ms.is_empty());
    assert!(adopting.rows_left, "the row of a terminal not seen yet stays");
    let since =
        registry.sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 9_000).unwrap().since_ms;
    assert_eq!(since[TERMINAL_ONE], 1_000, "the grace goes on across the reopen");
    // Placed again: the row goes, and the next unplace starts a new time.
    registry.sync_terminal_unplaced(&ids(&[]), &ids(&[TERMINAL_ONE]), 10_000).unwrap();
    let since =
        registry.sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 12_000).unwrap().since_ms;
    assert_eq!(since[TERMINAL_ONE], 12_000);
    // Closed (tombstoned): its row is pruned, and no row is left.
    let close = WorkspaceMutation::daemon("close-unplaced", "test").unwrap();
    let revision = registry.terminal_snapshot().unwrap().revision;
    registry.close_terminal(&close, None, Some(revision), TERMINAL_ONE, None).unwrap();
    let after = registry.sync_terminal_unplaced(&ids(&[]), &ids(&[]), 13_000).unwrap();
    assert!(!after.rows_left, "a closed terminal's row is pruned");
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
