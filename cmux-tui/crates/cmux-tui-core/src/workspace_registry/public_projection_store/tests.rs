use super::*;
use serde_json::json;

fn terminal_id(value: u128) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
}

fn notification_id(value: u128) -> NotificationPublicId {
    NotificationPublicId::parse(format!("notification_{value:032x}")).unwrap()
}

fn projection_id(value: u128) -> FrontendProjectionPublicId {
    FrontendProjectionPublicId::parse(format!("projection_{value:032x}")).unwrap()
}

fn seed_live_terminal(
    registry: &mut WorkspaceRegistry,
) -> (TerminalPublicId, PanePublicId, TabPublicId) {
    const HOST_ID: &str = "00000000000040008000000000000001";
    let workspace = RegistryWorkspace {
        id: 1,
        public_id: WorkspacePublicId::parse("ws_00000000000000000000000000000001").unwrap(),
        key: "workspace-one".into(),
        name: "One".into(),
        group_key: "public-projections".into(),
    };
    let screen = ScreenPublicId::parse("screen_00000000000000000000000000000001").unwrap();
    let pane = PanePublicId::parse("pane_00000000000000000000000000000001").unwrap();
    let tab = TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
    let terminal = terminal_id(1);
    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("seed-terminal", "test").unwrap(),
            "workspace.create",
            &json!({"fixture":"live-terminal"}),
            None,
            Some(0),
            &ResourcePatch {
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
                        name: None,
                        layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                        active_pane: pane.clone(),
                        zoomed_pane: None,
                        auto_layout: None,
                        viewport: RegistryViewport::default(),
                    }),
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane.clone(),
                        screen_id: screen.clone(),
                        name: None,
                        active_tab: Some(tab.clone()),
                        creation_ordinal: 1,
                    }),
                    ResourceChange::UpsertTerminal {
                        public_id: terminal.clone(),
                        terminal: RegistryTerminal {
                            terminal_id: HOST_ID.into(),
                            workspace_key: workspace.key.clone(),
                            incarnation: None,
                            lifecycle: TerminalLifecycle::Launching,
                            launch_spec: json!({}),
                            exit: None,
                            on_exit: TerminalOnExit::Close,
                        },
                    },
                    ResourceChange::UpsertTab(RegistryTab {
                        name_source: Default::default(),
                        name_revision: 0,
                        public_id: tab.clone(),
                        pane_id: pane.clone(),
                        position: 0,
                        content_id: ContentPublicId::Terminal(terminal.clone()),
                        name: None,
                        browser_url: None,
                        terminal_id: Some(HOST_ID.into()),
                    }),
                    ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![workspace.public_id.clone()],
                    },
                    ResourceChange::SetScreenOrder {
                        workspace_id: workspace.public_id.clone(),
                        screen_ids: vec![screen],
                    },
                    ResourceChange::SetTabOrder {
                        pane_id: pane.clone(),
                        tab_ids: vec![tab.clone()],
                    },
                    ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
                ],
            },
            &json!({"created":true}),
            &json!([]),
        )
        .unwrap();
    (terminal, pane, tab)
}

fn insert_mutation(
    registry: &WorkspaceRegistry,
    key: &str,
    operation: &str,
    result: &Value,
    revision: i64,
) {
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO resource_mutations(
               idempotency_key, origin, operation, fingerprint, result_json,
               committed_revision
             ) VALUES(?1, 'test', ?2, '{}', ?3, ?4)",
            params![key, operation, canonical_json(result).unwrap(), revision],
        )
        .unwrap();
    if operation == "agent.report" {
        let terminal_id = result["terminal_id"].as_str().unwrap();
        registry
            .connection
            .get()
            .execute(
                "INSERT INTO resource_agent_projections(
                   terminal_id, result_json, committed_revision
                 )
                 SELECT ?1, ?2, ?3
                 WHERE EXISTS (
                   SELECT 1 FROM resource_terminals
                   WHERE public_id = ?1 AND deleted_revision IS NULL
                 )
                 ON CONFLICT(terminal_id) DO UPDATE SET
                   result_json = excluded.result_json,
                   committed_revision = excluded.committed_revision",
                params![terminal_id, canonical_json(result).unwrap(), revision,],
            )
            .unwrap();
    }
}

