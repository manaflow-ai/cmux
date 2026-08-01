use super::*;

const TERMINAL_ONE: &str = "00000000000040008000000000000001";
const TERMINAL_TWO: &str = "00000000000040008000000000000002";
const INCARNATION_ONE: &str = "10000000000040008000000000000001";
use serde_json::json;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
}

fn workspace(id: u64, key: &str, name: &str) -> RegistryWorkspace {
    RegistryWorkspace {
        id,
        public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
        key: key.into(),
        name: name.into(),
        group_key: "default".into(),
    }
}

fn seed_workspace(registry: &mut WorkspaceRegistry, key: &str) {
    registry
        .commit(
            &WorkspaceMutation::new(format!("create-{key}"), "test").unwrap(),
            &json!({"op":"create","key":key}),
            None,
            Some(registry.snapshot().unwrap().revision),
            "workspace-added",
            key,
            &[workspace(1, key, "Workspace")],
            &json!({"key":key}),
        )
        .unwrap();
}

#[test]
fn interrupted_staged_workspace_keeps_reserved_public_id_without_early_publication() {
    let root = temp_root("interrupted-workspace-public-id");
    let key = "018f6e21-7b70-7e70-8000-0000000000aa";
    let public_id =
        WorkspacePublicId::parse("ws_018f6e217b707e7080000000000000aa".to_string()).unwrap();
    let fingerprint = json!({"operation":"workspace.create"});
    let intent = json!({
        "workspace_reservation":{
            "workspace_key":key,
            "workspace_public_id":public_id,
        },
        "terminal_reservation":{
            "terminal_id":"018f6e217b707e7080000000000000ab",
        },
    });
    {
        let mut registry = WorkspaceRegistry::open(&root, "interrupted-public-id").unwrap();
        registry
            .prepare_resource_creation(
                "interrupted-public-id-correlation",
                "interrupted-public-id-attempt",
                "workspace.create",
                &fingerprint,
                &intent,
                true,
                None,
                None,
            )
            .unwrap();
        registry
            .mark_resource_effect_executing(
                "interrupted-public-id-attempt",
                "workspace.create",
                &fingerprint,
            )
            .unwrap();
        let staged = RegistryWorkspace {
            id: 1,
            public_id: public_id.clone(),
            key: key.to_string(),
            name: "Reserved workspace".to_string(),
            group_key: "interrupted-public-id".to_string(),
        };
        registry
            .commit_for_resource_effect(
                &WorkspaceMutation::new("interrupted-public-id-workspace", "resource-api").unwrap(),
                &json!({"operation":"workspace.create","workspace_key":key}),
                None,
                None,
                "workspace-added",
                key,
                std::slice::from_ref(&staged),
                Some(&public_id),
                &json!({"workspace":1,"workspace_id":public_id,"key":key,"index":0}),
            )
            .unwrap();
        let public = registry.resource_topology_snapshot().unwrap();
        assert_eq!(public.revision, 0);
        assert!(public.active_screens.is_empty());
        assert_eq!(public.active_workspace, None);
    }

    let registry = WorkspaceRegistry::open(&root, "interrupted-public-id").unwrap();
    let staged = registry.interrupted_resource_workspaces().unwrap();
    assert_eq!(staged.len(), 1);
    assert_eq!(staged[0].1.public_id, public_id);
    assert_eq!(staged[0].1.key, key);
    let public = registry.resource_topology_snapshot().unwrap();
    assert_eq!(public.revision, 0);
    assert!(public.active_screens.is_empty());
    assert_eq!(public.active_workspace, None);
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn workspace_commit_publishes_one_normalized_resource_event() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "legacy-only");

    let snapshot = registry.snapshot().unwrap();
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.resource_revision, 1);
    let events = registry.resource_events_after(0).unwrap();
    assert_eq!(events.batches.len(), 1);
    assert_eq!(events.batches[0].previous_revision, 0);
    assert_eq!(events.batches[0].revision, 1);
    assert_eq!(events.batches[0].changes.as_array().unwrap().len(), 1);
    assert_eq!(events.batches[0].changes[0]["kind"], "upsert");
    assert_eq!(events.batches[0].changes[0]["resource"], "workspace");
    assert!(events.batches[0].changes[0].get("event").is_none());
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_mutations", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
}

fn terminal(id: &str, workspace_key: &str) -> RegistryTerminal {
    RegistryTerminal {
        terminal_id: id.into(),
        workspace_key: workspace_key.into(),
        incarnation: None,
        lifecycle: TerminalLifecycle::Launching,
        launch_spec: json!({"command":["/bin/zsh"],"cwd":"/tmp","rows":24,"cols":80}),
        exit: None,
    }
}

fn screen_id(value: u128) -> ScreenPublicId {
    ScreenPublicId::parse(format!("screen_{value:032x}")).unwrap()
}

fn pane_id(value: u128) -> PanePublicId {
    PanePublicId::parse(format!("pane_{value:032x}")).unwrap()
}

fn tab_id(value: u128) -> TabPublicId {
    TabPublicId::parse(format!("tab_{value:032x}")).unwrap()
}

fn split_id(value: u128) -> SplitPublicId {
    SplitPublicId::parse(format!("split_{value:032x}")).unwrap()
}

fn terminal_resource(id: &str) -> TerminalPublicId {
    let value = if id == TERMINAL_ONE { 1 } else { 2 };
    TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
}

fn agent_resource(terminal_id: &TerminalPublicId) -> crate::resource::AgentPublicId {
    let digest = Sha256::digest(format!("cmux.protocol/1/agent/{terminal_id}").as_bytes());
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    crate::resource::AgentPublicId::parse(format!("agent_{payload}")).unwrap()
}

fn browser_id(value: u128) -> BrowserPublicId {
    BrowserPublicId::parse(format!("browser_{value:032x}")).unwrap()
}

