use super::*;

#[test]
fn terminal_resume_command_persists_validates_and_clears() {
    let root = temp_root("terminal-resume-set");
    {
        let mut registry = WorkspaceRegistry::open(&root, "terminal-resume-set").unwrap();
        seed_workspace(&mut registry, "one");
        reserve_terminal(&mut registry, TERMINAL_ONE, 0);
        assert_eq!(registry.terminal_resume_command(TERMINAL_ONE).unwrap(), None);
        let stored =
            registry.set_terminal_resume_command(TERMINAL_ONE, Some("  npm run dev ")).unwrap();
        assert_eq!(stored.as_deref(), Some("npm run dev"));
        for bad in ["", "   ", "echo a\nrm -rf ~", "echo a\rb", "echo\ta"] {
            let error = registry.set_terminal_resume_command(TERMINAL_ONE, Some(bad)).unwrap_err();
            assert!(error.to_string().contains("bad request"), "{bad:?}: {error}");
        }
        let long = "a".repeat(terminal_resume_store::RESUME_COMMAND_CAP + 1);
        assert!(registry.set_terminal_resume_command(TERMINAL_ONE, Some(&long)).is_err());
        let unknown = registry.set_terminal_resume_command(TERMINAL_TWO, Some("ls")).unwrap_err();
        assert!(unknown.to_string().contains("terminal_not_found"));
    }
    // Survives a reopen; a rejected set left the stored command alone.
    let mut registry = WorkspaceRegistry::open(&root, "terminal-resume-set").unwrap();
    assert_eq!(
        registry.terminal_resume_command(TERMINAL_ONE).unwrap().as_deref(),
        Some("npm run dev")
    );
    registry.set_terminal_resume_command(TERMINAL_ONE, Some("cargo watch")).unwrap();
    assert_eq!(
        registry.terminal_resume_command(TERMINAL_ONE).unwrap().as_deref(),
        Some("cargo watch")
    );
    assert_eq!(registry.set_terminal_resume_command(TERMINAL_ONE, None).unwrap(), None);
    assert_eq!(registry.terminal_resume_command(TERMINAL_ONE).unwrap(), None);

    registry.set_terminal_resume_command(TERMINAL_ONE, Some("ls")).unwrap();
    let close = WorkspaceMutation::daemon("close-resume", "test").unwrap();
    registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert_eq!(registry.prune_terminal_resume_commands().unwrap(), 1);
    let closed = registry.set_terminal_resume_command(TERMINAL_ONE, Some("ls")).unwrap_err();
    assert!(closed.to_string().contains("terminal_not_found"));
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}
