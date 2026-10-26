//! Child agents a terminal agent's hooks report (manaflow-ai/cmux#25563). Claude Code sends
//! `Stop` when the parent's turn ends, while background subagents it started may still run:
//! the task is not done until they end. A completed turn whose children still run holds its
//! "finished" notification, and the last child to end posts it under the turn's own key, so a
//! replay never posts it twice. Memory only, like presence (`agent_presence.rs`): a daemon
//! restart forgets running children, and a later turn's end notifies as before.

use super::*;

/// What one terminal's agent runs below its turn.
#[derive(Debug, Default)]
pub(super) struct HookChildren {
    /// The children that started and have not ended, by `agent_node_id`.
    running: std::collections::HashSet<String>,
    /// The completed turn waiting for them, if one is.
    held: Option<HeldFinish>,
}

/// A turn's "finished" notification, held until the agent's children end.
#[derive(Debug)]
struct HeldFinish {
    /// The completed turn's journal sequence: the notification's idempotency key.
    sequence: u64,
    title: String,
    body: String,
    level: NotificationLevel,
}

impl Mux {
    /// An `agent.child.*` hook: counts the child in or out, and posts the held finish once the
    /// last child ends. A child the hook does not name (no `agent_node_id`) cannot be matched
    /// with its end, so it is not counted.
    pub(super) fn apply_agent_child_hook(&self, ingress: &crate::JournalIngress) -> anyhow::Result<()> {
        let Some(terminal_id) = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())
        else {
            return Ok(());
        };
        let Some(child) = ingress
            .payload
            .get("normalized")
            .and_then(|value| value.get("agent_node_id"))
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
        else {
            return Ok(());
        };
        let held = {
            let mut children = self.agent_hook_children.lock().unwrap();
            if ingress.kind == "agent.child.spawned" {
                children.entry(terminal_id.clone()).or_default().running.insert(child.to_owned());
                return Ok(());
            }
            let Some(entry) = children.get_mut(&terminal_id) else { return Ok(()) };
            entry.running.remove(child);
            if !entry.running.is_empty() {
                return Ok(());
            }
            children.remove(&terminal_id).and_then(|entry| entry.held)
        };
        let Some(held) = held else { return Ok(()) };
        let Some(surface) = self.resource_surface_for_terminal(&terminal_id) else { return Ok(()) };
        self.create_durable_notification(
            &Actor::Daemon,
            &format!("agent-hook-notification-{}", held.sequence),
            held.title,
            None,
            held.body,
            held.level,
            Some(surface),
            NotificationSource::Agent,
        )
        .with_context(|| format!("held agent finish for sequence {}", held.sequence))?;
        Ok(())
    }

    /// A lifecycle hook of `terminal_id`'s agent passed its fence. A completed turn whose
    /// children still run is held and returns true (it posts nothing now); a new turn drops
    /// a held one (that turn's own end decides); a new or ended session forgets its children.
    pub(super) fn hold_agent_finish(
        &self,
        terminal_id: &TerminalPublicId,
        kind: &str,
        sequence: u64,
        notification: Option<&(String, String, NotificationLevel)>,
    ) -> bool {
        let mut children = self.agent_hook_children.lock().unwrap();
        match kind {
            "agent.session.started" | "agent.session.ended" => {
                children.remove(terminal_id);
                false
            }
            "agent.turn.started" => {
                if let Some(entry) = children.get_mut(terminal_id) {
                    entry.held = None;
                }
                false
            }
            "agent.turn.completed" => {
                let (Some(entry), Some((title, body, level))) =
                    (children.get_mut(terminal_id).filter(|e| !e.running.is_empty()), notification)
                else {
                    return false;
                };
                let (title, body, level) = (title.clone(), body.clone(), *level);
                entry.held = Some(HeldFinish { sequence, title, body, level });
                true
            }
            _ => false,
        }
    }
}
