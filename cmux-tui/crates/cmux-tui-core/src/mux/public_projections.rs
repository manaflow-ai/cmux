use anyhow::Context;

use super::*;
use crate::workspace_registry::RegistryPublicProjections;

#[derive(Debug)]
pub(super) struct RestoredPublicProjections {
    pub(super) default_colors: DefaultColors,
    pub(super) has_terminal_defaults: bool,
    pub(super) next_notification_id: u64,
    pub(super) agent_records: HashMap<TerminalPublicId, TerminalAgentRecord>,
    pub(super) terminal_notifications: HashMap<TerminalPublicId, SurfaceNotification>,
    pub(super) notification_ledger: VecDeque<ResourceNotification>,
}

pub(super) fn restore_public_projections(
    state: &State,
    projections: RegistryPublicProjections,
) -> anyhow::Result<RestoredPublicProjections> {
    let has_terminal_defaults = projections.terminal_defaults.is_some();
    let default_colors = projections.terminal_defaults.unwrap_or_default();
    let mut notification_ledger = VecDeque::with_capacity(projections.notifications.len());
    let mut terminal_notifications = HashMap::new();
    for (index, notification) in projections.notifications.into_iter().enumerate() {
        let numeric_id =
            u64::try_from(index).context("notification count exceeds uint64")?.saturating_add(1);
        let surface = notification.terminal_id.as_ref().and_then(|terminal_id| {
            state
                .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
                .first()
                .copied()
                .or_else(|| state.terminal_catalog.get(terminal_id).map(|surface| surface.id))
        });
        let level = notification_level(&notification.level)?;
        if notification.unread {
            let terminal_id = notification
                .terminal_id
                .clone()
                .context("terminal notification omitted its terminal identity")?;
            terminal_notifications.insert(
                terminal_id,
                SurfaceNotification { notification: numeric_id, level, unread: true },
            );
        }
        notification_ledger.push_back(ResourceNotification {
            id: notification.id,
            title: notification.title,
            body: notification.body,
            level,
            terminal_id: notification.terminal_id,
            created_at_ms: notification.created_at_ms,
            surface,
        });
    }
    let next_notification_id = u64::try_from(notification_ledger.len())
        .context("notification count exceeds uint64")?
        .saturating_add(1);

    let mut agent_records = HashMap::with_capacity(projections.agents.len());
    for agent in projections.agents {
        let previous = agent_records.insert(
            agent.terminal_id.clone(),
            TerminalAgentRecord {
                state: agent_state(&agent.state)?,
                source: agent_source(&agent.source)?,
                session: agent.source_session,
                updated_at_ms: agent.updated_at_ms,
            },
        );
        anyhow::ensure!(
            previous.is_none(),
            "multiple durable agents resolve to terminal {}",
            agent.terminal_id
        );
    }

    Ok(RestoredPublicProjections {
        default_colors,
        has_terminal_defaults,
        next_notification_id,
        agent_records,
        terminal_notifications,
        notification_ledger,
    })
}

fn notification_level(value: &str) -> anyhow::Result<NotificationLevel> {
    match value {
        "info" => Ok(NotificationLevel::Info),
        "warning" => Ok(NotificationLevel::Warning),
        "error" => Ok(NotificationLevel::Error),
        other => anyhow::bail!("invalid durable notification level {other:?}"),
    }
}

fn agent_state(value: &str) -> anyhow::Result<AgentState> {
    match value {
        "working" => Ok(AgentState::Working),
        "blocked" => Ok(AgentState::Blocked),
        "idle" => Ok(AgentState::Idle),
        "done" => Ok(AgentState::Done),
        "unknown" => Ok(AgentState::Unknown),
        other => anyhow::bail!("invalid durable agent state {other:?}"),
    }
}

fn agent_source(value: &str) -> anyhow::Result<AgentSource> {
    match value {
        "detected" => Ok(AgentSource::Detected),
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("invalid durable agent source {other:?}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::resource::{AgentPublicId, NotificationPublicId, TerminalPublicId};
    use crate::workspace_registry::{RegistryAgentProjection, RegistryNotificationProjection};

    #[test]
    fn zero_view_terminal_projections_restore_by_stable_content_identity() {
        let terminal = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
        let projections = RegistryPublicProjections {
            notifications: vec![RegistryNotificationProjection {
                id: NotificationPublicId::parse("notification_00000000000000000000000000000001")
                    .unwrap(),
                title: "build".into(),
                body: String::new(),
                level: "info".into(),
                terminal_id: Some(terminal.clone()),
                created_at_ms: 1,
                unread: false,
            }],
            agents: vec![RegistryAgentProjection {
                id: AgentPublicId::parse("agent_00000000000000000000000000000001").unwrap(),
                terminal_id: terminal,
                state: "working".into(),
                source: "hook".into(),
                updated_at_ms: 1,
                source_session: None,
            }],
            terminal_defaults: None,
            frontend_projections: Vec::new(),
        };
        let state = State {
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
            split_screens: HashMap::new(),
            resource_indexes: PublicSlotIndexes::default(),
        };
        let restored = restore_public_projections(&state, projections).unwrap();
        let terminal = TerminalPublicId::parse("term_00000000000000000000000000000001").unwrap();
        assert_eq!(restored.agent_records.get(&terminal).unwrap().state, AgentState::Working);
        assert_eq!(restored.notification_ledger[0].terminal_id.as_ref(), Some(&terminal));
        assert_eq!(restored.notification_ledger[0].surface, None);
    }
}