#[test]
fn machine_identity_is_state_root_global_and_survives_restart() {
    let root = temp_root("machine-identity");
    let first = WorkspaceRegistry::open(&root, "alpha").unwrap();
    let machine = first.machine_id().clone();
    let session = first.session_id().clone();
    let second = WorkspaceRegistry::open(&root, "beta").unwrap();
    assert_eq!(second.machine_id(), &machine);
    assert_ne!(second.session_id(), &session);
    drop(first);
    let restarted = WorkspaceRegistry::open(&root, "alpha").unwrap();
    assert_eq!(restarted.machine_id(), &machine);
    assert_eq!(restarted.session_id(), &session);
    drop(second);
    drop(restarted);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn concurrent_first_open_converges_on_one_machine_identity() {
    let root = temp_root("machine-race");
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(12));
    let threads = (0..12)
        .map(|index| {
            let root = root.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                WorkspaceRegistry::open(&root, &format!("session-{index}"))
                    .unwrap()
                    .machine_id()
                    .clone()
            })
        })
        .collect::<Vec<_>>();
    let identities =
        threads.into_iter().map(|thread| thread.join().unwrap()).collect::<HashSet<_>>();
    assert_eq!(identities.len(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn corrupt_machine_identity_fails_closed() {
    let root = temp_root("machine-corrupt");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join(MACHINE_ID_FILE), b"machine_not-an-id\n").unwrap();
    let error = WorkspaceRegistry::open(&root, "alpha").unwrap_err();
    assert!(error.to_string().contains("machine identity file is corrupt"));
    fs::remove_dir_all(root).unwrap();
}

#[cfg(unix)]
#[test]
fn machine_identity_files_are_owner_only() {
    use std::os::unix::fs::PermissionsExt;

    let root = temp_root("machine-mode");
    let registry = WorkspaceRegistry::open(&root, "alpha").unwrap();
    assert_eq!(
        fs::metadata(root.join(MACHINE_ID_FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.join(MACHINE_ID_LOCK_FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert_eq!(
        fs::metadata(root.join(RESOURCE_EFFECT_PEPPER_LOCK_FILE)).unwrap().permissions().mode()
            & 0o777,
        0o600
    );
    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn resource_effect_pepper_is_stable_per_root_and_unlinkable_across_roots() {
    let first_root = temp_root("receipt-pepper-first");
    let second_root = temp_root("receipt-pepper-second");
    let message = b"{\"text\":\"same secret\"}";
    let first = {
        let registry = WorkspaceRegistry::open(&first_root, "alpha").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let same_root = {
        let registry = WorkspaceRegistry::open(&first_root, "beta").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let reopened = {
        let registry = WorkspaceRegistry::open(&first_root, "alpha").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let second = {
        let registry = WorkspaceRegistry::open(&second_root, "alpha").unwrap();
        registry.resource_input_receipt_hmac("same-key", "terminal.input.write", message)
    };
    let memory_one = WorkspaceRegistry::in_memory("one").unwrap().resource_input_receipt_hmac(
        "same-key",
        "terminal.input.write",
        message,
    );
    let memory_two = WorkspaceRegistry::in_memory("two").unwrap().resource_input_receipt_hmac(
        "same-key",
        "terminal.input.write",
        message,
    );

    assert_eq!(first, same_root);
    assert_eq!(first, reopened);
    assert_ne!(first, second);
    assert_ne!(memory_one, memory_two);

    let pepper = fs::read(first_root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
    assert_eq!(pepper.len(), RESOURCE_EFFECT_PEPPER_BYTES);
    let session_dir = first_root.join(session_storage_component("alpha"));
    for entry in fs::read_dir(session_dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_file() {
            let bytes = fs::read(&path).unwrap();
            assert!(
                !bytes.windows(pepper.len()).any(|window| window == pepper),
                "raw receipt pepper persisted in {}",
                path.display()
            );
        }
    }

    fs::remove_dir_all(first_root).unwrap();
    fs::remove_dir_all(second_root).unwrap();
}

#[test]
fn resource_effect_pepper_missing_corrupt_and_mismatch_fail_closed() {
    let missing_root = temp_root("receipt-pepper-missing");
    drop(WorkspaceRegistry::open(&missing_root, "session").unwrap());
    fs::remove_file(missing_root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();
    assert!(
        WorkspaceRegistry::open(&missing_root, "session")
            .unwrap_err()
            .to_string()
            .contains("resource receipt pepper is missing")
    );
    fs::remove_dir_all(missing_root).unwrap();

    let corrupt_root = temp_root("receipt-pepper-corrupt");
    drop(WorkspaceRegistry::open(&corrupt_root, "session").unwrap());
    fs::write(corrupt_root.join(RESOURCE_EFFECT_PEPPER_FILE), b"short").unwrap();
    assert!(
        WorkspaceRegistry::open(&corrupt_root, "session")
            .unwrap_err()
            .to_string()
            .contains("resource receipt pepper is corrupt")
    );
    fs::remove_dir_all(corrupt_root).unwrap();

    let mismatch_root = temp_root("receipt-pepper-mismatch");
    drop(WorkspaceRegistry::open(&mismatch_root, "session").unwrap());
    fs::write(
        mismatch_root.join(RESOURCE_EFFECT_PEPPER_FILE),
        [0xa5; RESOURCE_EFFECT_PEPPER_BYTES],
    )
    .unwrap();
    assert!(
        WorkspaceRegistry::open(&mismatch_root, "session")
            .unwrap_err()
            .to_string()
            .contains("resource receipt pepper does not match")
    );
    fs::remove_dir_all(mismatch_root).unwrap();
}

fn viewport_screen() -> RegistryScreen {
    let workspace = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first = pane_id(1);
    let second = pane_id(2);
    let third = pane_id(3);
    let internal = split_id(1);
    let boundary = split_id(2);
    let base_column = split_id(3);
    let first_column = RegistryLayoutNode::Split {
        split: internal,
        direction: "down".into(),
        ratio: 0.5,
        first: Box::new(RegistryLayoutNode::Leaf { pane: first }),
        second: Box::new(RegistryLayoutNode::Leaf { pane: second }),
    };
    RegistryScreen {
        public_id: screen,
        workspace_id: workspace,
        position: 0,
        name: None,
        layout: RegistryLayoutNode::Split {
            split: boundary.clone(),
            direction: "right".into(),
            ratio: 1.0 / (1.0 + 0.5),
            first: Box::new(first_column.clone()),
            second: Box::new(RegistryLayoutNode::Leaf { pane: third.clone() }),
        },
        active_pane: third.clone(),
        zoomed_pane: Some(third.clone()),
        auto_layout: None,
        viewport: RegistryViewport {
            base_width: Some(1.0),
            columns: vec![
                RegistryViewportColumn {
                    id: base_column,
                    width: 1.0,
                    layout: first_column,
                    auto_layout: None,
                },
                RegistryViewportColumn {
                    id: boundary,
                    width: 0.5,
                    layout: RegistryLayoutNode::Leaf { pane: third },
                    auto_layout: Some(vec![pane_id(3)]),
                },
            ],
        },
    }
}

#[test]
fn viewport_schema_rejects_missing_duplicate_and_owner_splits() {
    let valid = viewport_screen();
    resource_store::validate_resource_patch(&ResourcePatch {
        changes: vec![ResourceChange::UpsertScreen(valid.clone())],
    })
    .unwrap();

    let mut missing = valid.clone();
    missing.viewport.columns[0].layout =
        RegistryLayoutNode::Stack { panes: vec![pane_id(1), pane_id(2)], expanded: pane_id(2) };
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(missing)],
        })
        .unwrap_err()
        .to_string()
        .contains("do not cover the screen splits")
    );

    let mut owner_inside = valid.clone();
    owner_inside.viewport.columns[1].id = split_id(1);
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(owner_inside)],
        })
        .unwrap_err()
        .to_string()
        .contains("boundary owner also appears inside")
    );

    let mut duplicate = valid.clone();
    let fourth = pane_id(4);
    if let RegistryLayoutNode::Split { second, .. } = &mut duplicate.layout {
        **second = RegistryLayoutNode::Split {
            split: split_id(4),
            direction: "down".into(),
            ratio: 0.5,
            first: Box::new(RegistryLayoutNode::Leaf { pane: pane_id(3) }),
            second: Box::new(RegistryLayoutNode::Leaf { pane: fourth.clone() }),
        };
    }
    duplicate.viewport.columns[1].layout = RegistryLayoutNode::Split {
        split: split_id(1),
        direction: "down".into(),
        ratio: 0.5,
        first: Box::new(RegistryLayoutNode::Leaf { pane: pane_id(3) }),
        second: Box::new(RegistryLayoutNode::Leaf { pane: fourth }),
    };
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(duplicate)],
        })
        .unwrap_err()
        .to_string()
        .contains("more than one viewport column")
    );

    let mut mismatch = valid;
    if let RegistryLayoutNode::Split { ratio, .. } = &mut mismatch.layout {
        *ratio = 0.5;
    }
    assert!(
        resource_store::validate_resource_patch(&ResourcePatch {
            changes: vec![ResourceChange::UpsertScreen(mismatch)],
        })
        .unwrap_err()
        .to_string()
        .contains("compatibility layout")
    );
}

fn terminal_topology_patch() -> ResourcePatch {
    let workspace = workspace(1, "one", "One");
    let screen = screen_id(1);
    let pane = pane_id(1);
    let tab = tab_id(1);
    let terminal_id = terminal_resource(TERMINAL_ONE);
    ResourcePatch {
        changes: vec![
            ResourceChange::UpsertWorkspace {
                workspace: workspace.clone(),
                position: 0,
                active_screen: Some(screen.clone()),
            },
            ResourceChange::UpsertScreen(RegistryScreen {
                public_id: screen.clone(),
                workspace_id: workspace.public_id.clone(),
                position: 0,
                name: Some("Main".into()),
                layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                active_pane: pane.clone(),
                zoomed_pane: None,
                auto_layout: None,
                viewport: RegistryViewport::default(),
            }),
            ResourceChange::UpsertPane(RegistryPane {
                public_id: pane.clone(),
                screen_id: screen.clone(),
                name: Some("Shell".into()),
                active_tab: Some(tab.clone()),
                creation_ordinal: 1,
            }),
            ResourceChange::UpsertTerminal {
                public_id: terminal_id.clone(),
                terminal: terminal(TERMINAL_ONE, "one"),
            },
            ResourceChange::UpsertTab(RegistryTab {
                public_id: tab.clone(),
                pane_id: pane.clone(),
                position: 0,
                content_id: ContentPublicId::Terminal(terminal_id),
                name: Some("zsh".into()),
                browser_url: None,
                terminal_id: Some(TERMINAL_ONE.into()),
            }),
            ResourceChange::SetWorkspaceOrder { workspace_ids: vec![workspace.public_id.clone()] },
            ResourceChange::SetScreenOrder {
                workspace_id: workspace.public_id.clone(),
                screen_ids: vec![screen],
            },
            ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab] },
            ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
        ],
    }
}

fn commit_terminal_topology(
    registry: &mut WorkspaceRegistry,
    mutation_id: &str,
) -> ResourcePatchCommit {
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new(mutation_id, "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"One"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({"workspace_id":workspace(1, "one", "One").public_id}),
            &json!([{"kind":"workspace.created"}]),
        )
        .unwrap()
}

fn commit_browser_topology(
    registry: &mut WorkspaceRegistry,
    mutation_id: &str,
    browser: RegistryBrowser,
) -> ResourcePatchCommit {
    let workspace_public_id = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first_pane = pane_id(1);
    let second_pane = pane_id(2);
    let second_tab = tab_id(2);
    let split = split_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new(mutation_id, "test").unwrap(),
            "tab.create_browser",
            &json!({"operation":"tab.create_browser"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Split {
                            split,
                            direction: "right".into(),
                            ratio: 0.5,
                            first: Box::new(RegistryLayoutNode::Leaf { pane: first_pane.clone() }),
                            second: Box::new(RegistryLayoutNode::Leaf {
                                pane: second_pane.clone(),
                            }),
                        },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen,
                        name: Some("Docs".into()),
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser(browser.clone()),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.public_id),
                        name: Some("Docs".into()),
                        browser_url: Some(browser.url),
                        terminal_id: None,
                    }),
                    ResourceChange::SetTabOrder { pane_id: second_pane, tab_ids: vec![second_tab] },
                ],
            },
            &json!({"created":true}),
            &json!([{"kind":"tab.created"}]),
        )
        .unwrap()
}

