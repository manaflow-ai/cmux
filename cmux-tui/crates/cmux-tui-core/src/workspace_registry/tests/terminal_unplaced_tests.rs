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
        let since =
            registry.sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 1_000).unwrap();
        assert_eq!(since[TERMINAL_ONE], 1_000);
        // A later pass keeps the first time.
        let since =
            registry.sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 5_000).unwrap();
        assert_eq!(since[TERMINAL_ONE], 1_000);
    }
    let mut registry = WorkspaceRegistry::open(&root, "terminal-unplaced").unwrap();
    // Not adopted yet: in neither set, the row stays.
    assert!(registry.sync_terminal_unplaced(&ids(&[]), &ids(&[]), 9_000).unwrap().is_empty());
    let since = registry.sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 9_000).unwrap();
    assert_eq!(since[TERMINAL_ONE], 1_000, "the grace goes on across the reopen");
    // Placed again: the row goes, and the next unplace starts a new time.
    registry.sync_terminal_unplaced(&ids(&[]), &ids(&[TERMINAL_ONE]), 10_000).unwrap();
    let since = registry.sync_terminal_unplaced(&ids(&[TERMINAL_ONE]), &ids(&[]), 12_000).unwrap();
    assert_eq!(since[TERMINAL_ONE], 12_000);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
