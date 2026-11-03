//! Ordered hook projection, including durable records whose first caller has not projected.

use super::*;

impl Mux {
    pub(super) fn apply_agent_hook_record(
        &self,
        ingress: &crate::JournalIngress,
        sequence: u64,
    ) -> anyhow::Result<()> {
        if ingress.producer_id != crate::agent_hooks::AGENT_HOOK_PRODUCER_ID {
            return Ok(());
        }
        let Some(subject) = ingress.subjects.iter().find(|subject| subject.kind == "terminal")
        else {
            return Ok(());
        };
        let terminal_id = TerminalPublicId::parse(&subject.id)
            .with_context(|| format!("invalid terminal subject {:?}", subject.id))?;
        // The lifecycle fence alone cannot order side effects of an unprojected Stop:
        // a later prompt must first learn which children outlived that Stop. Serialize
        // catch-up with live projection; the inner projector never reacquires this lock.
        let _projection = self.agent_hook_projection.lock().unwrap_or_else(|e| e.into_inner());
        // Catch-up accounts for the earlier row's failure. The current receipt
        // only waits for it and must retain its own permanent-failure budget.
        self.reconcile_preceding_agent_hooks(&terminal_id, sequence).map_err(|error| {
            error.context(agent_hook_errors::AgentHookPrecedingProjectionPending)
        })?;
        self.project_agent_hook_record(ingress, sequence)
    }

    fn reconcile_preceding_agent_hooks(
        &self,
        terminal_id: &TerminalPublicId,
        sequence: u64,
    ) -> anyhow::Result<()> {
        // Every commit preseeds its retry row in the same transaction, including an
        // admitted append whose caller timed out. Process only earlier rows for this
        // terminal, in bounded pages; no scan of the session's journal history is needed.
        for _ in 0..crate::workspace_registry::AGENT_HOOK_MAX_RETRY_PAGES_PER_WAKE {
            let pending = self
                .workspace_registry
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .pending_agent_hook_projections_before(terminal_id, sequence)?;
            if pending.is_empty() {
                return Ok(());
            }
            for (producer, origin, key, earlier_sequence, ingress) in pending {
                if let Err(error) = self.project_agent_hook_record(&ingress, earlier_sequence)
                    && !agent_hook_terminal_gone(&error)
                {
                    self.workspace_registry
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .enqueue_agent_hook_pending(
                            &producer,
                            &origin,
                            &key,
                            earlier_sequence,
                            &ingress,
                            AgentHookPendingFailure {
                                error: AGENT_HOOK_RETRY_ERROR,
                                retry_class: agent_hook_retry_class(&error),
                            },
                        )?;
                    return Err(error);
                }
                self.workspace_registry
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .clear_agent_hook_pending(&producer, &origin, &key)?;
            }
        }
        anyhow::bail!("earlier hook projections exceeded the per-wake limit")
    }
}