#[test]
fn resource_patch_commits_terminal_and_topology_in_one_revision() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let commit = commit_terminal_topology(&mut registry, "create-one");
    assert_eq!(commit.revision, 1);
    assert!(!commit.replayed);

    let snapshot = registry.resource_topology_snapshot().unwrap();
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.active_workspace, Some(workspace(1, "one", "One").public_id));
    assert_eq!(snapshot.screens.len(), 1);
    assert_eq!(snapshot.panes.len(), 1);
    assert_eq!(snapshot.tabs.len(), 1);
    assert_eq!(
        registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
        TerminalLifecycle::Launching
    );
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_events", [], |row| row.get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_mutations", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        1
    );
}

#[test]
fn resource_patch_replay_precedes_revision_and_rejects_changed_input() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let first = commit_terminal_topology(&mut registry, "same-key");
    let retry = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("same-key", "reconnected-client").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"One"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({"workspace_id":workspace(1, "one", "One").public_id}),
            &json!([{"kind":"workspace.created"}]),
        )
        .unwrap();
    assert_eq!(retry.revision, first.revision);
    assert!(retry.replayed);
    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("same-key", "another-client").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"Different"}),
            None,
            None,
            &terminal_topology_patch(),
            &json!({}),
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("idempotency.conflict"));
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
}

#[test]
fn resource_patch_replays_across_registry_reopen_and_origin_change() {
    let root = temp_root("resource-reconnect-replay");
    let first = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "reconnect-key")
    };
    let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let replay = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("reconnect-key", "new-connection").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create","name":"One"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({"workspace_id":workspace(1, "one", "One").public_id}),
            &json!([{"kind":"workspace.created"}]),
        )
        .unwrap();
    assert_eq!(replay.revision, first.revision);
    assert!(replay.replayed);
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
}

#[test]
fn resource_mutation_pruning_allows_only_one_batch_of_runtime_slack() {
    let mut registry = WorkspaceRegistry::in_memory("mutation-runtime-bound").unwrap();
    let capacity = resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
    let interval = usize::try_from(resource_store::RESOURCE_MUTATION_PRUNE_INTERVAL).unwrap();
    let before_boundary = capacity + interval - 1;
    {
        let tx = registry.connection.transaction().unwrap();
        for index in 0..before_boundary {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("bounded-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 1).unwrap(),
                ],
            )
            .unwrap();
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [before_boundary.to_string()],
        )
        .unwrap();
        resource_store::prune_resource_mutations(&tx).unwrap();
        tx.commit().unwrap();
    }
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(before_boundary).unwrap()
    );

    {
        let tx = registry.connection.transaction().unwrap();
        let index = before_boundary;
        tx.execute(
            "INSERT INTO resource_mutations(
               idempotency_key, origin, operation, fingerprint, result_json,
               committed_revision
             ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
            params![
                format!("bounded-{index:08}"),
                canonical_json(&json!({"sequence":index})).unwrap(),
                canonical_json(&json!({"sequence":index})).unwrap(),
                i64::try_from(index + 1).unwrap(),
            ],
        )
        .unwrap();
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [(before_boundary + 1).to_string()],
        )
        .unwrap();
        resource_store::prune_resource_mutations(&tx).unwrap();
        tx.commit().unwrap();
    }

    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity).unwrap()
    );
    let oldest: i64 = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = 'bounded-00000000'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let first_retained: i64 = registry
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = ?1",
            [format!("bounded-{interval:08}")],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(oldest, 0);
    assert_eq!(first_retained, 1);

    let pages_after_first_wave: i64 =
        registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap();
    let wave = capacity + interval;
    let mut pages = vec![pages_after_first_wave];
    for wave_index in 0..2 {
        let start = before_boundary + 1 + wave_index * wave;
        let tx = registry.connection.transaction().unwrap();
        for index in start..start + wave {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("bounded-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 1).unwrap(),
                ],
            )
            .unwrap();
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [(index + 1).to_string()],
            )
            .unwrap();
            resource_store::prune_resource_mutations(&tx).unwrap();
        }
        tx.commit().unwrap();
        assert_eq!(
            registry.resource_mutation_count_for_test().unwrap(),
            u64::try_from(capacity).unwrap()
        );
        pages.push(
            registry.connection.query_row("PRAGMA page_count", [], |row| row.get(0)).unwrap(),
        );
    }
    assert!(
        pages[1] <= pages[0] + 16,
        "mutation journal grew after reaching steady state: {pages:?}"
    );
    assert!(pages[2] <= pages[1] + 16, "mutation journal did not reuse freed pages: {pages:?}");
}

#[test]
fn completed_creation_counts_in_the_boundary_replay_window() {
    let mut registry = WorkspaceRegistry::in_memory("creation-mutation-bound").unwrap();
    let capacity = resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
    let interval = usize::try_from(resource_store::RESOURCE_MUTATION_PRUNE_INTERVAL).unwrap();
    let boundary = capacity + interval;
    let before_boundary = boundary - 1;
    {
        let tx = registry.connection.transaction().unwrap();
        for index in 0..before_boundary {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("creation-bound-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 1).unwrap(),
                ],
            )
            .unwrap();
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [before_boundary.to_string()],
        )
        .unwrap();
        tx.commit().unwrap();
    }

    let fingerprint = json!({"name":"boundary"});
    registry
        .prepare_resource_creation(
            "boundary-correlation",
            "boundary-attempt",
            "test.create.boundary",
            &fingerprint,
            &json!({"reservation":"boundary"}),
            false,
            None,
            Some(u64::try_from(before_boundary).unwrap()),
        )
        .unwrap();
    registry
        .commit_resource_creation_patch(
            "boundary-correlation",
            &WorkspaceMutation::new("boundary-attempt", "test").unwrap(),
            "test.create.boundary",
            &fingerprint,
            &ResourcePatch { changes: Vec::new() },
            &json!({"created":true}),
            &json!({"kind":"test","id":"boundary"}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity).unwrap()
    );

    {
        let tx = registry.connection.transaction().unwrap();
        for offset in 1..interval {
            let revision = boundary + offset;
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("creation-slack-{offset:08}"),
                    canonical_json(&json!({"sequence":revision})).unwrap(),
                    canonical_json(&json!({"sequence":revision})).unwrap(),
                    i64::try_from(revision).unwrap(),
                ],
            )
            .unwrap();
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [revision.to_string()],
            )
            .unwrap();
            resource_store::prune_resource_mutations(&tx).unwrap();
        }
        tx.commit().unwrap();
    }
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity + interval - 1).unwrap()
    );

    {
        let tx = registry.connection.transaction().unwrap();
        let revision = boundary + interval;
        tx.execute(
            "INSERT INTO resource_mutations(
               idempotency_key, origin, operation, fingerprint, result_json,
               committed_revision
             ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
            params![
                "creation-next-boundary",
                canonical_json(&json!({"sequence":revision})).unwrap(),
                canonical_json(&json!({"sequence":revision})).unwrap(),
                i64::try_from(revision).unwrap(),
            ],
        )
        .unwrap();
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )
        .unwrap();
        resource_store::prune_resource_mutations(&tx).unwrap();
        tx.commit().unwrap();
    }
    assert_eq!(
        registry.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity).unwrap()
    );
}

