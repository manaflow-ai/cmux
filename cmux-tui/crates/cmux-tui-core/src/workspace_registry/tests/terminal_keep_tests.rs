use super::*;

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
    let close = WorkspaceMutation::daemon("close-kept", "test").unwrap();
    registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert_eq!(registry.prune_terminal_keep().unwrap(), 1);
    assert!(registry.kept_terminals().unwrap().is_empty());
    let closed = registry.set_terminal_keep(TERMINAL_ONE, true).unwrap_err();
    assert!(closed.to_string().contains("terminal_not_found"));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
