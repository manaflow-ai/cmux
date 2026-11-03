//! A creation whose effect ran but whose public commit failed for good.
//!
//! The workspace row and the terminal were committed before the projection
//! that publishes them. If that projection fails twice (and the run was not
//! interrupted), the created workspace and its terminal are live in memory
//! but never public. A workspace creation is rolled back (the staged
//! workspace closes, the terminal ends) and its failure is committed, so a
//! failed create leaves nothing half-created. Other creations (a tab, pane
//! or screen in an existing workspace) keep the indeterminate settlement,
//! but their terminal ends and its views leave memory first.

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
            // A tab, pane or screen in an existing workspace keeps the
            // indeterminate settlement, but its terminal's views leave
            // memory first and subscribers get their removal: the store
            // never published them, and the mark below is a write that a
            // full disk refuses too (fuzz restore h1).
            if let Some(terminal_id) = recovery
                .intent
                .get("terminal_reservation")
                .and_then(|reservation| reservation.get("terminal_id"))
                .and_then(Value::as_str)
                && let Err(error) = self.close_unpublished_terminal(terminal_id)
            {
                eprintln!("cmux-tui: a failed creation's terminal could not be closed: {error:#}");
            }
            self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
            return Ok(ResourceCreationSettlement::Indeterminate);
        }
        // The terminal ends first: if that fails (or the daemon stops here),
        // the receipt's evidence is a closed terminal, whose settlement
        // already rolls the workspace back. Both leave memory even when the
        // store refuses their writes (a full disk), so no client keeps a
        // workspace or a tab the store never published (fuzz restore h1). A
        // rollback whose write fails leaves the effect indeterminate, as
        // before.
        let terminal_closed = match recovery
            .intent
            .get("terminal_reservation")
            .and_then(|reservation| reservation.get("terminal_id"))
            .and_then(Value::as_str)
        {
            Some(terminal_id) => self.close_unpublished_terminal(terminal_id),
            None => Ok(()),
        };
        let workspace_rolled_back = self.rollback_interrupted_workspace_creation(&recovery.intent);
        if let (Err(_), Err(error)) = (&terminal_closed, &workspace_rolled_back) {
            eprintln!("cmux-tui: a failed creation's workspace could not be closed: {error:#}");
        }
        let rolled_back = terminal_closed.and(workspace_rolled_back);
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
    /// its host. The runtime leaves memory and ends even when the store
    /// refuses the tombstone (a full disk); that error comes back after.
    /// The creation fence is already held by the caller, so this does not
    /// go through `close_terminal_guarded` (which takes it).
    pub(super) fn close_unpublished_terminal(&self, terminal_id: &str) -> anyhow::Result<()> {
        let tombstoned = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            registry
                .close_terminal(
                    &WorkspaceMutation::daemon_local("cmux-tui"),
                    None,
                    None,
                    terminal_id,
                    None,
                )
                .map(|commit| {
                    // Subscribers saw the terminal's Launching and Running rows.
                    self.emit_terminal_registry_changed(&registry, commit.revision);
                })
        };
        // Each view leaves the tree with its close delta (a tab or a pane),
        // so a subscriber drops what the creation showed it.
        let views = {
            let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            state
                .terminal_catalog
                .values()
                .find(|surface| {
                    self.resource_terminal_host_identity(surface)
                        .is_some_and(|identity| identity.terminal_id == terminal_id)
                })
                .map(|runtime| {
                    state
                        .surfaces
                        .iter()
                        .filter(|(_, view)| view.shares_terminal_runtime(runtime))
                        .map(|(id, _)| *id)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default()
        };
        let mut tree_changed = false;
        for view in views {
            tree_changed |= self.remove_surface_after_registry(view);
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
        tree_changed |= !removed.is_empty();
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
        }
        if tree_changed {
            // A client that skips a delta (the app at an unchanged
            // revision) resyncs to the tree without the views.
            self.emit(MuxEvent::TreeChanged);
        }
        match runtime {
            Some(runtime) => {
                self.purge_terminal_runtime_side_tables(&runtime);
                self.terminate_terminal_runtime(&runtime);
            }
            None => self.terminate_discovered_terminal_host(terminal_id, None),
        }
        tombstoned
    }
}
