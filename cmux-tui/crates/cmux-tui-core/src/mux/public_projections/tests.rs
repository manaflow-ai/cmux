//! Unit tests for `public_projections`.

use super::*;
use crate::resource::{AgentPublicId, NotificationPublicId, TerminalPublicId};
#[cfg(unix)]
use crate::terminal_host_runtime::TerminalHostIdentity;
use crate::workspace_registry::{RegistryAgentProjection, RegistryNotificationProjection};

fn terminal_id(value: u8) -> TerminalPublicId {
    TerminalPublicId::parse(format!("term_{value:032x}")).unwrap()
}

fn empty_state() -> State {
    State {
        workspaces: Vec::new(),
        workspace_index_by_id: HashMap::new(),
        workspace_id_by_key: HashMap::new(),
        workspace_revision: 0,
        pane_revision: 0,
        resource_revision: 0,
        focus_sequence: 0,
        active_workspace: 0,
        panes: HashMap::new(),
        surfaces: HashMap::new(),
        terminal_catalog: HashMap::new(),
        terminal_catalog_by_runtime: HashMap::new(),
        terminal_catalog_by_host: HashMap::new(),
        split_screens: HashMap::new(),
        resource_indexes: PublicSlotIndexes::default(),
    }
}

#[cfg(unix)]
#[test]
fn zero_view_terminal_projections_restore_by_stable_content_identity() {
    let terminal = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
    let mux = Mux::new_for_test("projection-restore", SurfaceOptions::default());
    let runtime = Surface::exited_terminal_placeholder_with_terminal_public_id(
        77,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        TerminalHostIdentity { terminal_id: "host-1".into(), incarnation: "incarnation-1".into() },
        terminal.clone(),
    )
    .unwrap();
    let projections = RegistryPublicProjections {
        notifications: vec![RegistryNotificationProjection {
            id: NotificationPublicId::parse("notification_00000000000000000000000000000001")
                .unwrap(),
            title: "build".into(),
            subtitle: None,
            body: String::new(),
            level: "info".into(),
            terminal_id: Some(terminal.clone()),
            created_at_ms: 1,
            unread: true,
            read_by: vec![],
            source: NotificationSource::Cli,
        }],
        agents: vec![RegistryAgentProjection {
            id: AgentPublicId::parse("agent_00000000000000000000000000000001").unwrap(),
            terminal_id: terminal.clone(),
            state: "working".into(),
            source: "hook".into(),
            updated_at_ms: 1,
            source_session: None,
            agent: None,
            agent_session_id: None,
        }],
        agent_hook_states: Vec::new(),
        terminal_defaults: None,
        frontend_projections: Vec::new(),
    };
    let mut state = empty_state();
    state.terminal_catalog.insert(terminal.clone(), runtime.clone());
    state.terminal_catalog_by_runtime.insert(runtime.terminal_runtime_id().unwrap(), terminal);
    let restored = restore_public_projections(&state, projections).unwrap();
    let terminal = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
    assert_eq!(restored.agent_records.get(&terminal).unwrap().state, AgentState::Working);
    assert_eq!(restored.notification_ledger[0].terminal_id.as_ref(), Some(&terminal));
    assert_eq!(restored.notification_ledger[0].surface, Some(runtime.id));
    assert!(restored.terminal_notifications[&terminal].unread);
    mux.shutdown();
}

#[test]
fn unread_projection_without_terminal_identity_is_rejected() {
    let projections = RegistryPublicProjections {
        notifications: vec![RegistryNotificationProjection {
            id: NotificationPublicId::parse("notification_00000000000000000000000000000002")
                .unwrap(),
            title: "orphan".into(),
            subtitle: None,
            body: String::new(),
            level: "warning".into(),
            terminal_id: None,
            created_at_ms: 2,
            unread: true,
            read_by: vec![],
            source: NotificationSource::Cli,
        }],
        agents: Vec::new(),
        agent_hook_states: Vec::new(),
        terminal_defaults: None,
        frontend_projections: Vec::new(),
    };

    let error = restore_public_projections(&empty_state(), projections).unwrap_err();
    assert!(error.to_string().contains("omitted its terminal identity"));
}

