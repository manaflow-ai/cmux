//! One projection commit for several created views (a creation group,
//! SPLIT BURST): the views' creations ran one after another under the
//! creation fence, and their panes reach the store and its subscribers in
//! one projection, one journal write and one public revision with changes.
//!
//! Each creation keeps its own receipt and revision: the first one's patch
//! carries every view's changes, and each later one commits an empty patch
//! right after it in the same transaction. A replay of any of them answers
//! its own created path; a client that waits for a later one's revision
//! has every pane by then. A failure of any part rolls back all of them,
//! and each creation settles as a failed lone commit does.

use super::*;
use crate::workspace_registry::EffectCommitReceipt;
use anyhow::Context as _;

/// One created view of a group commit.
pub(crate) struct CreatedViewCommit<'a> {
    pub(crate) idempotency_key: &'a str,
    pub(crate) operation: &'a str,
    pub(crate) fingerprint: &'a Value,
    pub(crate) result: &'a Value,
}

impl Mux {
    /// Commit `views` (at least one) as one projection, under the same
    /// registry -> state fence as [`Self::commit_resource_effect_projection`].
    /// Answers each view's commit, in order.
    #[track_caller]
    pub(crate) fn commit_created_views_projection(
        &self,
        views: &[CreatedViewCommit<'_>],
    ) -> anyhow::Result<Vec<ResourcePatchCommit>> {
        let (first, rest) = views.split_first().context("a group commit has no created view")?;
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let mut state = self.lock_state_pinned(&registry).unwrap_or_else(PoisonError::into_inner);
        crate::debug_spans::mark("projection.locked");
        let results = views.iter().map(|view| view.result).collect::<Vec<_>>();
        let mut projection = self.created_views_projection_locked(
            &registry,
            &mut state,
            &results,
            first.result.clone(),
        )?;
        crate::debug_spans::mark("projection.built");
        persist_public_topology_result(
            first.operation,
            &mut projection.result,
            &projection.changes,
        )?;
        let mut rest_results = Vec::with_capacity(rest.len());
        for view in rest {
            let mut result = view.result.clone();
            persist_public_topology_result(view.operation, &mut result, &projection.changes)?;
            rest_results.push(result);
        }
        #[cfg(test)]
        crate::walk_counters::projection_prepared(
            projection.patch.changes.len(),
            projection.changes.as_array().map_or(0, Vec::len),
        );
        #[cfg(test)]
        if let Some(hook) = self
            .resource_projection_before_commit
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .clone()
        {
            hook();
        }
        let mut intents = Vec::with_capacity(views.len());
        let mut finishes = Vec::with_capacity(views.len());
        let (intent, finish) = registry.prepare_effect_patch_intent(
            first.idempotency_key,
            first.operation,
            first.fingerprint,
            &projection.patch,
            &projection.result,
            &projection.changes,
            projection.restates_all,
        )?;
        intents.push(intent);
        finishes.push(finish);
        let (no_patch, no_changes) =
            (ResourcePatch { changes: Vec::new() }, Value::Array(Vec::new()));
        for (view, result) in rest.iter().zip(&rest_results) {
            let (intent, finish) = registry.prepare_effect_patch_intent(
                view.idempotency_key,
                view.operation,
                view.fingerprint,
                &no_patch,
                result,
                &no_changes,
                false,
            )?;
            intents.push(intent);
            finishes.push(finish);
        }
        drop(projection);
        drop(state);
        crate::debug_spans::mark("projection.intent_prepared");
        let commits = self
            .commit_effect_intents(&mut registry, intents, finishes)?
            .into_iter()
            .map(EffectCommitReceipt::into_patch_commit)
            .collect::<anyhow::Result<Vec<_>>>()?;
        crate::debug_spans::mark("projection.writer_committed");
        if let Some(last) = commits.last() {
            self.state.lock().unwrap_or_else(PoisonError::into_inner).resource_revision =
                last.revision;
        }
        drop(registry);
        self.publish_resource_event();
        self.publish_pending_terminal_directories();
        crate::debug_spans::mark("projection.published");
        Ok(commits)
    }
}
