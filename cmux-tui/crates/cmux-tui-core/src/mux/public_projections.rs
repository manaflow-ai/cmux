use anyhow::Context;

use super::*;
use crate::workspace_registry::RegistryPublicProjections;

#[derive(Debug)]
pub(super) struct RestoredPublicProjections {
    pub(super) default_colors: DefaultColors,
    pub(super) has_terminal_defaults: bool,
    pub(super) next_notification_id: u64,
    pub(super) agent_records: HashMap<TerminalPublicId, TerminalAgentRecord>,
    pub(super) agent_hook_fences: HashMap<TerminalPublicId, HookFence>,
    pub(super) terminal_notifications: HashMap<TerminalPublicId, SurfaceNotification>,
    pub(super) notification_ledger: VecDeque<ResourceNotification>,
    pub(super) notification_reads: HashMap<NotificationPublicId, BTreeSet<String>>,
}

/// Rebuild the in-memory notification ledger, agent records (with their
/// published hook session ids), and hook fences from durable projections.
pub(super) fn restore_public_projections(
    state: &State,
    projections: RegistryPublicProjections,
) -> anyhow::Result<RestoredPublicProjections> {
    let has_terminal_defaults = projections.terminal_defaults.is_some();
    let default_colors = projections.terminal_defaults.unwrap_or_default();
    let mut notification_ledger = VecDeque::with_capacity(projections.notifications.len());
    let mut terminal_notifications = HashMap::new();
    let mut notification_reads = HashMap::new();
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
            if surface.is_some() {
                terminal_notifications.insert(
                    terminal_id,
                    SurfaceNotification {
                        notification: numeric_id,
                        level,
                        unread: true,
                        source: notification.source,
                    },
                );
            }
        }
        if !notification.read_by.is_empty() {
            notification_reads.insert(
                notification.id.clone(),
                notification.read_by.into_iter().collect::<BTreeSet<String>>(),
            );
        }
        notification_ledger.push_back(ResourceNotification {
            id: notification.id,
            title: notification.title,
            subtitle: notification.subtitle,
            body: notification.body,
            level,
            terminal_id: notification.terminal_id,
            created_at_ms: notification.created_at_ms,
            source: notification.source,
            surface,
        });
    }
    let next_notification_id = u64::try_from(notification_ledger.len())
        .context("notification count exceeds uint64")?
        .saturating_add(1);

    let mut agent_records = HashMap::with_capacity(projections.agents.len());
    let mut agent_hook_fences = HashMap::new();
    for hook_state in projections.agent_hook_states {
        agent_hook_fences.insert(
            hook_state.terminal_id,
            HookFence {
                session_id: hook_state.agent_session_id,
                sequence: hook_state.applied_sequence,
                ended: hook_state.ended,
                ended_at_ms: hook_state.ended_at_ms,
            },
        );
    }
    for agent in projections.agents {
        let state = agent_state(&agent.state)?;
        let internal_marker = agent.source_session.as_deref().is_some_and(|value| {
            value.starts_with("cmux-hook-sequence:") || value.starts_with("cmux-hook-ended:")
        });
        if let Some(source_session) = agent.source_session.as_deref() {
            let marker = source_session.strip_prefix("cmux-hook-sequence:");
            let ended = source_session.strip_prefix("cmux-hook-ended:");
            if let Some(value) = marker.or(ended).and_then(|value| value.parse::<u64>().ok()) {
                // Marker-only projections predate durable hook state. Use the
                // marker sequence as their legacy generation token so a
                // session-less event continues the same lifecycle after a
                // restart without reusing a terminal-wide identity.
                agent_hook_fences.entry(agent.terminal_id.clone()).or_insert(HookFence {
                    session_id: legacy_hook_session_id(&agent.terminal_id, value),
                    sequence: value,
                    ended: ended.is_some(),
                    ended_at_ms: None,
                });
            }
        }
        if state == AgentState::Done && agent.source == "hook" {
            // Older projections predate the internal ended marker. Keep
            // their terminal fenced after restart so a late socket report
            // cannot resurrect the completed session. Sequence zero is the
            // one-release compatibility generation for records without a
            // marker.
            agent_hook_fences.entry(agent.terminal_id.clone()).or_insert(HookFence {
                session_id: legacy_hook_session_id(&agent.terminal_id, 0),
                sequence: 0,
                ended: true,
                ended_at_ms: None,
            });
            continue;
        }
        let previous = agent_records.insert(
            agent.terminal_id.clone(),
            TerminalAgentRecord {
                state,
                source: agent_source(&agent.source)?,
                session: (!internal_marker).then_some(agent.source_session).flatten(),
                agent: agent.agent,
                agent_session_id: agent.agent_session_id,
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
        agent_hook_fences,
        terminal_notifications,
        notification_ledger,
        notification_reads,
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
        "plugin" => Ok(AgentSource::Plugin),
        "detected" => Ok(AgentSource::Detected),
        "socket" => Ok(AgentSource::Socket),
        "hook" => Ok(AgentSource::Hook),
        other => anyhow::bail!("invalid durable agent source {other:?}"),
    }
}

#[cfg(test)]
mod tests;