fn insert_notification(registry: &WorkspaceRegistry, key: &str, result: &Value, revision: i64) {
    let outcome = ResourceEffectOutcome::Success(result.clone());
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES(?1, 'notification.create', '{}', '{}', 'committed', ?2, ?3)",
            params![
                key,
                canonical_json(&serde_json::to_value(outcome).unwrap()).unwrap(),
                revision
            ],
        )
        .unwrap();
}

fn defaults(foreground: &str) -> Value {
    json!({
        "foreground":foreground,
        "background":null,
        "cursor":null,
        "selection_background":null,
        "selection_foreground":null,
        "cursor_style":"bar",
        "cursor_blink":true,
        "palette":{"0":"#010203","255":"#fdfefe"},
    })
}

#[test]
fn reconstructs_bounded_notifications_latest_agents_defaults_and_projections() {
    let mut registry = WorkspaceRegistry::in_memory("public-projections").unwrap();
    let session = registry.session_id().clone();
    for revision in 1..=260 {
        insert_notification(
            &registry,
            &format!("notification-{revision}"),
            &json!({
                "id":notification_id(revision),
                "session_id":session,
                "title":format!("title-{revision}"),
                "body":"",
                "level":"info",
                "created_at_ms":revision.to_string(),
                "unread":false,
            }),
            revision as i64,
        );
    }
    let terminal = terminal_id(1);
    let agent = agent_id(&terminal).unwrap();
    insert_mutation(
        &registry,
        "agent-old",
        "agent.report",
        &json!({
            "id":agent,
            "session_id":session,
            "terminal_id":terminal,
            "state":"working",
            "source":"hook",
            "updated_at_ms":"1",
            "source_session":null,
        }),
        261,
    );
    insert_mutation(
        &registry,
        "agent-new",
        "agent.report",
        &json!({
            "id":agent,
            "session_id":session,
            "terminal_id":terminal,
            "state":"done",
            "source":"hook",
            "updated_at_ms":"2",
            "source_session":"agent-session",
        }),
        262,
    );
    insert_mutation(
        &registry,
        "defaults-old",
        "session.terminal_defaults.update",
        &defaults("#111111"),
        263,
    );
    insert_mutation(
        &registry,
        "defaults-new",
        "session.terminal_defaults.update",
        &defaults("#abcdef"),
        264,
    );
    let projection = projection_id(1);
    registry
        .put_frontend_projection(
            &WorkspaceMutation::daemon("projection-one", "test").unwrap(),
            "resource-api",
            "session",
            projection.as_str(),
            RESOURCE_API_FRONTEND_PROJECTION_SCHEMA_VERSION,
            None,
            &json!({
                "frontend_id":"cmux-test",
                "window_id":"window-test",
                "generation":"launch-test",
                "projection":{"columns":[1,2]},
            }),
        )
        .unwrap();

    // This fixture has no terminal row, so notification links are cleared
    // and the historical agent mutations never form a valid projection.
    let restored = registry.public_projections().unwrap();
    assert_eq!(restored.notifications.len(), 256);
    assert_eq!(restored.notifications.first().unwrap().title, "title-5");
    assert_eq!(restored.notifications.last().unwrap().title, "title-260");
    assert!(restored.notifications.iter().all(|item| item.terminal_id.is_none()));
    assert!(restored.agents.is_empty());
    let defaults = restored.terminal_defaults.unwrap();
    assert_eq!(defaults.fg, Some(Rgb { r: 0xab, g: 0xcd, b: 0xef }));
    assert_eq!(defaults.cursor_style, Some(CursorShape::Bar));
    assert_eq!(defaults.palette[0], Some(Rgb { r: 1, g: 2, b: 3 }));
    assert_eq!(defaults.palette[255], Some(Rgb { r: 0xfd, g: 0xfe, b: 0xfe }));
    assert_eq!(restored.frontend_projections.len(), 1);
    assert_eq!(restored.frontend_projections[0].subject_key, projection.as_str());
    assert_eq!(restored.frontend_projections[0].projection["projection"], json!({"columns":[1,2]}));
}