#[test]
fn startup_mutation_compaction_preserves_recovery_authorities_and_recent_replay() {
    let root = temp_root("mutation-startup-bound");
    let effect_fingerprint = json!({"title":"pending"});
    let effect_intent = json!({"notification_id":"reserved"});
    let active_creation_fingerprint = json!({"name":"active"});
    let active_creation_intent = json!({"reservation":"active"});
    let created_fingerprint = json!({"name":"created"});
    let created_intent = json!({"reservation":"created"});
    let created_path = json!({"kind":"test","id":"created"});
    let capacity = resource_store::RESOURCE_MUTATION_REPLAY_CAPACITY;
    let ordinary_count = capacity + 32;

    {
        let mut registry = WorkspaceRegistry::open(&root, "mutation-retention").unwrap();
        registry
            .prepare_resource_creation(
                "created-correlation",
                "created-attempt",
                "test.create.completed",
                &created_fingerprint,
                &created_intent,
                false,
                None,
                Some(0),
            )
            .unwrap();
        registry
            .commit_resource_creation_patch(
                "created-correlation",
                &WorkspaceMutation::new("created-attempt", "test").unwrap(),
                "test.create.completed",
                &created_fingerprint,
                &ResourcePatch { changes: Vec::new() },
                &json!({"created":true}),
                &created_path,
                &json!([]),
            )
            .unwrap();
        registry
            .prepare_resource_effect(
                "pending-effect",
                "notification.create",
                &effect_fingerprint,
                &effect_intent,
                None,
                None,
            )
            .unwrap();
        registry
            .prepare_resource_creation(
                "active-correlation",
                "active-attempt",
                "test.create.active",
                &active_creation_fingerprint,
                &active_creation_intent,
                false,
                None,
                None,
            )
            .unwrap();

        let tx = registry.connection.transaction().unwrap();
        for (key, operation, fingerprint, result, revision) in [
            (
                "pending-effect",
                "notification.create",
                effect_fingerprint.clone(),
                json!({"pending":true}),
                2_i64,
            ),
            (
                "active-attempt",
                "test.create.active",
                active_creation_fingerprint.clone(),
                json!({"active":true}),
                3_i64,
            ),
            (
                "terminal-defaults",
                "session.terminal_defaults.update",
                json!({"operation":"session.terminal_defaults.update"}),
                json!({
                    "foreground":"#123456",
                    "background":null,
                    "cursor":null,
                    "selection_background":null,
                    "selection_foreground":null,
                    "cursor_style":"block",
                    "cursor_blink":false,
                    "palette":{},
                }),
                4_i64,
            ),
        ] {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', ?2, ?3, ?4, ?5)",
                params![
                    key,
                    operation,
                    canonical_json(&fingerprint).unwrap(),
                    canonical_json(&result).unwrap(),
                    revision,
                ],
            )
            .unwrap();
        }
        for index in 0..ordinary_count {
            tx.execute(
                "INSERT INTO resource_mutations(
                   idempotency_key, origin, operation, fingerprint, result_json,
                   committed_revision
                 ) VALUES(?1, 'test', 'test.pure', ?2, ?3, ?4)",
                params![
                    format!("ordinary-{index:08}"),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    canonical_json(&json!({"sequence":index})).unwrap(),
                    i64::try_from(index + 5).unwrap(),
                ],
            )
            .unwrap();
        }
        tx.commit().unwrap();
        assert_eq!(
            registry.resource_mutation_count_for_test().unwrap(),
            u64::try_from(ordinary_count + 4).unwrap()
        );
    }

    let reopened = WorkspaceRegistry::open(&root, "mutation-retention").unwrap();
    assert_eq!(
        reopened.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity + 3).unwrap()
    );
    for key in ["pending-effect", "active-attempt", "terminal-defaults"] {
        let count: i64 = reopened
            .connection
            .query_row(
                "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1, "{key}");
    }
    for key in ["created-attempt", "ordinary-00000000"] {
        let count: i64 = reopened
            .connection
            .query_row(
                "SELECT COUNT(*) FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 0, "{key}");
    }

    assert_eq!(
        reopened
            .lookup_resource_effect("pending-effect", "notification.create", &effect_fingerprint,)
            .unwrap(),
        Some(ResourceEffectPreparation::Execute { intent: effect_intent, resumed: true })
    );
    assert_eq!(
        reopened
            .lookup_resource_creation(
                "active-correlation",
                "active-attempt",
                "test.create.active",
                &active_creation_fingerprint,
                false,
            )
            .unwrap(),
        Some(ResourceCreationPreparation::Execute {
            idempotency_key: "active-attempt".to_string(),
            intent: active_creation_intent,
            resumed: true,
        })
    );
    assert!(matches!(
        reopened
            .lookup_resource_creation(
                "created-correlation",
                "created-attempt",
                "test.create.completed",
                &created_fingerprint,
                false,
            )
            .unwrap(),
        Some(ResourceCreationPreparation::Created { created_path: path, revision: 1, .. })
            if path == created_path
    ));
    assert!(
        reopened
            .replay_resource_patch(
                &WorkspaceMutation::new("created-attempt", "retry").unwrap(),
                "test.create.completed",
                &created_fingerprint,
            )
            .unwrap()
            .is_none(),
        "completed correlation remains authoritative after its replay key expires"
    );

    let newest_index = ordinary_count - 1;
    let newest_key = format!("ordinary-{newest_index:08}");
    let newest_fingerprint = json!({"sequence":newest_index});
    let replay = reopened
        .replay_resource_patch(
            &WorkspaceMutation::new(&newest_key, "retry").unwrap(),
            "test.pure",
            &newest_fingerprint,
        )
        .unwrap()
        .unwrap();
    assert!(replay.replayed);
    assert_eq!(replay.result, json!({"sequence":newest_index}));
    let conflict = reopened
        .replay_resource_patch(
            &WorkspaceMutation::new(&newest_key, "retry").unwrap(),
            "test.pure",
            &json!({"sequence":"changed"}),
        )
        .unwrap_err();
    assert!(conflict.to_string().contains("idempotency.conflict"));
    assert!(reopened.public_projections().unwrap().terminal_defaults.is_some());
    drop(reopened);

    let reopened_again = WorkspaceRegistry::open(&root, "mutation-retention").unwrap();
    assert_eq!(
        reopened_again.resource_mutation_count_for_test().unwrap(),
        u64::try_from(capacity + 3).unwrap()
    );
    drop(reopened_again);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn resource_patch_failure_rolls_back_every_projection_and_log() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    registry.set_resource_patch_failure(true).unwrap();
    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("forced-failure", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create"}),
            None,
            Some(0),
            &terminal_topology_patch(),
            &json!({}),
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("forced resource patch failure"));
    registry.set_resource_patch_failure(false).unwrap();
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 0);
    assert!(registry.snapshot().unwrap().workspaces.is_empty());
    assert!(registry.terminal_record(TERMINAL_ONE).unwrap().is_none());
    for table in [
        "resource_identities",
        "resource_screens",
        "resource_panes",
        "resource_tabs",
        "resource_terminals",
        "resource_mutations",
        "resource_events",
    ] {
        let count = registry
            .connection
            .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get::<_, i64>(0))
            .unwrap();
        assert_eq!(count, 0, "{table} was not rolled back");
    }
}

#[test]
fn targeted_resource_patch_does_not_rewrite_unrelated_rows() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let pane = pane_id(1);
    let screen = screen_id(1);
    let tab = tab_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("rename-pane", "test").unwrap(),
            "pane.rename",
            &json!({"operation":"pane.rename","pane_id":pane,"name":"Build"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![ResourceChange::UpsertPane(RegistryPane {
                    public_id: pane.clone(),
                    screen_id: screen.clone(),
                    name: Some("Build".into()),
                    active_tab: Some(tab.clone()),
                    creation_ordinal: 1,
                })],
            },
            &json!({"pane_id":pane}),
            &json!([{"kind":"pane.renamed"}]),
        )
        .unwrap();
    let revisions = |table: &str, public_id: &str| {
        registry
            .connection
            .query_row(
                &format!("SELECT updated_revision FROM {table} WHERE public_id = ?1"),
                [public_id],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
    };
    assert_eq!(revisions("resource_panes", pane.as_str()), 2);
    assert_eq!(revisions("resource_screens", screen.as_str()), 1);
    assert_eq!(revisions("resource_tabs", tab.as_str()), 1);
    assert_eq!(revisions("resource_terminals", terminal_resource(TERMINAL_ONE).as_str()), 1);
}

#[test]
fn resource_tombstones_prevent_public_id_and_workspace_key_reuse() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let workspace = workspace(1, "one", "One");
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("close", "test").unwrap(),
            "workspace.close",
            &json!({"operation":"workspace.close","workspace_id":workspace.public_id}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::TombstoneWorkspace {
                        workspace_id: workspace.public_id.clone(),
                    },
                    ResourceChange::SetWorkspaceOrder { workspace_ids: vec![] },
                    ResourceChange::SetActiveWorkspace { workspace_id: None },
                ],
            },
            &json!({"closed":true}),
            &json!([{"kind":"workspace.closed"}]),
        )
        .unwrap();
    assert!(registry.resource_topology_snapshot().unwrap().screens.is_empty());
    assert!(registry.terminal_snapshot().unwrap().terminals.is_empty());
    let error = registry
        .commit_resource_patch(
            &WorkspaceMutation::new("recreate", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create"}),
            None,
            Some(2),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace { workspace, position: 0, active_screen: None },
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![
                            WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
                        ],
                    },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap_err();
    assert!(error.to_string().contains("tombstoned workspace key cannot be reused"));
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 2);
}

#[test]
fn resource_order_is_exact_and_positions_are_contiguous() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let one = workspace(1, "one", "One");
    let two = workspace(2, "two", "Two");
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("create-two", "test").unwrap(),
            "workspace.create",
            &json!({"operation":"workspace.create"}),
            None,
            Some(0),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: one.clone(),
                        position: 0,
                        active_screen: None,
                    },
                    ResourceChange::UpsertWorkspace {
                        workspace: two.clone(),
                        position: 1,
                        active_screen: None,
                    },
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![one.public_id.clone(), two.public_id.clone()],
                    },
                    ResourceChange::SetActiveWorkspace {
                        workspace_id: Some(one.public_id.clone()),
                    },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("move", "test").unwrap(),
            "workspace.move",
            &json!({"operation":"workspace.move"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![ResourceChange::SetWorkspaceOrder {
                    workspace_ids: vec![two.public_id.clone(), one.public_id.clone()],
                }],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        registry
            .snapshot()
            .unwrap()
            .workspaces
            .into_iter()
            .map(|workspace| workspace.public_id)
            .collect::<Vec<_>>(),
        vec![two.public_id, one.public_id]
    );
}

#[test]
fn resource_ids_survive_registry_restart() {
    let root = temp_root("resource-restart");
    let before = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "create");
        registry.resource_topology_snapshot().unwrap()
    };
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let after = registry.resource_topology_snapshot().unwrap();
    assert_eq!(after.session_id, before.session_id);
    assert_eq!(after.revision, before.revision);
    assert_eq!(after.active_workspace, before.active_workspace);
    assert_eq!(after.screens, before.screens);
    assert_eq!(after.panes, before.panes);
    assert_eq!(after.tabs, before.tabs);
    assert_eq!(after.browsers, before.browsers);
    assert_ne!(after.generation, before.generation);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn browser_restart_metadata_is_safe_and_exact() {
    let browser = RegistryBrowser {
        public_id: browser_id(1),
        url: "https://cmux.dev/docs".into(),
        source: RegistryBrowserSource::External,
        launch: RegistryBrowserLaunch::Adopted,
        reconnect: RegistryBrowserReconnect::Recreate,
        status: RegistryBrowserStatus::Live,
        cols: 117,
        rows: 43,
    };
    let encoded = serde_json::to_string(&browser).unwrap();
    for forbidden in
        ["target_id", "session_id", "websocket", "access_token", "authorization", "cdp"]
    {
        assert!(!encoded.contains(forbidden), "browser metadata leaked {forbidden}");
    }

    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    commit_browser_topology(&mut registry, "browser", browser.clone());
    assert_eq!(registry.resource_topology_snapshot().unwrap().browsers, vec![browser]);
}

