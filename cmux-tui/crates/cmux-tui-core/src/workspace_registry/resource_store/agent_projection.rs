//! The commit of one agent report as its terminal's durable projection.

use super::*;

impl WorkspaceRegistry {
    #[cfg(test)]
    pub(crate) fn commit_agent_projection(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        terminal_id: &TerminalPublicId,
        result: &Value,
        deltas: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_agent_projection_with_hook_state(
            mutation,
            fingerprint,
            expected_revision,
            terminal_id,
            result,
            deltas,
            None,
            None,
            None,
        )
    }

    /// `notification`: the outcome of the notification of the same hook. It
    /// is applied in this transaction after the report's checks and before
    /// its rows (its record is one revision below the report's), when the
    /// result is not a replay. A report that refuses leaves it not applied.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_agent_projection_with_hook_state(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        terminal_id: &TerminalPublicId,
        result: &Value,
        deltas: &Value,
        hook_state: Option<&AgentHookProjectionState>,
        journal_sequence: Option<u64>,
        notification: Option<&EffectCommitIntent>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        const OPERATION: &str = "agent.report";
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        anyhow::ensure!(
            result.get("terminal_id").and_then(Value::as_str) == Some(terminal_id.as_str()),
            "agent projection terminal does not match {terminal_id}"
        );
        let socket_report = fingerprint.get("source").and_then(Value::as_str) == Some("socket");
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        if let Some(replayed) = resource_patch_replay(&tx, mutation, OPERATION, &fingerprint)? {
            if let Some(sequence) = journal_sequence {
                advance_agent_hook_apply_cursor_transaction(&tx, sequence)?;
                tx.commit()?;
            }
            return Ok(replayed);
        }
        let terminal_is_live = tx
            .query_row(
                "SELECT 1 FROM resource_terminals
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [terminal_id.as_str()],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        anyhow::ensure!(terminal_is_live, "unknown terminal {terminal_id}");
        let previous_revision = transaction_resource_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != previous_revision
        {
            anyhow::bail!(
                "resource revision conflict: expected {expected}, current {previous_revision}"
            );
        }
        // Socket reporters are observers, not a freshness clock. A second
        // client can report the same effective state while the first report
        // is still current. Record the new mutation key at the existing
        // revision, then return it as a replay-equivalent no-op so this path
        // does not churn resource events or roster recency. Hook and plugin
        // projections keep their timestamp semantics for arbitration.
        if socket_report && hook_state.is_none() && journal_sequence.is_none() {
            let existing = tx
                .query_row(
                    "SELECT result_json FROM resource_agent_projections
                     WHERE terminal_id = ?1",
                    [terminal_id.as_str()],
                    |row| row.get::<_, String>(0),
                )
                .optional()?;
            if let Some(existing_json) = existing {
                let existing_value: Value = serde_json::from_str(&existing_json)
                    .context("stored agent projection is not valid JSON")?;
                if same_agent_projection_ignoring_timestamp(&existing_value, result)? {
                    let stored_result_json = canonical_json(&existing_value)?;
                    insert_resource_mutation(
                        &tx,
                        mutation,
                        OPERATION,
                        &fingerprint,
                        &stored_result_json,
                        i64::try_from(previous_revision)
                            .context("resource revision exceeds SQLite range")?,
                    )?;
                    prune_resource_mutations(&tx)?;
                    tx.commit()?;
                    return Ok(ResourcePatchCommit {
                        revision: previous_revision,
                        result: existing_value,
                        replayed: true,
                    });
                }
            }
        }
        let previous_revision = match notification {
            Some(notification) => notification.apply(&tx)?.revision(),
            None => previous_revision,
        };
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;
        tx.execute(
            "INSERT INTO resource_agent_projections(
               terminal_id, result_json, committed_revision
             ) VALUES(?1, ?2, ?3)
             ON CONFLICT(terminal_id) DO UPDATE SET
               result_json = excluded.result_json,
               committed_revision = excluded.committed_revision",
            params![terminal_id.as_str(), result_json, sqlite_revision],
        )?;
        if let Some(hook_state) = hook_state {
            let applied_sequence = i64::try_from(hook_state.applied_sequence)
                .context("agent hook sequence exceeds SQLite range")?;
            let ended_at_ms = hook_state
                .ended_at_ms
                .map(i64::try_from)
                .transpose()
                .context("agent hook end time exceeds SQLite range")?;
            tx.execute(
                "INSERT INTO resource_agent_hook_state(
                   terminal_id, agent_session_id, applied_sequence, ended, committed_revision,
                   ended_at_ms
                 ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(terminal_id) DO UPDATE SET
                   agent_session_id = excluded.agent_session_id,
                   applied_sequence = excluded.applied_sequence,
                   ended = excluded.ended,
                   committed_revision = excluded.committed_revision,
                   ended_at_ms = excluded.ended_at_ms",
                params![
                    terminal_id.as_str(),
                    hook_state.agent_session_id,
                    applied_sequence,
                    hook_state.ended,
                    sqlite_revision,
                    ended_at_ms,
                ],
            )?;
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [revision.to_string()],
        )?;
        insert_resource_mutation(
            &tx,
            mutation,
            OPERATION,
            &fingerprint,
            &result_json,
            sqlite_revision,
        )?;
        append_resource_journal_record(
            &tx,
            revision,
            previous_revision,
            &mutation.origin,
            &mutation.id,
            OPERATION,
            None,
            result,
            deltas,
        )?;
        prune_resource_mutations(&tx)?;
        if let Some(sequence) = journal_sequence {
            advance_agent_hook_apply_cursor_transaction(&tx, sequence)?;
        }
        tx.commit()?;
        drop(db);
        if notification.is_some() {
            // The notification's effect receipt committed here, on its
            // request thread, as its commit alone counts it.
            self.connection.write_path_stats().request_effect_committed();
        }
        Ok(ResourcePatchCommit { revision, result: result.clone(), replayed: false })
    }
}