#[test]
fn malformed_authoritative_rows_fail_closed() {
    let registry = WorkspaceRegistry::in_memory("malformed-public-projections").unwrap();
    insert_mutation(
        &registry,
        "bad-defaults",
        "session.terminal_defaults.update",
        &json!({
            "foreground":"red",
            "background":null,
            "cursor":null,
            "selection_background":null,
            "selection_foreground":null,
            "cursor_style":null,
            "cursor_blink":null,
            "palette":{},
        }),
        1,
    );
    let error = registry.public_projections().unwrap_err().to_string();
    assert!(error.contains("terminal color \"red\" must use #rrggbb"), "{error}");
}

#[test]
fn malformed_notification_outcome_fails_closed() {
    let registry = WorkspaceRegistry::in_memory("malformed-notification").unwrap();
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES('bad-notification', 'notification.create', '{}', '{}',
                      'committed', '{\"kind\":\"success\",\"value\":{\"id\":7}}', 1)",
            [],
        )
        .unwrap();
    let error = registry.public_projections().unwrap_err().to_string();
    assert!(error.contains("invalid committed notification result"), "{error}");
}

#[test]
fn agent_projections_survive_terminal_tombstones() {
    let mut registry = WorkspaceRegistry::in_memory("terminal-relationships").unwrap();
    let session = registry.session_id().clone();
    let (terminal, pane, tab) = seed_live_terminal(&mut registry);
    let agent = agent_id(&terminal).unwrap();
    insert_mutation(
        &registry,
        "agent-live",
        "agent.report",
        &json!({
            "id":agent,
            "session_id":session,
            "terminal_id":terminal,
            "state":"working",
            "source":"hook",
            "updated_at_ms":"10",
            "source_session":null,
        }),
        2,
    );
    insert_notification(
        &registry,
        "notification-live",
        &json!({
            "id":notification_id(1),
            "session_id":session,
            "title":"terminal",
            "body":"",
            "level":"warning",
            "terminal_id":terminal,
            "created_at_ms":"11",
            "unread":true,
        }),
        3,
    );

    let live = registry.public_projections().unwrap();
    assert_eq!(live.agents.len(), 1);
    assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
    assert_eq!(live.agents[0].terminal_id, terminal);
    assert_eq!(live.notifications[0].terminal_id, Some(terminal.clone()));
    assert!(live.notifications[0].unread);

    registry
        .commit_resource_patch(
            &WorkspaceMutation::daemon("tombstone-terminal", "test").unwrap(),
            "terminal.close",
            &json!({"terminal_id":terminal}),
            None,
            Some(1),
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane.clone(),
                        screen_id: ScreenPublicId::parse("screen_00000000000000000000000000000001")
                            .unwrap(),
                        name: None,
                        active_tab: None,
                        creation_ordinal: 1,
                    }),
                    ResourceChange::TombstoneTab { tab_id: tab, close_content: true },
                    ResourceChange::TombstoneTerminal {
                        public_id: terminal.clone(),
                        expected_incarnation: None,
                    },
                    ResourceChange::SetTabOrder { pane_id: pane, tab_ids: Vec::new() },
                ],
            },
            &json!({}),
            &json!([]),
        )
        .unwrap();

    let tombstoned = registry.public_projections().unwrap();
    assert_eq!(registry.resource_agent_projection_count_for_test().unwrap(), 1);
    assert_eq!(tombstoned.agents.len(), 1);
    assert_eq!(tombstoned.agents[0].terminal_id, terminal);
    assert_eq!(tombstoned.notifications.len(), 1);
    assert_eq!(tombstoned.notifications[0].terminal_id, None);
}