#[test]
fn invalid_browser_restart_metadata_is_rejected_before_commit() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let error = commit_browser_topology_unchecked(
        &mut registry,
        RegistryBrowser::recreate(browser_id(1), "https://cmux.dev".into(), 0, 24),
    );
    assert!(error.to_string().contains("invalid size 0x24"));
    assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
}

fn commit_browser_topology_unchecked(
    registry: &mut WorkspaceRegistry,
    browser: RegistryBrowser,
) -> anyhow::Error {
    let workspace_public_id = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first_pane = pane_id(1);
    let second_pane = pane_id(2);
    let second_tab = tab_id(2);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("invalid-browser", "test").unwrap(),
            "tab.create_browser",
            &json!({"operation":"tab.create_browser"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Split {
                            split: split_id(1),
                            direction: "right".into(),
                            ratio: 0.5,
                            first: Box::new(RegistryLayoutNode::Leaf { pane: first_pane.clone() }),
                            second: Box::new(RegistryLayoutNode::Leaf {
                                pane: second_pane.clone(),
                            }),
                        },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen,
                        name: None,
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser(browser.clone()),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.public_id),
                        name: None,
                        browser_url: Some(browser.url),
                        terminal_id: None,
                    }),
                    ResourceChange::SetTabOrder { pane_id: second_pane, tab_ids: vec![second_tab] },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap_err()
}

#[test]
fn corrupt_browser_restart_metadata_fails_closed_on_open() {
    let root = temp_root("browser-metadata-corrupt");
    let browser = browser_id(1);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "create");
        commit_browser_topology(
            &mut registry,
            "browser",
            RegistryBrowser::recreate(browser.clone(), "https://cmux.dev".into(), 91, 31),
        );
    }
    let session_dir = root.join(session_storage_component("session"));
    let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
    connection
        .execute(
            "UPDATE resource_browsers
             SET metadata_json = '{\"public_id\":\"browser_00000000000000000000000000000001\",\"url\":\"https://cmux.dev\",\"source\":\"unknown\",\"launch\":\"create\",\"reconnect\":\"recreate\",\"status\":\"starting\",\"cols\":91,\"rows\":31,\"target_id\":\"secret\"}'
             WHERE public_id = ?1",
            [browser.as_str()],
        )
        .unwrap();
    drop(connection);
    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    assert!(error.to_string().contains("invalid metadata for browser"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn split_and_browser_identities_follow_targeted_parent_lifecycle() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    commit_terminal_topology(&mut registry, "create");
    let workspace_public_id = workspace(1, "one", "One").public_id;
    let screen = screen_id(1);
    let first_pane = pane_id(1);
    let second_pane = pane_id(2);
    let second_tab = tab_id(2);
    let split = split_id(1);
    let browser = browser_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("split", "test").unwrap(),
            "pane.split",
            &json!({"operation":"pane.split"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id.clone(),
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Split {
                            split: split.clone(),
                            direction: "right".into(),
                            ratio: 0.5,
                            first: Box::new(RegistryLayoutNode::Leaf { pane: first_pane.clone() }),
                            second: Box::new(RegistryLayoutNode::Leaf {
                                pane: second_pane.clone(),
                            }),
                        },
                        active_pane: first_pane.clone(),
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen.clone(),
                        name: Some("Docs".into()),
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser(RegistryBrowser::recreate(
                        browser.clone(),
                        "https://cmux.dev".into(),
                        80,
                        24,
                    )),
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.clone()),
                        name: Some("Docs".into()),
                        browser_url: Some("https://cmux.dev".into()),
                        terminal_id: None,
                    }),
                    ResourceChange::SetTabOrder {
                        pane_id: second_pane.clone(),
                        tab_ids: vec![second_tab],
                    },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    assert_eq!(
        registry
            .connection
            .query_row(
                "SELECT kind FROM resource_identities
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                [split.as_str()],
                |row| row.get::<_, String>(0),
            )
            .unwrap(),
        "split"
    );

    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("unsplit", "test").unwrap(),
            "pane.close",
            &json!({"operation":"pane.close"}),
            None,
            Some(2),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertScreen(RegistryScreen {
                        public_id: screen,
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Leaf { pane: first_pane.clone() },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::TombstonePane { pane_id: second_pane },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    for public_id in [split.as_str(), browser.as_str()] {
        assert!(
            registry
                .connection
                .query_row(
                    "SELECT deleted_revision FROM resource_identities WHERE public_id = ?1",
                    [public_id],
                    |row| row.get::<_, Option<i64>>(0),
                )
                .unwrap()
                .is_some()
        );
    }
}

#[test]
fn resource_identity_sql_check_rejects_non_hex_payload() {
    let registry = WorkspaceRegistry::in_memory("test").unwrap();
    let invalid = format!("pane_{}", "z".repeat(32));
    let error = registry
        .connection
        .execute(
            "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'pane', 1, 1, NULL)",
            [&invalid],
        )
        .unwrap_err();
    assert!(error.to_string().contains("CHECK constraint failed"));
}

#[test]
fn deferred_terminal_foreign_keys_reject_orphans_at_commit() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let public_id = terminal_resource(TERMINAL_TWO);
    {
        let tx = registry.connection.transaction().unwrap();
        tx.execute(
            "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'terminal', 1, 1, NULL)",
            [public_id.as_str()],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO resource_terminals(
                   public_id, terminal_id, lifecycle,
                   created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, ?2, 'active', 1, 1, NULL)",
            params![public_id.as_str(), TERMINAL_TWO],
        )
        .unwrap();
        assert!(tx.commit().unwrap_err().to_string().contains("FOREIGN KEY constraint failed"));
    }
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM resource_terminals", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
        0
    );

    let tx = registry.connection.transaction().unwrap();
    tx.execute(
        "INSERT INTO terminal_placements(
               terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
               exit_json, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'missing', NULL, 'launching', '{}', NULL, 1, 1, NULL)",
        [TERMINAL_TWO],
    )
    .unwrap();
    assert!(tx.commit().unwrap_err().to_string().contains("FOREIGN KEY constraint failed"));
}

