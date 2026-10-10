//! Terminal record commits (`commit_terminal`: reserved, ready, adopting,
//! exited, tombstoned) as journal writer intents (PR5 of
//! plans/cmux-tui-journal-write-path.md).
//!
//! The request thread validates the record and renders its canonical JSON
//! while it holds the registry; the CAS on the terminal revision and every
//! write run inside the commit transaction (the writer's SAVEPOINT, or a
//! request-side transaction when the writer does not run).

use super::*;

/// One prepared `commit_terminal`.
#[derive(Debug)]
pub(crate) struct TerminalCommitIntent {
    mutation: WorkspaceMutation,
    /// Canonical fingerprint.
    fingerprint: String,
    expected_generation: Option<String>,
    /// The registry generation at prepare.
    generation: String,
    expected_revision: Option<u64>,
    event_kind: String,
    terminal: RegistryTerminal,
    result: Value,
    result_json: String,
    launch_spec_json: String,
    exit_json: Option<String>,
}

impl WorkspaceRegistry {
    /// Validate one terminal transition for [`Self::commit_terminal`].
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_terminal_commit(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        terminal: &RegistryTerminal,
        result: &Value,
    ) -> anyhow::Result<TerminalCommitIntent> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("terminal event kind", event_kind)?;
        validate_terminal(terminal)?;
        let launch_spec_json = canonical_json(&terminal.launch_spec)?;
        if launch_spec_json.len() > MAX_LAUNCH_SPEC_BYTES {
            anyhow::bail!("terminal launch spec exceeds {MAX_LAUNCH_SPEC_BYTES} bytes");
        }
        Ok(TerminalCommitIntent {
            mutation: mutation.clone(),
            fingerprint: canonical_json(fingerprint)?,
            expected_generation: expected_generation.map(str::to_string),
            generation: self.generation.clone(),
            expected_revision,
            event_kind: event_kind.to_string(),
            terminal: terminal.clone(),
            result: result.clone(),
            result_json: canonical_json(result)?,
            launch_spec_json,
            exit_json: terminal.exit.as_ref().map(canonical_json).transpose()?,
        })
    }
}

impl TerminalCommitIntent {
    /// Resident size for the writer's durable batch byte cap.
    pub(crate) fn estimated_bytes(&self) -> usize {
        self.fingerprint
            .len()
            .saturating_add(self.result_json.len().saturating_mul(2))
            .saturating_add(self.launch_spec_json.len().saturating_mul(2))
            .saturating_add(self.exit_json.as_ref().map_or(0, String::len))
            .saturating_add(1024)
    }

    /// The body of `commit_terminal` inside the caller's transaction.
    pub(super) fn apply(&self, tx: &Transaction<'_>) -> anyhow::Result<TerminalRegistryCommit> {
        let (mutation, terminal) = (&self.mutation, &self.terminal);
        if let Some(replay) = terminal_replay(tx, mutation, &self.fingerprint)? {
            return Ok(replay);
        }
        if let Some(expected) = self.expected_generation.as_deref()
            && expected != self.generation
        {
            anyhow::bail!(
                "terminal generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let current_revision = transaction_terminal_revision(tx)?;
        if let Some(expected) = self.expected_revision
            && expected != current_revision
        {
            anyhow::bail!(
                "terminal revision conflict: expected {expected}, current {current_revision}"
            );
        }
        let existing = read_terminal(tx, &terminal.terminal_id)?;
        if let Some(existing) = existing.as_ref()
            && existing.lifecycle == TerminalLifecycle::Exited
            && terminal.lifecycle == TerminalLifecycle::Exited
        {
            if existing.incarnation != terminal.incarnation {
                anyhow::bail!("terminal_incarnation_mismatch");
            }
            // Process exit is a latch: the first observed reason/status is
            // authoritative. Reader EOF, child wait, and reconnect failure can
            // race, but later observations neither rewrite metadata nor mint a
            // new durable revision/event.
            return Ok(TerminalRegistryCommit {
                revision: current_revision,
                result: self.result.clone(),
                replayed: true,
            });
        }
        validate_terminal_transition(existing.as_ref(), terminal)?;
        if terminal.lifecycle != TerminalLifecycle::Tombstoned
            && existing.as_ref().is_none_or(|stored| stored.workspace_key != terminal.workspace_key)
        {
            require_live_workspace(tx, &terminal.workspace_key)?;
        }

        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        tx.execute(
            "INSERT INTO terminal_hosts(
               terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
               exit_json, on_exit, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?8, ?9)
             ON CONFLICT(terminal_id) DO UPDATE SET
               workspace_key=excluded.workspace_key,
               incarnation=excluded.incarnation,
               lifecycle=excluded.lifecycle,
               launch_spec_json=excluded.launch_spec_json,
               exit_json=excluded.exit_json,
               on_exit=excluded.on_exit,
               updated_revision=excluded.updated_revision,
               deleted_revision=excluded.deleted_revision",
            params![
                terminal.terminal_id,
                terminal.workspace_key,
                terminal.incarnation,
                terminal.lifecycle.as_str(),
                self.launch_spec_json,
                self.exit_json,
                terminal.on_exit.as_str(),
                sqlite_revision,
                (terminal.lifecycle == TerminalLifecycle::Tombstoned).then_some(sqlite_revision),
            ],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [revision.to_string()],
        )?;
        let ledger = mutation_ledger::KeyedLedger::Terminal;
        let row = (self.fingerprint.as_str(), self.result_json.as_str(), sqlite_revision);
        mutation_ledger::insert_keyed_mutation(tx, ledger, mutation, row.0, row.1, row.2)?;
        tx.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                sqlite_revision,
                self.event_kind,
                terminal.terminal_id,
                terminal.workspace_key,
                mutation.origin,
                mutation.id,
                self.result_json,
            ],
        )?;
        Ok(TerminalRegistryCommit { revision, result: self.result.clone(), replayed: false })
    }
}
