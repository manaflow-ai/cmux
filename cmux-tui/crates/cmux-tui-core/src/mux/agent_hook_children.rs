//! Child agents a terminal agent's hooks report (manaflow-ai/cmux#25563). Claude Code sends
//! `Stop` when the parent's turn ends, while background subagents it started may still run:
//! the task is not done until they end. A completed turn whose children still run holds its
//! "finished" notification, and the last child to end posts it under the turn's own key, so a
//! replay never posts it twice.
//!
//! A child that never reports its end must not hold every later finish: one still running when
//! a turn completes outlived it (a background child); one that did not is a foreground child
//! of an interrupted turn, and the next turn's start drops it. A session that starts again or
//! ends posts what it held. Memory only, like presence (`agent_presence.rs`): a daemon restart
//! forgets running children and a held finish.

use super::*;

/// What one terminal's agent runs below its turn.
#[derive(Debug, Default)]
pub(super) struct HookChildren {
    /// Session start/end boundary: even an exact replay cannot cross it. Unlike the
    /// lifecycle fence, it does not advance on a turn's Stop.
    session_boundary: u64,
    /// The children that started and have not ended, by `agent_node_id`: true once one outlived
    /// the turn it started in.
    running: HashMap<String, bool>,
    /// The children that ended, so a start that arrives after its end (hooks run as separate
    /// processes) does not count one that will never end again.
    ended: HashSet<String>,
    /// The completed turn waiting for them, if one is.
    held: Option<HeldFinish>,
}

/// A turn's "finished" notification, held until the agent's children end.
#[derive(Debug, Clone)]
pub(super) struct HeldFinish {
    /// The completed turn's journal sequence: the notification's idempotency key.
    sequence: u64,
    title: String,
    body: String,
    level: NotificationLevel,
}

/// What a lifecycle hook does with the agent's "finished" notification.
pub(super) enum FinishGate {
    /// Post the hook's own notification, if it has one.
    Notify,
    /// A completed turn whose children run: post nothing now.
    Hold,
    /// The session started again or ended: post the finish it held.
    Release(HeldFinish),
}

impl Mux {
    /// An `agent.child.*` hook: counts the child in or out, and posts the held finish once the
    /// last child ends. A child the hook does not place in the agent's tree (no `agent_node_id`,
    /// or an `unknown` relation, such as Kiro's session start) is not counted.
    pub(super) fn apply_agent_child_hook(
        &self,
        ingress: &crate::JournalIngress,
        sequence: u64,
    ) -> anyhow::Result<()> {
        let Some(terminal_id) = ingress
            .subjects
            .iter()
            .find(|subject| subject.kind == "terminal")
            .and_then(|subject| TerminalPublicId::parse(&subject.id).ok())
        else {
            return Ok(());
        };
        let normalized = ingress.payload.get("normalized");
        let text = |field: &str| {
            normalized
                .and_then(|value| value.get(field))
                .and_then(Value::as_str)
                .filter(|text| !text.is_empty())
        };
        let Some(child) =
            text("agent_node_id").filter(|_| text("agent_relation") != Some("unknown"))
        else {
            return Ok(());
        };
        // Child hooks belong to the same session incarnation as lifecycle hooks. In
        // particular, an exact journal retry must not recreate a child after that session
        // ended. Hold this fence through posting as well, so a new turn cannot invalidate a
        // held finish while its last child is posting it. Child events never advance the
        // lifecycle sequence: a later child must not suppress an earlier Stop's retry.
        let fences = self.agent_hook_fences.lock().unwrap_or_else(|e| e.into_inner());
        let fence = fences.get(&terminal_id);
        // A replayed spawn cannot recreate a foreground child discarded by a newer turn.
        // Completions, however, still release a known child when a later Stop projected first.
        if ingress.kind == "agent.child.spawned"
            && fence.is_some_and(|fence| sequence <= fence.sequence)
        {
            return Ok(());
        }
        if !matches!(
            HookFence::session_transition(
                fence,
                terminal_id.as_str(),
                text("agent_session_id"),
                false,
                sequence,
                crate::journal_reducers::hook_observed_at_ms(&ingress.payload),
            ),
            JournalHookTransition::Apply(_)
        ) {
            return Ok(());
        }
        let held = {
            let mut children = self.agent_hook_children.lock().unwrap_or_else(|e| e.into_inner());
            let entry = children.entry(terminal_id.clone()).or_insert_with(|| HookChildren {
                session_boundary: fence.map_or(0, |fence| fence.sequence),
                ..HookChildren::default()
            });
            if sequence <= entry.session_boundary {
                return Ok(());
            }
            if ingress.kind == "agent.child.spawned" {
                if !entry.ended.contains(child) {
                    entry.running.entry(child.to_owned()).or_default();
                }
                return Ok(());
            }
            entry.ended.insert(child.to_owned());
            entry.running.remove(child);
            if !entry.running.is_empty() {
                return Ok(());
            }
            entry.held.clone()
        };
        let Some(held) = held else { return Ok(()) };
        self.post_held_agent_finish(&terminal_id, &held)?;
        // Taken only once it posted: a failed post retries this hook and finds it still held.
        let mut children = self.agent_hook_children.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = children.get_mut(&terminal_id)
            && entry.held.as_ref().is_some_and(|h| h.sequence == held.sequence)
        {
            entry.held = None;
        }
        Ok(())
    }

