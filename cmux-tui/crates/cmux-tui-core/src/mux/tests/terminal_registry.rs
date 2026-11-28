//! Terminal registry records: secret-free launch specs and stable terminal lookup.

use super::*;

#[test]
fn terminal_registry_launch_spec_never_persists_environment_secrets() {
    let sentinel = "cmux-secret-sentinel-do-not-persist";
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), sentinel.into()]),
        cwd: Some(format!("/tmp/{sentinel}")),
        extra_env: vec![
            ("API_BEARER_TOKEN".into(), sentinel.into()),
            ("CMUX_TUI_SOCKET".into(), "/tmp/cmux.sock".into()),
            ("CMUX_TUI_HOOK".into(), "/tmp/cmux-tui-hook".into()),
        ],
        ..SurfaceOptions::default()
    };
    let encoded = serde_json::to_string(&terminal_launch_spec(&options)).unwrap();
    assert!(!encoded.contains(sentinel));
    assert!(!encoded.contains("API_BEARER_TOKEN"));
    assert!(!encoded.contains("/tmp/cmux.sock"));
    assert!(!encoded.contains("/tmp/cmux-tui-hook"));
    assert!(!encoded.contains("/bin/sh"));
    assert!(encoded.contains("CMUX_TUI_SOCKET"));
    assert!(encoded.contains("CMUX_TUI_HOOK"));
}

#[test]
fn terminal_create_mutation_persists_only_a_secret_free_digest() {
    const TERMINAL: &str = "00000000000040008000000000000009";
    let sentinel = "cmux-create-secret-sentinel-do-not-persist";
    let root = std::env::temp_dir()
        .join(format!("cmux-create-fingerprint-{}", crate::workspace_registry::new_uuid_v4()));
    let argv = vec!["/bin/sh".to_string(), "-c".to_string(), sentinel.to_string()];
    let cwd = format!("/tmp/{sentinel}");
    let name = format!("terminal-{sentinel}");
    let fingerprint = terminal_create_fingerprint(
        "workspace-one",
        Some(TERMINAL),
        Some(&argv),
        Some(&cwd),
        Some(&name),
        Some((80, 24)),
        Some(TerminalOnExit::Keep),
    )
    .unwrap();
    assert!(!serde_json::to_string(&fingerprint).unwrap().contains(sentinel));

    {
        let mut registry = WorkspaceRegistry::open(&root, "secret-test").unwrap();
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
                    group_key: "secret-test".into(),
                }],
                &serde_json::json!({"workspace":1,"key":"workspace-one"}),
            )
            .unwrap();
        registry
            .commit_terminal(
                &WorkspaceMutation::daemon("create", "browser").unwrap(),
                &fingerprint,
                None,
                Some(0),
                "terminal-reserved",
                &RegistryTerminal {
                    terminal_id: TERMINAL.into(),
                    workspace_key: "workspace-one".into(),
                    incarnation: None,
                    lifecycle: TerminalLifecycle::Launching,
                    launch_spec: serde_json::json!({"command_present":true}),
                    exit: None,
                    on_exit: TerminalOnExit::Close,
                },
                &serde_json::json!({"terminal_id":TERMINAL}),
            )
            .unwrap();
    }

    fn assert_tree_does_not_contain(path: &Path, needle: &[u8]) {
        for entry in std::fs::read_dir(path).unwrap() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                assert_tree_does_not_contain(&path, needle);
            } else {
                let bytes = std::fs::read(&path).unwrap();
                assert!(
                    !bytes.windows(needle.len()).any(|window| window == needle),
                    "secret persisted in {}",
                    path.display()
                );
            }
        }
    }
    assert_tree_does_not_contain(&root, sentinel.as_bytes());
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn stable_terminal_lookup_never_chooses_between_duplicate_ids() {
    let terminal_id = "00112233445566778899aabbccddeeff";
    let identities = vec![
        (
            10,
            TerminalHostIdentity {
                terminal_id: terminal_id.into(),
                incarnation: "11111111111111111111111111111111".into(),
            },
        ),
        (
            20,
            TerminalHostIdentity {
                terminal_id: terminal_id.into(),
                incarnation: "22222222222222222222222222222222".into(),
            },
        ),
    ];

    assert_eq!(
        unique_terminal_match(terminal_id, identities.clone()).unwrap_err().to_string(),
        "duplicate_terminal_id"
    );
    let unique =
        unique_terminal_match(terminal_id, identities.into_iter().take(1)).unwrap().unwrap();
    assert_eq!(unique.0, 10);
}
