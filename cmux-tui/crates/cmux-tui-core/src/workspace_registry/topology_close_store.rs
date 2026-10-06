//! One durable commit for a batch topology close.
//!
//! `close-tabs` and the container closes with `end_terminals` remove many
//! placements and end many terminals at once. Every durable side lands in
//! one SQLite transaction (one journal fsync): the resource tombstones, the
//! legacy workspace ledger when a workspace closes, the terminal host
//! tombstones, the mutation receipt, and the journal record.

use super::resource_store::{
    apply_resource_patch, apply_resource_patch_unrecorded, complete_terminal_close_patch,
    prune_resource_mutations, resource_patch_replay, validate_resource_patch,
};
use super::*;

#[derive(Debug, Clone)]
pub(crate) struct TopologyCloseCommit {
    pub resource: ResourcePatchCommit,
    /// The legacy workspace revision, when the close removed a workspace.
    pub workspace_revision: Option<u64>,
    pub terminal_batch: TerminalBatchClose,
}

impl WorkspaceRegistry {
    /// Commit a batch close. A replayed mutation returns its original result
    /// and writes nothing. Terminal identities and incarnations are checked
    /// before anything is written, and any failure rolls back the whole set.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_topology_close(
        &mut self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_workspace_revision: Option<u64>,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
        terminals: &[(String, Option<String>)],
        workspace_close: Option<&ResourceWorkspaceClose>,
        tab_groups: Option<&TabGroupState>,
        record_closed: bool,
    ) -> anyhow::Result<TopologyCloseCommit> {
        validate_identifier("resource operation", operation)?;
        validate_terminal_batch_close(mutation, terminals)?;
        validate_resource_patch(patch)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let deltas = &self.prune_stated_topology_deltas(deltas)?;
        let tx = self.connection.transaction()?;
        if let Some(resource) = resource_patch_replay(&tx, mutation, operation, &fingerprint)? {
            let terminal_batch =
                TerminalBatchClose { revision: transaction_terminal_revision(&tx)?, closed: 0 };
            return Ok(TopologyCloseCommit { resource, workspace_revision: None, terminal_batch });
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "workspace generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let (patch, deltas) = complete_terminal_close_patch(&tx, terminals, patch, deltas)?;
        let previous_revision = transaction_resource_revision(&tx)?;
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;

        let workspace_revision = match workspace_close {
            Some(close) => {
                if let Some(active) = close.active_workspace.as_ref() {
                    anyhow::ensure!(
                        close.remaining_workspaces.iter().any(|item| &item.public_id == active),
                        "active workspace is absent from the post-close registry: {active}"
                    );
                }
                let (revision, _) = commit_workspace_registry_in_transaction(
                    &tx,
                    mutation,
                    &fingerprint,
                    expected_workspace_revision,
                    "workspace-closed",
                    &close.workspace_key,
                    &close.remaining_workspaces,
                    &canonical_json(&close.legacy_result)?,
                )?;
                Some(revision)
            }
            None => None,
        };
        if let Some(tab_groups) = tab_groups {
            presentation_store::write_tab_group_state(&tx, tab_groups)?;
        }
        let terminal_batch =
            close_terminals_in_transaction(&tx, mutation, terminals, "topology-closed")?;
        // A session-end close (`close-reason-v1`) stays out of the closed history.
        let patch = if record_closed {
            apply_resource_patch(&tx, &patch, sqlite_revision)?
        } else {
            apply_resource_patch_unrecorded(&tx, &patch, sqlite_revision)?
        };
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.origin,
                mutation.id,
                operation,
                fingerprint,
                result_json,
                sqlite_revision,
            ],
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            operation,
            Some(&patch),
            result,
            &deltas,
        )?;
        prune_resource_mutations(&tx)?;
        tx.commit()?;
        self.record_public_fold(previous_revision, revision, &deltas, true);
        Ok(TopologyCloseCommit {
            resource: ResourcePatchCommit { revision, result: result.clone(), replayed: false },
            workspace_revision,
            terminal_batch,
        })
    }
}