    /// A lifecycle hook of `terminal_id`'s agent passed its fence: whether its finish posts,
    /// waits for the agent's children, or a held one posts now.
    pub(super) fn gate_agent_finish(
        &self,
        terminal_id: &TerminalPublicId,
        kind: &str,
        sequence: u64,
        notification: Option<&(String, String, NotificationLevel)>,
    ) -> FinishGate {
        let mut children = self.agent_hook_children.lock().unwrap_or_else(|e| e.into_inner());
        match kind {
            "agent.session.started" | "agent.session.ended" => {
                if let Some(held) = children.get(terminal_id).and_then(|entry| entry.held.clone()) {
                    FinishGate::Release(held)
                } else {
                    children.insert(
                        terminal_id.clone(),
                        HookChildren { session_boundary: sequence, ..HookChildren::default() },
                    );
                    FinishGate::Notify
                }
            }
            "agent.turn.started" => {
                if let Some(entry) = children.get_mut(terminal_id) {
                    // This turn's own end decides; foreground children of the last one ended
                    // with it, whether or not their end came.
                    entry.held = None;
                    entry.running.retain(|_, background| *background);
                }
                FinishGate::Notify
            }
            "agent.turn.completed" => {
                let (Some(entry), Some((title, body, level))) =
                    (children.get_mut(terminal_id).filter(|e| !e.running.is_empty()), notification)
                else {
                    return FinishGate::Notify;
                };
                entry.running.values_mut().for_each(|background| *background = true);
                let (title, body, level) = (title.clone(), body.clone(), *level);
                entry.held = Some(HeldFinish { sequence, title, body, level });
                FinishGate::Hold
            }
            _ => FinishGate::Notify,
        }
    }

    /// Reset a session's child state only after its held finish posts. A failed
    /// post leaves the lifecycle hook retryable with the original finish key.
    pub(super) fn release_held_agent_session_finish(
        &self,
        terminal_id: &TerminalPublicId,
        held: &HeldFinish,
        sequence: u64,
    ) -> anyhow::Result<()> {
        self.post_held_agent_finish(terminal_id, held)?;
        let mut children = self.agent_hook_children.lock().unwrap_or_else(|e| e.into_inner());
        if children
            .get(terminal_id)
            .and_then(|entry| entry.held.as_ref())
            .is_some_and(|current| current.sequence == held.sequence)
        {
            children.insert(
                terminal_id.clone(),
                HookChildren { session_boundary: sequence, ..HookChildren::default() },
            );
        }
        Ok(())
    }

    /// Posts a held finish under its turn's key, so a replay never posts it twice.
    pub(super) fn post_held_agent_finish(
        &self,
        terminal_id: &TerminalPublicId,
        held: &HeldFinish,
    ) -> anyhow::Result<()> {
        let Some(surface) = self.resource_surface_for_terminal(terminal_id) else { return Ok(()) };
        self.create_durable_notification(
            &Actor::Daemon,
            &format!("agent-hook-notification-{}", held.sequence),
            held.title.clone(),
            None,
            held.body.clone(),
            held.level,
            Some(surface),
            NotificationSource::Agent,
        )
        .with_context(|| format!("held agent finish for sequence {}", held.sequence))?;
        Ok(())
    }
}
