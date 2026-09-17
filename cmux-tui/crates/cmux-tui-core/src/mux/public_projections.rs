use anyhow::Context;

use super::*;
use crate::workspace_registry::RegistryPublicProjections;

#[derive(Debug)]
pub(super) struct RestoredPublicProjections {
    pub(super) default_colors: DefaultColors,
    pub(super) has_terminal_defaults: bool,
    pub(super) next_notification_id: u64,
    pub(super) agent_records: HashMap<SurfaceId, AgentRecord>,
    pub(super) surface_notifications: HashMap<SurfaceId, SurfaceNotification>,
    pub(super) notification_ledger: VecDeque<ResourceNotification>,
}

pub(super) fn restore_public_projections(
    state: &State,
    projections: RegistryPublicProjections,
) -> anyhow::Result<RestoredPublicProjections> {
    let has_terminal_defaults = projections.terminal_defaults.is_some();
    let default_colors = projections.terminal_defaults.unwrap_or_default();
    let mut notification_ledger = VecDeque::with_capacity(projections.notifications.len());
    let mut surface_notifications = HashMap::new();
    for (index, notification) in projections.notifications.into_iter().enumerate() {
        let numeric_id =
            u64::try_from(index).context("notification count exceeds uint64")?.saturating_add(1);
        let surface = notification
            .terminal_id
            .as_ref()
            .map(|terminal_id| {
                state
                    .resource_indexes
                    .content
                    .get(&ContentPublicId::Terminal(terminal_id.clone()))
                    .copied()
                    .with_context(|| {
                        format!(
                            "durable notification {} references live terminal {} without a runtime slot",
                            notification.id, terminal_id
                        )
                    })
            })
            .transpose()?;
        let level = notification_level(&notification.level)?;
        if notification.unread
            && let Some(surface) = surface
        {
            surface_notifications.insert(
                surface,
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
        let surface = state
            .resource_indexes
            .content
            .get(&ContentPublicId::Terminal(agent.terminal_id.clone()))
            .copied()
            .with_context(|| {
                format!(
                    "durable agent {} references live terminal {} without a runtime slot",
                    agent.id, agent.terminal_id
                )
            })?;
        let previous = agent_records.insert(
            surface,
            AgentRecord {
                surface,
                state: agent_state(&agent.state)?,
                source: agent_source(&agent.source)?,
                session: agent.source_session,
                updated_at_ms: agent.updated_at_ms,
            },
        );
        anyhow::ensure!(
            previous.is_none(),
            "multiple durable agents resolve to runtime surface {surface}"
        );
    }

    Ok(RestoredPublicProjections {
        default_colors,
        has_terminal_defaults,
        next_notification_id,
        agent_records,
        surface_notifications,
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
    fn missing_runtime_slot_fails_closed() {
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
            split_screens: HashMap::new(),
            resource_indexes: PublicSlotIndexes::default(),
        };
        let error = restore_public_projections(&state, projections).unwrap_err().to_string();
        assert!(error.contains("without a runtime slot"), "{error}");
    }
}
