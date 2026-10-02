use super::*;

const TERMINAL_THREE: &str = "00000000000040008000000000000003";

fn forget_terminal_keep_classification(registry: &WorkspaceRegistry) {
    registry
        .connection
        .execute_batch(
            "DELETE FROM meta WHERE key = 'terminal_keep_classified';
             DELETE FROM terminal_keep;",
        )
        .unwrap();
}

#[test]
fn terminal_keep_legacy_classification_keeps_only_unplaced_terminals() {
    let root = temp_root("terminal-keep-classify");
    {
        let mut registry = WorkspaceRegistry::open(&root, "terminal-keep").unwrap();
        // TERMINAL_ONE has a live tab; TERMINAL_TWO is registered without one.
        commit_terminal_topology(&mut registry, "create-placed-terminal");
        let revision = registry.terminal_revision().unwrap();
        reserve_terminal(&mut registry, TERMINAL_TWO, revision);
        // Simulate a registry written before terminal-reap-v1.
        forget_terminal_keep_classification(&registry);
    }
    {
        let mut registry = WorkspaceRegistry::open(&root, "terminal-keep").unwrap();
        assert!(!registry.terminal_keep(TERMINAL_ONE).unwrap(), "a placed terminal stays reapable");
        assert!(registry.terminal_keep(TERMINAL_TWO).unwrap(), "detached work survives upgrade");
        // Terminals created after classification default to reapable, and a
        // later open never classifies again.
        let revision = registry.terminal_revision().unwrap();
        reserve_terminal(&mut registry, TERMINAL_THREE, revision);
    }
    let registry = WorkspaceRegistry::open(&root, "terminal-keep").unwrap();
    assert!(!registry.terminal_keep(TERMINAL_THREE).unwrap());
    assert!(registry.terminal_keep(TERMINAL_TWO).unwrap());
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn terminal_keep_persists_and_rejects_unknown_and_closed_terminals() {
    let root = temp_root("terminal-keep-set");
    {
        let mut registry = WorkspaceRegistry::open(&root, "terminal-keep-set").unwrap();
        seed_workspace(&mut registry, "one");
        reserve_terminal(&mut registry, TERMINAL_ONE, 0);
        assert!(!registry.terminal_keep(TERMINAL_ONE).unwrap());
        registry.set_terminal_keep(TERMINAL_ONE, true).unwrap();
        registry.set_terminal_keep(TERMINAL_ONE, true).unwrap();
        let unknown = registry.set_terminal_keep(TERMINAL_TWO, true).unwrap_err();
        assert!(unknown.to_string().contains("terminal_not_found"));
    }
    let mut registry = WorkspaceRegistry::open(&root, "terminal-keep-set").unwrap();
    assert!(registry.terminal_keep(TERMINAL_ONE).unwrap());
    assert_eq!(registry.kept_terminals().unwrap().len(), 1);
    registry.set_terminal_keep(TERMINAL_ONE, false).unwrap();
    assert!(!registry.terminal_keep(TERMINAL_ONE).unwrap());

    registry.set_terminal_keep(TERMINAL_ONE, true).unwrap();
    let close = WorkspaceMutation::new("close-kept", "test").unwrap();
    registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert_eq!(registry.prune_terminal_keep().unwrap(), 1);
    assert!(registry.kept_terminals().unwrap().is_empty());
    let closed = registry.set_terminal_keep(TERMINAL_ONE, true).unwrap_err();
    assert!(closed.to_string().contains("terminal_not_found"));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
