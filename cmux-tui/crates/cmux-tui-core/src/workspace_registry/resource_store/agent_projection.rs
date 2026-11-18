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
        let checked = check_agent_projection(mutation, fingerprint, terminal_id, result)?;
        let _writer = crate::diagnostics::CommitWriter::AgentReport.scope();
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let AgentProjectionApplied { commit, wrote, reported } = apply_agent_projection(
            &tx,
            &checked,
            mutation,
            expected_revision,
            terminal_id,
            result,
            deltas,
            hook_state,
            journal_sequence,
            notification,
        )?;
        if wrote {
            tx.commit()?;
        } else {
            drop(tx);
        }
        drop(db);
        if reported && notification.is_some() {
            // The notification's effect receipt committed here, on its
            // request thread, as its commit alone counts it.
            self.connection.write_path_stats().request_effect_committed();
        }
        Ok(commit)
    }
}

/// The input of one agent report after the checks that need no transaction
/// ([`check_agent_projection`]).
pub(crate) struct CheckedAgentProjection {
    socket_report: bool,
    fingerprint: String,
    result_json: String,
}

/// What [`apply_agent_projection`] did in its transaction.
pub(crate) struct AgentProjectionApplied {
    pub(crate) commit: ResourcePatchCommit,
    /// The transaction holds rows to commit. A replay with no hook sequence
    /// wrote none.
    pub(crate) wrote: bool,
    /// The report's own rows are in the transaction: `false` for a replay
    /// and for a socket report that repeats the stored value.
    pub(crate) reported: bool,
}

/// The checks of one agent report that read no stored row, and the canonical
/// forms its transaction stores.
pub(crate) fn check_agent_projection(
    mutation: &WorkspaceMutation,
    fingerprint: &Value,
    terminal_id: &TerminalPublicId,
    result: &Value,
) -> anyhow::Result<CheckedAgentProjection> {
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    anyhow::ensure!(
        result.get("terminal_id").and_then(Value::as_str) == Some(terminal_id.as_str()),
        "agent projection terminal does not match {terminal_id}"
    );
    let socket_report = fingerprint.get("source").and_then(Value::as_str) == Some("socket");
    let fingerprint = canonical_json(fingerprint)?;
    let result_json = canonical_json(result)?;
    Ok(CheckedAgentProjection { socket_report, fingerprint, result_json })
}

/// The rows of one agent report, written in `tx`. The caller commits `tx`
/// when the result says it wrote ([`AgentProjectionApplied::wrote`]).
///
/// `notification`: the outcome of the notification of the same hook. It is
/// applied after the report's checks and before its rows (its record is one
/// revision below the report's), when the result is not a replay. A report
/// that refuses leaves it not applied.
#[allow(clippy::too_many_arguments)]
pub(crate) fn apply_agent_projection(
    tx: &Transaction<'_>,
    checked: &CheckedAgentProjection,
    mutation: &WorkspaceMutation,
    expected_revision: Option<u64>,
    terminal_id: &TerminalPublicId,
    result: &Value,
    deltas: &Value,
    hook_state: Option<&AgentHookProjectionState>,
    journal_sequence: Option<u64>,
    notification: Option<&EffectCommitIntent>,
) -> anyhow::Result<AgentProjectionApplied> {
    const OPERATION: &str = "agent.report";
    if let Some(replayed) = resource_patch_replay(tx, mutation, OPERATION, &checked.fingerprint)? {
        if let Some(sequence) = journal_sequence {
            advance_agent_hook_apply_cursor_transaction(tx, sequence)?;
        }
        return Ok(AgentProjectionApplied {
            commit: replayed,
            wrote: journal_sequence.is_some(),
            reported: false,
        });
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
    let previous_revision = transaction_resource_revision(tx)?;
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
    if checked.socket_report && hook_state.is_none() && journal_sequence.is_none() {
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
                    tx,
                    mutation,
                    OPERATION,
                    &checked.fingerprint,
                    &stored_result_json,
                    i64::try_from(previous_revision)
                        .context("resource revision exceeds SQLite range")?,
                )?;
                prune_resource_mutations(tx)?;
                return Ok(AgentProjectionApplied {
                    commit: ResourcePatchCommit {
                        revision: previous_revision,
                        result: existing_value,
                        replayed: true,
                    },
                    wrote: true,
                    reported: false,
                });
            }
        }
    }
    let previous_revision = match notification {
        Some(notification) => notification.apply(tx)?.revision(),
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
        params![terminal_id.as_str(), checked.result_json, sqlite_revision],
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
        tx,
        mutation,
        OPERATION,
        &checked.fingerprint,
        &checked.result_json,
        sqlite_revision,
    )?;
    append_resource_journal_record(
        tx,
        revision,
        previous_revision,
        &mutation.origin,
        &mutation.id,
        OPERATION,
        None,
        result,
        deltas,
    )?;
    prune_resource_mutations(tx)?;
    if let Some(sequence) = journal_sequence {
        advance_agent_hook_apply_cursor_transaction(tx, sequence)?;
    }
    Ok(AgentProjectionApplied {
        commit: ResourcePatchCommit { revision, result: result.clone(), replayed: false },
        wrote: true,
        reported: true,
    })
}
