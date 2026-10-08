//! `close-terminal` through the resource topology owner: the host close,
//! its public resource tombstones, and the workspace it emptied, in one
//! SQLite transaction.

use super::*;

impl WorkspaceRegistry {
    /// Commit the legacy host close and its public resource tombstone in one
    /// SQLite transaction, with the workspace the close emptied
    /// (LAST-TAB-CLOSES-WORKSPACE). The mux installs the matching runtime projection
    /// only after this method returns successfully.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn close_terminal_with_resource_patch(
        &mut self,
        mutation: &WorkspaceMutation,
        expected_generation: Option<&str>,
        expected_terminal_revision: Option<u64>,
        expected_resource_revision: u64,
        terminal_id: &str,
        expected_incarnation: Option<&str>,
        patch: &ResourcePatch,
        resource_result: &Value,
        resource_deltas: &Value,
        workspace_close: Option<&ResourceWorkspaceClose>,
    ) -> anyhow::Result<TerminalResourceCloseCommit> {
        const OPERATION: &str = "terminal.close";

        validate_identifier("resource operation", OPERATION)?;
        resource_store::validate_resource_patch(patch)?;
        let fingerprint = terminal_close_fingerprint(mutation, terminal_id, expected_incarnation)?;
        let resource_result_json = canonical_json(resource_result)?;
        let resource_deltas = &self.prune_stated_topology_deltas(resource_deltas)?;
        let tx = self.connection.transaction()?;
        let terminal_batch = [(terminal_id.to_string(), expected_incarnation.map(str::to_string))];
        let (patch, resource_deltas) =
            complete_terminal_close_patch(&tx, &terminal_batch, patch, resource_deltas)?;
        if let Some(terminal) = terminal_replay(&tx, mutation, &fingerprint)? {
            tx.commit()?;
            return Ok(TerminalResourceCloseCommit::TerminalReplay(terminal));
        }
        if let Some(resource) =
            resource_store::resource_patch_replay(&tx, mutation, OPERATION, &fingerprint)?
        {
            let terminal =
                read_terminal(&tx, terminal_id)?.context("terminal close state is unavailable")?;
            anyhow::ensure!(
                terminal.lifecycle == TerminalLifecycle::Tombstoned,
                "terminal close state is unavailable"
            );
            let revision = transaction_terminal_revision(&tx)?;
            let result = serde_json::json!({
                "terminal_id": terminal_id,
                "incarnation": terminal.incarnation,
                "closed": true,
                "already_closed": true,
            });
            tx.commit()?;
            return Ok(TerminalResourceCloseCommit::ResourceReplay {
                terminal: TerminalRegistryCommit { revision, result, replayed: true },
                resource,
            });
        }
        let terminal = close_terminal_in_transaction(
            &tx,
            &self.generation,
            mutation,
            &fingerprint,
            expected_generation,
            expected_terminal_revision,
            terminal_id,
            expected_incarnation,
        )?;
        debug_assert!(!terminal.replayed);
        let workspace_revision = match workspace_close {
            Some(close) => Some(
                commit_workspace_registry_in_transaction(
                    &tx,
                    mutation,
                    &fingerprint,
                    None,
                    "workspace-closed",
                    &close.workspace_key,
                    &close.remaining_workspaces,
                    &canonical_json(&close.legacy_result)?,
                )?
                .0,
            ),
            None => None,
        };
        let previous_revision = transaction_resource_revision(&tx)?;
        anyhow::ensure!(
            previous_revision == expected_resource_revision,
            "resource revision conflict: expected {expected_resource_revision}, current {previous_revision}"
        );
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;
        let patch = apply_resource_patch(&tx, &patch, sqlite_revision)?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        insert_resource_mutation(
            &tx,
            mutation,
            OPERATION,
            &fingerprint,
            &resource_result_json,
            sqlite_revision,
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            OPERATION,
            Some(&patch),
            resource_result,
            &resource_deltas,
        )?;
        resource_store::prune_resource_mutations(&tx)?;
        let resource =
            ResourcePatchCommit { revision, result: resource_result.clone(), replayed: false };
        tx.commit()?;
        self.record_public_fold(previous_revision, revision, &resource_deltas, true);
        Ok(TerminalResourceCloseCommit::Committed { terminal, resource, workspace_revision })
    }
}
