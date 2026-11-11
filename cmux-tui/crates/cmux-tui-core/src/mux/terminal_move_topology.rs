//! Keeps the resource topology in step when `terminal.move` moves a
//! terminal's view between panes through the legacy projection path.

use super::*;

impl Mux {
    /// Commit the full public topology of `state` as one revision of
    /// `actor`, for a legacy path that changed the live tree while it already
    /// holds both writer locks (registry, then state).
    pub(super) fn commit_full_resource_projection_locked(
        &self,
        registry: &mut WorkspaceRegistry,
        state: &mut State,
        actor: &Actor,
        operation: &str,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        let mut projection =
            self.resource_effect_projection_locked(registry, state, serde_json::json!({}))?;
        persist_public_topology_result(operation, &mut projection.result, &projection.changes)?;
        // After the result took its public value from the full changes: the
        // journal gets only the upserts it does not already state.
        let pruned = registry.prune_stated_projection_deltas(&projection.changes)?;
        let commit = registry.commit_resource_patch(
            &mutation,
            operation,
            &serde_json::json!({"operation": operation, "mutation": mutation.id}),
            None,
            None,
            &projection.patch,
            &projection.result,
            pruned.as_ref().unwrap_or(&projection.changes),
        )?;
        if pruned.is_none() && projection.restates_all && !commit.replayed {
            registry.record_full_projection_fold(commit.revision, &projection.changes);
        }
        state.resource_revision = commit.revision;
        Ok(commit)
    }
}
