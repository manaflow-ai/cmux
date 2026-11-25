//! A terminal's `.exit` sidecar that this build cannot read (a newer
//! build's record after a rollback, a damaged file) must not stop the
//! daemon from starting: the whole session, with every live terminal,
//! was unreachable until someone deleted the file by hand.

use super::*;

#[cfg(unix)]
fn registry_with_reserved_terminal(root: &Path, session: &str, terminal: &str) {
    let mut registry = WorkspaceRegistry::open(root, session).unwrap();
    registry
        .commit(
            &WorkspaceMutation::daemon("workspace", "test").unwrap(),
            &serde_json::json!({"op":"create-workspace"}),
            None,
            Some(0),
            "workspace-added",
            "workspace-one",
            &[RegistryWorkspace {
                id: 1,
                public_id: WorkspacePublicId::random().unwrap(),
                key: "workspace-one".into(),
                name: "One".into(),
                name_source: Default::default(),
                name_revision: 0,
                group_key: session.into(),
            }],
            &serde_json::json!({"workspace":1,"key":"workspace-one"}),
        )
        .unwrap();
    registry
        .commit_terminal(
            &WorkspaceMutation::daemon("reserve", "test").unwrap(),
            &serde_json::json!({"op":"create-terminal","terminal_id":terminal}),
            None,
            Some(0),
            "terminal-reserved",
            &RegistryTerminal {
                terminal_id: terminal.into(),
                workspace_key: "workspace-one".into(),
                incarnation: None,
                lifecycle: TerminalLifecycle::Launching,
                launch_spec: serde_json::json!({"command_present":true}),
                exit: None,
                on_exit: TerminalOnExit::Close,
            },
            &serde_json::json!({"terminal_id":terminal}),
        )
        .unwrap();
}

/// A terminal with no host record whose sidecar does not decode ends as a
/// host loss at start, the daemon starts, and the file stays for a build
/// that can read it.
#[cfg(unix)]
#[test]
fn a_start_with_an_unreadable_exit_sidecar_ends_the_terminal_and_starts() {
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    const TERMINAL: &str = "00000000000040008000000000000a02";
    const SESSION: &str = "unreadable-exit";
    for sidecar in [
        // A field this build does not know (a newer build's sidecar).
        br#"{"record_version":2,"terminal_id":"00000000000040008000000000000a02","incarnation":"00000000000040008000000000000a01","exit":{"outcome":{"kind":"exit","code":0},"exited_at_ms":1},"extra":true}"#.to_vec(),
        // A damaged file.
        b"{\"record_version\":1,\"terminal".to_vec(),
    ] {
        let root = std::env::temp_dir().join(format!(
            "cmux-mux-unreadable-exit-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        registry_with_reserved_terminal(&root, SESSION, TERMINAL);
        let host_root = crate::terminal_host_runtime::terminal_host_root(&root, SESSION);
        std::fs::create_dir_all(&host_root).unwrap();
        std::fs::set_permissions(&host_root, std::fs::Permissions::from_mode(0o700)).unwrap();
        let exit_path = host_root.join(format!("{TERMINAL}.exit"));
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&exit_path)
            .and_then(|mut file| std::io::Write::write_all(&mut file, &sidecar))
            .unwrap();
        let options =
            SurfaceOptions { terminal_host_root: Some(host_root), ..SurfaceOptions::default() };
        let mux = Mux::open_persistent(SESSION, options, &root)
            .expect("an unreadable exit sidecar stopped the daemon's start");
        let resolved = mux.resolve_terminal(TERMINAL).unwrap().unwrap();
        assert_eq!(resolved.terminal.lifecycle, TerminalLifecycle::Exited);
        let exit = resolved.terminal.exit.unwrap();
        assert_eq!(exit["outcome"]["kind"], "unknown");
        assert_eq!(exit["outcome"]["reason"], "missing-host-record");
        assert_eq!(std::fs::read(&exit_path).unwrap(), sidecar, "the sidecar was not kept");
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}
