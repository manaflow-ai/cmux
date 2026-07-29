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
    TerminalPublicId::from_terminal_host_id(id).unwrap()
}

fn browser_id(value: u128) -> BrowserPublicId {
    BrowserPublicId::parse(format!("browser_{value:032x}")).unwrap()
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
                viewport: json!({"offset":0}),
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
            &WorkspaceMutation::new("same-key", "test").unwrap(),
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
            &WorkspaceMutation::new("same-key", "test").unwrap(),
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
    assert_ne!(after.generation, before.generation);
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
                        viewport: json!({"offset":0}),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: second_pane.clone(),
                        screen_id: screen.clone(),
                        name: Some("Docs".into()),
                        active_tab: Some(second_tab.clone()),
                        creation_ordinal: 2,
                    }),
                    ResourceChange::UpsertBrowser {
                        public_id: browser.clone(),
                        url: "https://cmux.dev".into(),
                    },
                    ResourceChange::UpsertTab(RegistryTab {
                        public_id: second_tab.clone(),
                        pane_id: second_pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Browser(browser.clone()),
                        name: Some("Docs".into()),
                        browser_url: Some("https://cmux.dev".into()),
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
                        public_id: screen.clone(),
                        workspace_id: workspace_public_id,
                        position: 0,
                        name: Some("Main".into()),
                        layout: RegistryLayoutNode::Leaf { pane: first_pane.clone() },
                        active_pane: first_pane,
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: json!({"offset":0}),
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
    assert_eq!(required_meta(&migrated.connection, "schema_version").unwrap(), "3");
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
    let session_dir = newer_root.join(session_storage_component("session"));
    fs::create_dir_all(&session_dir).unwrap();
    let db = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
    db.execute_batch(
        "CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             INSERT INTO meta(key,value) VALUES('schema_version','999');",
    )
    .unwrap();
    drop(db);
    assert!(
        WorkspaceRegistry::open(&newer_root, "session")
            .unwrap_err()
            .to_string()
            .contains("unsupported workspace registry schema")
    );
    fs::remove_dir_all(newer_root).unwrap();
}
