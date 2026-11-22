//! A creation whose effect ran but whose public commit failed for good.
//!
//! The workspace row and the terminal were committed before the projection
//! that publishes them. If that projection fails twice (and the run was not
//! interrupted), the created workspace and its terminal are live in memory
//! but never public. A workspace creation is rolled back (the staged
//! workspace closes, the terminal ends) and its failure is committed, so a
//! failed create leaves nothing half-created. Other creations (a tab, pane
//! or screen in an existing workspace) keep the indeterminate settlement.

use std::sync::PoisonError;

use super::*;

impl Mux {
    pub(super) fn settle_unpublished_creation(
        &self,
        recovery: &ResourceCreationRecovery,
        failure: Option<ResourceError>,
        projection_error: anyhow::Error,
    ) -> anyhow::Result<ResourceCreationSettlement> {
        if let Some(settlement) = self.persisted_creation_settlement(recovery)? {
            return Ok(settlement);
        }
        if recovery.interrupted {
            return Ok(ResourceCreationSettlement::Pending);
        }
        if recovery.intent.get("workspace_reservation").is_none() {
            self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
            return Ok(ResourceCreationSettlement::Indeterminate);
        }
        // The terminal ends first: if that fails (or the daemon stops here),
        // the receipt's evidence is a closed terminal, whose settlement
        // already rolls the workspace back. A rollback that fails leaves the
        // effect indeterminate, as before.
        let rolled_back = match recovery.intent["terminal_reservation"]["terminal_id"].as_str() {
            Some(terminal_id) => self.close_unpublished_terminal(terminal_id),
            None => Ok(()),
        }
        .and_then(|()| self.rollback_interrupted_workspace_creation(&recovery.intent));
        if let Err(error) = rolled_back {
            eprintln!("cmux-tui: a failed creation could not be rolled back: {error:#}");
            self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
            return Ok(ResourceCreationSettlement::Indeterminate);
        }
        let error = failure.unwrap_or_else(|| {
            ResourceError::operation_failed(
                &recovery.operation,
                "the created resources could not be committed",
                json!({
                    "correlation_key":recovery.correlation_key,
                    "attempt":recovery.attempt,
                    "error":projection_error.to_string(),
                }),
            )
        });
        match self.commit_resource_effect(
            &recovery.idempotency_key,
            &recovery.operation,
            &recovery.fingerprint,
            &ResourceEffectOutcome::Failure(error.clone()),
            None,
        ) {
            Ok(_) => Ok(ResourceCreationSettlement::NotApplied(error)),
            Err(_) => {
                self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                Ok(ResourceCreationSettlement::Indeterminate)
            }
        }
    }

    /// End a created terminal that was never published: tombstone its
    /// durable row, remove its runtime and views from memory, then signal
    /// its host. The creation fence is already held by the caller, so this
    /// does not go through `close_terminal_guarded` (which takes it).
    fn close_unpublished_terminal(&self, terminal_id: &str) -> anyhow::Result<()> {
        {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let commit = registry.close_terminal(
                &WorkspaceMutation::daemon_local("cmux-tui"),
                None,
                None,
                terminal_id,
                None,
            )?;
            // Subscribers saw the terminal's Launching and Running rows.
            self.emit_terminal_registry_changed(&registry, commit.revision);
        }
        let (runtime, removed) = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let runtime = state
                .terminal_catalog
                .values()
                .find(|surface| {
                    self.resource_terminal_host_identity(surface)
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                })
                .cloned();
            let removed = runtime
                .as_ref()
                .map(|runtime| remove_terminal_runtime_from_state(self, &mut state, runtime).0)
                .unwrap_or_default();
            (runtime, removed)
        };
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
        }
        match runtime {
            Some(runtime) => {
                self.purge_terminal_runtime_side_tables(&runtime);
                self.terminate_terminal_runtime(&runtime);
            }
            None => self.terminate_discovered_terminal_host(terminal_id, None),
        }
        Ok(())
    }
}