#[test]
fn orphaned_unread_notification_restores_only_in_the_historical_ledger() {
    let terminal = TerminalPublicId::parse("term_00000000000000000000000000000003").unwrap();
    let projections = RegistryPublicProjections {
        notifications: vec![RegistryNotificationProjection {
            id: NotificationPublicId::parse("notification_00000000000000000000000000000003")
                .unwrap(),
            title: "finished".into(),
            subtitle: None,
            body: String::new(),
            level: "info".into(),
            terminal_id: Some(terminal.clone()),
            created_at_ms: 3,
            unread: true,
            read_by: vec![],
            source: NotificationSource::Cli,
        }],
        agents: Vec::new(),
        agent_hook_states: Vec::new(),
        terminal_defaults: None,
        frontend_projections: Vec::new(),
    };

    let restored = restore_public_projections(&empty_state(), projections).unwrap();
    assert_eq!(restored.notification_ledger.len(), 1);
    assert_eq!(restored.notification_ledger[0].terminal_id, Some(terminal));
    assert!(restored.terminal_notifications.is_empty());
}

#[test]
fn done_agent_records_are_not_restored_into_live_roster() {
    let terminal = terminal_id(9);
    let projections = RegistryPublicProjections {
        notifications: Vec::new(),
        agents: vec![RegistryAgentProjection {
            id: AgentPublicId::parse("agent_00000000000000000000000000000009").unwrap(),
            terminal_id: terminal.clone(),
            state: "done".into(),
            source: "hook".into(),
            updated_at_ms: 1,
            source_session: None,
            agent: None,
            agent_session_id: None,
        }],
        agent_hook_states: Vec::new(),
        terminal_defaults: None,
        frontend_projections: Vec::new(),
    };
    let restored = restore_public_projections(&empty_state(), projections).unwrap();
    assert!(restored.agent_records.is_empty());
    assert!(restored.agent_hook_fences[&terminal].ended);
}

#[test]
fn hook_marker_restores_watermark_without_exposing_session() {
    let terminal = terminal_id(10);
    let projections = RegistryPublicProjections {
        notifications: Vec::new(),
        agents: vec![RegistryAgentProjection {
            id: AgentPublicId::parse("agent_00000000000000000000000000000010").unwrap(),
            terminal_id: terminal.clone(),
            state: "working".into(),
            source: "hook".into(),
            updated_at_ms: 1,
            source_session: Some("cmux-hook-sequence:12".into()),
            agent: None,
            agent_session_id: None,
        }],
        agent_hook_states: Vec::new(),
        terminal_defaults: None,
        frontend_projections: Vec::new(),
    };
    let restored = restore_public_projections(&empty_state(), projections).unwrap();
    assert_eq!(restored.agent_hook_fences[&terminal].sequence, 12);
    assert_eq!(restored.agent_records[&terminal].session, None);
}

#[test]
fn socket_done_agent_restores_into_live_record_map() {
    let terminal = terminal_id(11);
    let projections = RegistryPublicProjections {
        notifications: Vec::new(),
        agents: vec![RegistryAgentProjection {
            id: AgentPublicId::parse("agent_00000000000000000000000000000011").unwrap(),
            terminal_id: terminal.clone(),
            state: "done".into(),
            source: "socket".into(),
            updated_at_ms: 3,
            source_session: Some("socket-session".into()),
            agent: None,
            agent_session_id: None,
        }],
        agent_hook_states: Vec::new(),
        terminal_defaults: None,
        frontend_projections: Vec::new(),
    };
    let restored = restore_public_projections(&empty_state(), projections).unwrap();
    let record = &restored.agent_records[&terminal];
    assert_eq!(record.state, AgentState::Done);
    assert_eq!(record.source, AgentSource::Socket);
    assert_eq!(record.session.as_deref(), Some("socket-session"));
    assert!(!restored.agent_hook_fences.contains_key(&terminal));
}