#[test]
fn thousand_workspace_rename_has_bounded_writes_and_time() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let workspaces = (1..=1_000)
        .map(|id| workspace(id, &format!("workspace-{id}"), &format!("Workspace {id}")))
        .collect::<Vec<_>>();
    let mut changes = workspaces
        .iter()
        .enumerate()
        .map(|(position, workspace)| ResourceChange::UpsertWorkspace {
            workspace: workspace.clone(),
            position,
            active_screen: None,
        })
        .collect::<Vec<_>>();
    changes.push(ResourceChange::SetWorkspaceOrder {
        workspace_ids: workspaces.iter().map(|workspace| workspace.public_id.clone()).collect(),
    });
    changes.push(ResourceChange::SetActiveWorkspace {
        workspace_id: Some(workspaces[0].public_id.clone()),
    });
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("seed-1000", "perf-test").unwrap(),
            "workspace.create",
            &json!({"count":1000}),
            None,
            Some(0),
            &ResourcePatch { changes },
            &json!({}),
            &json!([]),
        )
        .unwrap();

    let target = workspaces[499].clone();
    let mut renamed = target.clone();
    renamed.name = "Renamed".into();
    let changes_before = registry.connection.total_changes();
    let started = std::time::Instant::now();
    registry
        .commit_resource_patch(
            &WorkspaceMutation::new("rename-one-of-1000", "perf-test").unwrap(),
            "workspace.rename",
            &json!({"workspace_id":target.public_id,"name":"Renamed"}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![ResourceChange::UpsertWorkspace {
                    workspace: renamed,
                    position: 499,
                    active_screen: None,
                }],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();
    let elapsed = started.elapsed();
    let changed_rows = registry.connection.total_changes() - changes_before;
    assert!(changed_rows <= 8, "rename changed {changed_rows} rows");
    assert!(elapsed < std::time::Duration::from_secs(1), "targeted rename took {elapsed:?}");
    assert_eq!(
        registry
            .connection
            .query_row("SELECT COUNT(*) FROM workspaces WHERE updated_revision = 2", [], |row| row
                .get::<_, i64>(
                0
            ),)
            .unwrap(),
        1
    );
    assert_eq!(
        registry
            .connection
            .query_row(
                "SELECT COUNT(*) FROM resource_workspaces WHERE updated_revision = 2",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap(),
        1
    );
}

#[test]
fn durable_commit_recovers_and_changes_generation() {
    let root = temp_root("recover");
    let first = {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let before = registry.snapshot().unwrap();
        let mutation = WorkspaceMutation::new(new_uuid_v4(), "browser").unwrap();
        let result = json!({"key":"one"});
        let commit = registry
            .commit(
                &mutation,
                &json!({"op":"create","key":"one"}),
                None,
                Some(0),
                "workspace-added",
                "one",
                &[RegistryWorkspace {
                    id: 1,
                    public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
                    key: "one".into(),
                    name: "One".into(),
                    group_key: "default".into(),
                }],
                &result,
            )
            .unwrap();
        assert_eq!(commit.revision, 1);
        (before.registry_id, before.generation)
    };
    let recovered = WorkspaceRegistry::open(&root, "session").unwrap();
    let snapshot = recovered.snapshot().unwrap();
    assert_eq!(snapshot.registry_id, first.0);
    assert_ne!(snapshot.generation, first.1);
    assert_eq!(snapshot.revision, 1);
    assert_eq!(snapshot.workspaces[0].key, "one");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn retry_precedes_revision_check_and_payload_mismatch_is_rejected() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    let mutation = WorkspaceMutation::new("mutation", "browser").unwrap();
    let fingerprint = json!({"op":"create","key":"one"});
    let result = json!({"key":"one"});
    let workspaces = [RegistryWorkspace {
        id: 1,
        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
        key: "one".into(),
        name: "One".into(),
        group_key: "default".into(),
    }];
    let first = registry
        .commit(
            &mutation,
            &fingerprint,
            None,
            Some(0),
            "workspace-added",
            "one",
            &workspaces,
            &result,
        )
        .unwrap();
    assert!(!first.replayed);
    let retry = registry
        .commit(
            &mutation,
            &fingerprint,
            None,
            Some(0),
            "workspace-added",
            "one",
            &workspaces,
            &result,
        )
        .unwrap();
    assert!(retry.replayed);
    assert_eq!(retry.revision, 1);
    assert!(
        registry
            .commit(
                &mutation,
                &json!({"op":"create","key":"different"}),
                None,
                None,
                "workspace-added",
                "different",
                &workspaces,
                &result,
            )
            .is_err()
    );
}

#[test]
fn second_writer_is_rejected() {
    let root = temp_root("lease");
    let first = WorkspaceRegistry::open(&root, "same").unwrap();
    assert!(WorkspaceRegistry::open(&root, "same").is_err());
    drop(first);
    WorkspaceRegistry::open(&root, "same").unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn tombstones_prevent_workspace_key_reuse() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    registry
        .commit(
            &WorkspaceMutation::new("create", "browser").unwrap(),
            &json!({"op":"create"}),
            None,
            Some(0),
            "workspace-added",
            "stable",
            &[workspace(1, "stable", "One")],
            &json!({"workspace":1,"key":"stable"}),
        )
        .unwrap();
    assert_eq!(registry.snapshot().unwrap().next_numeric_id, 2);
    registry
        .commit(
            &WorkspaceMutation::new("close", "browser").unwrap(),
            &json!({"op":"close"}),
            None,
            Some(1),
            "workspace-closed",
            "stable",
            &[],
            &json!({"workspace":1,"key":"stable"}),
        )
        .unwrap();
    assert_eq!(registry.snapshot().unwrap().next_numeric_id, 2);
    let error = registry
        .commit(
            &WorkspaceMutation::new("recreate", "browser").unwrap(),
            &json!({"op":"create"}),
            None,
            Some(2),
            "workspace-added",
            "stable",
            &[workspace(2, "stable", "Again")],
            &json!({"workspace":2,"key":"stable"}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("tombstoned workspace key cannot be reused"));
}

#[test]
fn frontend_projection_is_durable_cas_and_exactly_once() {
    let root = temp_root("projection");
    let mutation = WorkspaceMutation::new("layout-1", "browser-profile").unwrap();
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let first = registry
            .put_frontend_projection(
                &mutation,
                "cmux-browser",
                "window-group",
                "group-a",
                1,
                Some(0),
                &json!({"columns":[{"workspace":"one"}]}),
            )
            .unwrap();
        assert_eq!(first.projection.projection_revision, 1);
        assert!(!first.replayed);
        let retry = registry
            .put_frontend_projection(
                &mutation,
                "cmux-browser",
                "window-group",
                "group-a",
                1,
                Some(0),
                &json!({"columns":[{"workspace":"one"}]}),
            )
            .unwrap();
        assert!(retry.replayed);
        assert_eq!(retry.projection.projection_revision, 1);
        assert!(
            registry
                .put_frontend_projection(
                    &WorkspaceMutation::new("layout-2", "browser-profile").unwrap(),
                    "cmux-browser",
                    "window-group",
                    "group-a",
                    1,
                    Some(0),
                    &json!({}),
                )
                .unwrap_err()
                .to_string()
                .contains("projection revision conflict")
        );
    }
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    let recovered = registry
        .get_frontend_projection("cmux-browser", "window-group", "group-a")
        .unwrap()
        .unwrap();
    assert_eq!(recovered.projection_revision, 1);
    assert_eq!(recovered.projection["columns"][0]["workspace"], "one");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn terminal_lifecycle_is_exactly_once_and_has_an_independent_revision() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    assert_eq!(registry.snapshot().unwrap().revision, 1);
    assert_eq!(registry.terminal_snapshot().unwrap().revision, 0);

    let terminal = terminal(TERMINAL_ONE, "one");
    let reserve = WorkspaceMutation::new("reserve-1", "browser").unwrap();
    let fingerprint = json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE});
    let result = json!({"terminal_id":TERMINAL_ONE,"state":"launching"});
    let first = registry
        .commit_terminal(
            &reserve,
            &fingerprint,
            None,
            Some(0),
            "terminal-added",
            &terminal,
            &result,
        )
        .unwrap();
    assert_eq!(first.revision, 1);
    assert!(!first.replayed);
    let retry = registry
        .commit_terminal(
            &reserve,
            &fingerprint,
            None,
            Some(0),
            "terminal-added",
            &terminal,
            &result,
        )
        .unwrap();
    assert_eq!(retry.revision, 1);
    assert!(retry.replayed);

    let mut adopting = terminal.clone();
    adopting.lifecycle = TerminalLifecycle::Adopting;
    adopting.incarnation = Some(INCARNATION_ONE.into());
    registry
        .commit_terminal(
            &WorkspaceMutation::new("adopt-1", "daemon").unwrap(),
            &json!({"op":"adopt-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(1),
            "terminal-adopting",
            &adopting,
            &json!({"terminal_id":TERMINAL_ONE,"state":"adopting"}),
        )
        .unwrap();
    let mut running = adopting;
    running.lifecycle = TerminalLifecycle::Running;
    registry
        .commit_terminal(
            &WorkspaceMutation::new("ready-1", "daemon").unwrap(),
            &json!({"op":"terminal-ready","terminal_id":TERMINAL_ONE}),
            None,
            Some(2),
            "terminal-ready",
            &running,
            &json!({"terminal_id":TERMINAL_ONE,"state":"running"}),
        )
        .unwrap();

    let terminals = registry.terminal_snapshot().unwrap();
    assert_eq!(terminals.revision, 3);
    assert_eq!(terminals.terminals, vec![running]);
    assert_eq!(registry.snapshot().unwrap().revision, 1);
    assert_eq!(registry.terminal_events_after(0).unwrap().len(), 3);
}

#[test]
fn first_exit_metadata_wins_and_exited_ids_cannot_be_relaunched() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    let launching = terminal(TERMINAL_ONE, "one");
    registry
        .commit_terminal(
            &WorkspaceMutation::new("reserve", "browser").unwrap(),
            &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(0),
            "terminal-reserved",
            &launching,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();

    let mut first_exit = launching.clone();
    first_exit.lifecycle = TerminalLifecycle::Exited;
    first_exit.exit = Some(json!({"reason":"first-observer","status":17}));
    let first = registry
        .commit_terminal(
            &WorkspaceMutation::new("exit-one", "daemon").unwrap(),
            &json!({"op":"terminal-exited","terminal_id":TERMINAL_ONE}),
            None,
            Some(1),
            "terminal-exited",
            &first_exit,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();
    assert_eq!(first.revision, 2);

    let mut late_exit = first_exit.clone();
    late_exit.exit = Some(json!({"reason":"late-observer","status":99}));
    let duplicate = registry
        .commit_terminal(
            &WorkspaceMutation::new("exit-two", "daemon").unwrap(),
            &json!({"op":"terminal-exited-again","terminal_id":TERMINAL_ONE}),
            None,
            Some(2),
            "terminal-exited",
            &late_exit,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();
    assert!(duplicate.replayed);
    assert_eq!(duplicate.revision, 2);
    assert_eq!(registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().exit, first_exit.exit);
    assert_eq!(registry.terminal_events_after(0).unwrap().len(), 2);

    let error = registry
        .commit_terminal(
            &WorkspaceMutation::new("reuse-exited", "browser").unwrap(),
            &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(2),
            "terminal-reserved",
            &launching,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("invalid terminal transition Exited -> Launching"));
    assert_eq!(
        registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
        TerminalLifecycle::Exited
    );
}

#[test]
fn batch_terminal_close_rolls_back_every_tab_on_mid_transaction_failure() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    for (revision, terminal_id) in [(0, TERMINAL_ONE), (1, TERMINAL_TWO)] {
        registry
            .commit_terminal(
                &WorkspaceMutation::new(format!("reserve-{revision}"), "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":terminal_id}),
                None,
                Some(revision),
                "terminal-reserved",
                &terminal(terminal_id, "one"),
                &json!({"terminal_id":terminal_id}),
            )
            .unwrap();
    }
    registry
        .connection
        .execute_batch(&format!(
            "CREATE TEMP TRIGGER fail_second_terminal_close
                 BEFORE UPDATE OF lifecycle ON terminal_placements
                 WHEN NEW.terminal_id = '{TERMINAL_TWO}'
                 BEGIN SELECT RAISE(ABORT, 'forced batch failure'); END;"
        ))
        .unwrap();
    let requests = vec![(TERMINAL_ONE.to_string(), None), (TERMINAL_TWO.to_string(), None)];
    let error = registry
        .close_terminals_atomically(
            &WorkspaceMutation::new("close-pane-failed", "tui").unwrap(),
            &requests,
        )
        .unwrap_err();
    assert!(error.to_string().contains("forced batch failure"));
    assert_eq!(registry.terminal_snapshot().unwrap().revision, 2);
    for terminal_id in [TERMINAL_ONE, TERMINAL_TWO] {
        assert_eq!(
            registry.terminal_record(terminal_id).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Launching
        );
    }
    registry.connection.execute_batch("DROP TRIGGER fail_second_terminal_close").unwrap();

    let closed = registry
        .close_terminals_atomically(
            &WorkspaceMutation::new("close-pane", "tui").unwrap(),
            &requests,
        )
        .unwrap();
    assert_eq!(closed, TerminalBatchClose { revision: 4, closed: 2 });
    assert_eq!(registry.terminal_events_after(2).unwrap().len(), 2);
    for terminal_id in [TERMINAL_ONE, TERMINAL_TWO] {
        assert_eq!(
            registry.terminal_record(terminal_id).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Tombstoned
        );
    }
}

#[test]
fn terminal_close_tombstones_before_kill_and_retries_safely() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    let terminal = terminal(TERMINAL_ONE, "one");
    registry
        .commit_terminal(
            &WorkspaceMutation::new("reserve-1", "browser").unwrap(),
            &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(0),
            "terminal-added",
            &terminal,
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap();

    let close = WorkspaceMutation::new("close-1", "browser").unwrap();
    let first = registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert_eq!(first.revision, 2);
    assert_eq!(first.result["already_closed"], false);
    assert_eq!(
        registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
        TerminalLifecycle::Tombstoned
    );
    assert!(registry.terminal_snapshot().unwrap().terminals.is_empty());

    let lost_reply_retry =
        registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
    assert!(lost_reply_retry.replayed);
    assert_eq!(lost_reply_retry.revision, 2);

    let second_close = registry
        .close_terminal(
            &WorkspaceMutation::new("close-2", "tui").unwrap(),
            None,
            Some(2),
            TERMINAL_ONE,
            None,
        )
        .unwrap();
    assert_eq!(second_close.revision, 2);
    assert_eq!(second_close.result["already_closed"], true);
    assert_eq!(registry.terminal_events_after(0).unwrap().len(), 2);

    assert!(
        registry
            .commit_terminal(
                &WorkspaceMutation::new("reuse", "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(2),
                "terminal-added",
                &terminal,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap_err()
            .to_string()
            .contains("tombstoned terminal id cannot be reused")
    );
}

#[test]
fn closing_workspace_atomically_tombstones_all_child_terminals() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    for (index, id) in [TERMINAL_ONE, TERMINAL_TWO].into_iter().enumerate() {
        let revision = u64::try_from(index).unwrap();
        registry
            .commit_terminal(
                &WorkspaceMutation::new(format!("reserve-{}", index + 1), "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":id}),
                None,
                Some(revision),
                "terminal-added",
                &terminal(id, "one"),
                &json!({"terminal_id":id}),
            )
            .unwrap();
    }
    registry
        .commit(
            &WorkspaceMutation::new("close-workspace", "browser").unwrap(),
            &json!({"op":"close-workspace","workspace_key":"one"}),
            None,
            Some(1),
            "workspace-closed",
            "one",
            &[],
            &json!({"workspace_key":"one"}),
        )
        .unwrap();

    assert!(registry.snapshot().unwrap().workspaces.is_empty());
    let terminals = registry.terminal_snapshot().unwrap();
    assert_eq!(terminals.revision, 4);
    assert!(terminals.terminals.is_empty());
    for id in [TERMINAL_ONE, TERMINAL_TWO] {
        assert_eq!(
            registry.terminal_record(id).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Tombstoned
        );
    }
    let events = registry.terminal_events_after(2).unwrap();
    assert_eq!(events.len(), 2);
    assert!(events.iter().all(|event| event.result["reason"] == "workspace-closed"));
}

#[test]
fn terminal_reserve_after_workspace_close_fails_referentially() {
    let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
    seed_workspace(&mut registry, "one");
    registry
        .commit(
            &WorkspaceMutation::new("close", "browser").unwrap(),
            &json!({"op":"close-workspace"}),
            None,
            Some(1),
            "workspace-closed",
            "one",
            &[],
            &json!({"key":"one"}),
        )
        .unwrap();
    let error = registry
        .commit_terminal(
            &WorkspaceMutation::new("late-reserve", "browser").unwrap(),
            &json!({"op":"create-terminal","terminal_id":TERMINAL_ONE}),
            None,
            Some(0),
            "terminal-reserved",
            &terminal(TERMINAL_ONE, "one"),
            &json!({"terminal_id":TERMINAL_ONE}),
        )
        .unwrap_err();
    assert!(error.to_string().contains("workspace is missing or closed"));
    assert!(registry.terminal_record(TERMINAL_ONE).unwrap().is_none());
    assert_eq!(registry.terminal_snapshot().unwrap().revision, 0);
}

#[test]
fn schema_six_securely_discards_legacy_sensitive_input_receipts() {
    let root = temp_root("schema-six-sensitive-receipts");
    let session_dir = root.join(session_storage_component("session"));
    let database = session_dir.join(WORKSPACE_REGISTRY_FILE);
    let sentinel = "legacy-password-sentinel-do-not-retain";
    let public_url = "https://example.test/public-browser-url";
    drop(WorkspaceRegistry::open(&root, "session").unwrap());

    {
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(&format!(
                "PRAGMA wal_autocheckpoint=0;
                 BEGIN IMMEDIATE;
                 UPDATE meta SET value = '6' WHERE key = 'schema_version';
                 DELETE FROM meta WHERE key = '{RESOURCE_EFFECT_PEPPER_META_KEY}';
                 INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(
                   'legacy-sensitive', 'terminal.input.write',
                   '{{\"fields\":{{\"text\":\"{sentinel}\"}}}}',
                   '{{\"terminal_id\":\"term_00000000000000000000000000000001\",\"fields\":{{\"text\":\"{sentinel}\"}}}}',
                   'pending', NULL, NULL
                 );
                 INSERT INTO resource_effect_receipts(
                   idempotency_key, operation, fingerprint, intent_json, state,
                   outcome_json, committed_revision
                 ) VALUES(
                   'legacy-navigation', 'browser.navigate',
                   '{{\"fields\":{{\"url\":\"{public_url}\"}}}}',
                   '{{\"browser_id\":\"browser_00000000000000000000000000000001\",\"fields\":{{\"url\":\"{public_url}\"}}}}',
                   'pending', NULL, NULL
                 );
                 COMMIT;"
            ))
            .unwrap();
    }
    fs::remove_file(root.join(RESOURCE_EFFECT_PEPPER_FILE)).unwrap();

    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    let sensitive: i64 = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_effect_receipts
             WHERE idempotency_key = 'legacy-sensitive'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let navigation: i64 = migrated
        .connection
        .query_row(
            "SELECT COUNT(*) FROM resource_effect_receipts
             WHERE idempotency_key = 'legacy-navigation'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(sensitive, 0);
    assert_eq!(navigation, 1);
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    assert_eq!(
        required_meta(&migrated.connection, RESOURCE_EFFECT_PEPPER_META_KEY).unwrap().len(),
        64
    );
    assert!(
        meta_value(&migrated.connection, RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY)
            .unwrap()
            .is_none()
    );
    drop(migrated);

    for entry in fs::read_dir(&session_dir).unwrap() {
        let path = entry.unwrap().path();
        if !path.is_file() {
            continue;
        }
        let bytes = fs::read(&path).unwrap();
        assert!(
            !bytes.windows(sentinel.len()).any(|window| window == sentinel.as_bytes()),
            "legacy sensitive receipt remained in {}",
            path.display()
        );
        if path.file_name().and_then(|name| name.to_str()) == Some("workspace-registry.sqlite3-wal")
        {
            assert!(bytes.is_empty(), "migration did not truncate the SQLite WAL");
        }
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_seven_resumes_interrupted_sensitive_receipt_cleanup() {
    let root = temp_root("schema-seven-resume-sensitive-cleanup");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    drop(WorkspaceRegistry::open(&root, "session").unwrap());
    Connection::open(&database)
        .unwrap()
        .execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1')",
            [RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY],
        )
        .unwrap();

    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    assert!(
        meta_value(&reopened.connection, RESOURCE_EFFECT_PEPPER_CLEANUP_META_KEY)
            .unwrap()
            .is_none()
    );
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_seven_migrates_latest_live_agent_and_tombstones_without_resurrection() {
    let root = temp_root("schema-seven-agent-projection");
    let database = root.join(session_storage_component("session")).join(WORKSPACE_REGISTRY_FILE);
    let terminal = terminal_resource(TERMINAL_ONE);
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "agent-migration-topology");
        let session = registry.session_id().clone();
        let agent = agent_resource(&terminal);
        for (key, state, source_session, expected_revision) in [
            ("agent-migration-old", "working", "old-session", 1_u64),
            ("agent-migration-new", "done", "new-session", 2_u64),
        ] {
            let fingerprint = json!({
                "terminal_id":terminal,
                "state":state,
                "source":"hook",
                "source_session":source_session,
            });
            let result = json!({
                "id":agent,
                "session_id":session,
                "terminal_id":terminal,
                "state":state,
                "source":"hook",
                "updated_at_ms":expected_revision.to_string(),
                "source_session":source_session,
            });
            let commit = registry
                .commit_agent_projection(
                    &WorkspaceMutation::new(key, "migration-test").unwrap(),
                    &fingerprint,
                    Some(expected_revision),
                    &terminal,
                    &result,
                    &json!([{
                        "kind":"upsert",
                        "sequence":0,
                        "resource":"agent",
                        "id":agent,
                        "value":result,
                    }]),
                )
                .unwrap();
            assert_eq!(commit.revision, expected_revision + 1);
        }
        assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
    }
    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DROP TRIGGER resource_agent_projection_terminal_tombstone;
             DROP TABLE resource_agent_projections;
             UPDATE meta SET value = '7' WHERE key = 'schema_version';",
        )
        .unwrap();

    let mut migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    assert_eq!(migrated.resource_agent_projection_count_for_test().unwrap(), 1);
    let agents = migrated.public_projections().unwrap().agents;
    assert_eq!(agents.len(), 1);
    assert_eq!(agents[0].terminal_id, terminal);
    assert_eq!(agents[0].state, "done");
    assert_eq!(agents[0].source, "hook");
    assert_eq!(agents[0].source_session.as_deref(), Some("new-session"));

    migrated
        .commit_resource_patch(
            &WorkspaceMutation::new("agent-migration-tombstone", "migration-test").unwrap(),
            "terminal.close",
            &json!({"terminal_id":terminal}),
            None,
            Some(3),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane_id(1),
                        screen_id: screen_id(1),
                        name: Some("Shell".into()),
                        active_tab: None,
                        creation_ordinal: 1,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab_id(1) },
                    ResourceChange::TombstoneTerminal {
                        public_id: terminal,
                        expected_incarnation: None,
                    },
                    ResourceChange::SetTabOrder { pane_id: pane_id(1), tab_ids: Vec::new() },
                ],
            },
            &json!({"closed":true}),
            &json!([{"kind":"delete","resource":"agent"}]),
        )
        .unwrap();
    assert_eq!(migrated.resource_agent_projection_count_for_test().unwrap(), 0);
    assert!(migrated.public_projections().unwrap().agents.is_empty());
    drop(migrated);

    // Re-running the v7 migration against stale historical reports must not
    // recreate state for a terminal that is already tombstoned.
    Connection::open(&database)
        .unwrap()
        .execute_batch(
            "DROP TRIGGER resource_agent_projection_terminal_tombstone;
             DROP TABLE resource_agent_projections;
             UPDATE meta SET value = '7' WHERE key = 'schema_version';",
        )
        .unwrap();
    let reopened = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(reopened.resource_agent_projection_count_for_test().unwrap(), 0);
    assert!(reopened.public_projections().unwrap().agents.is_empty());
    drop(reopened);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_four_backfills_safe_browser_restart_metadata() {
    let root = temp_root("schema-four-browser");
    let browser = browser_id(1);
    let session_dir = root.join(session_storage_component("session"));
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        commit_terminal_topology(&mut registry, "create");
        commit_browser_topology(
            &mut registry,
            "browser",
            RegistryBrowser {
                public_id: browser.clone(),
                url: "https://cmux.dev/migrate".into(),
                source: RegistryBrowserSource::External,
                launch: RegistryBrowserLaunch::Adopted,
                reconnect: RegistryBrowserReconnect::Recreate,
                status: RegistryBrowserStatus::Live,
                cols: 111,
                rows: 42,
            },
        );
    }
    {
        let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
        connection
            .execute_batch(
                "PRAGMA foreign_keys=OFF;
                 BEGIN IMMEDIATE;
                 ALTER TABLE resource_browsers RENAME TO resource_browsers_v5;
                 CREATE TABLE resource_browsers (
                   public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
                   url TEXT NOT NULL,
                   lifecycle TEXT NOT NULL CHECK(lifecycle IN ('running','tombstoned')),
                   created_revision INTEGER NOT NULL,
                   updated_revision INTEGER NOT NULL,
                   deleted_revision INTEGER,
                   CHECK (
                     (deleted_revision IS NULL AND lifecycle = 'running') OR
                     (deleted_revision IS NOT NULL AND lifecycle = 'tombstoned')
                   )
                 );
                 INSERT INTO resource_browsers(
                   public_id, url, lifecycle, created_revision, updated_revision, deleted_revision
                 )
                 SELECT public_id, url, lifecycle, created_revision, updated_revision,
                        deleted_revision
                 FROM resource_browsers_v5;
                 DROP TABLE resource_browsers_v5;
                 UPDATE meta SET value = '4' WHERE key = 'schema_version';
                 COMMIT;
                 PRAGMA foreign_keys=ON;",
            )
            .unwrap();
    }
    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    assert_eq!(
        migrated.resource_topology_snapshot().unwrap().browsers,
        vec![RegistryBrowser::recreate(browser, "https://cmux.dev/migrate".into(), 80, 24,)]
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_one_migrates_transactionally_to_terminal_registry() {
    let root = temp_root("schema-one");
    let session_dir = root.join(session_storage_component("session"));
    {
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        drop(registry);
        let connection = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
        connection
            .execute_batch(
                "DROP TABLE terminal_events;
                     DROP TABLE terminal_mutations;
                     DROP TABLE terminal_placements;
                     DELETE FROM meta WHERE key = 'terminal_revision';
                     UPDATE meta SET value = '1' WHERE key = 'schema_version';",
            )
            .unwrap();
    }
    let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
    assert_eq!(migrated.terminal_snapshot().unwrap().revision, 0);
    assert!(migrated.terminal_snapshot().unwrap().terminals.is_empty());
    assert_eq!(
        required_meta(&migrated.connection, "schema_version").unwrap(),
        SCHEMA_VERSION.to_string()
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn interrupted_transaction_and_newer_schema_fail_closed() {
    let root = temp_root("transaction");
    {
        let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let tx = registry.connection.transaction().unwrap();
        tx.execute("UPDATE meta SET value = '77' WHERE key = 'revision'", []).unwrap();
        drop(tx);
        assert_eq!(registry.snapshot().unwrap().revision, 0);
    }
    fs::remove_dir_all(&root).unwrap();

    let newer_root = temp_root("newer");
    drop(load_or_create_resource_effect_pepper(&newer_root).unwrap());
    let session_dir = newer_root.join(session_storage_component("session"));
    fs::create_dir_all(&session_dir).unwrap();
    let database = session_dir.join(WORKSPACE_REGISTRY_FILE);
    let db = Connection::open(&database).unwrap();
    db.execute_batch(
        "CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             INSERT INTO meta(key,value) VALUES('schema_version','999');",
    )
    .unwrap();
    drop(db);
    let error = WorkspaceRegistry::open(&newer_root, "session").unwrap_err();
    let schema = error.downcast_ref::<UnsupportedWorkspaceRegistrySchema>().unwrap();
    assert_eq!(schema.found(), 999);
    assert_eq!(schema.newest_supported(), SCHEMA_VERSION);
    assert_eq!(schema.database_path(), Some(database.as_path()));
    assert!(error.to_string().contains("unsupported workspace registry schema"));
    fs::remove_dir_all(newer_root).unwrap();
}

#[test]
fn newer_schema_is_reported_before_writer_lease_conflict() {
    let root = temp_root("newer-before-lease");
    let registry = WorkspaceRegistry::open(&root, "session").unwrap();
    registry
        .connection
        .execute(
            "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
            [(SCHEMA_VERSION + 1).to_string()],
        )
        .unwrap();

    let error = WorkspaceRegistry::open(&root, "session").unwrap_err();
    let schema = error.downcast_ref::<UnsupportedWorkspaceRegistrySchema>().unwrap();
    assert_eq!(schema.found(), SCHEMA_VERSION + 1);
    assert_eq!(schema.registry_id(), Some(registry.registry_id()));
    assert!(!error.to_string().contains("already owned"));

    drop(registry);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn schema_preflight_failures_defer_to_authoritative_open() {
    let root = temp_root("preflight-failure");
    fs::create_dir_all(&root).unwrap();
    let database = root.join(WORKSPACE_REGISTRY_FILE);
    fs::write(&database, b"not a sqlite database").unwrap();

    assert!(preflight_unsupported_schema(&database).is_none());

    fs::remove_dir_all(root).unwrap();
}
