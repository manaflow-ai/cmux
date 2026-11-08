use anyhow::Context;
use rusqlite::{OptionalExtension, Transaction, params};
use serde::Deserialize;
use serde_json::{Value, json};

use super::resource_store::validate_resource_patch;
use super::{
    RegistryTerminal, ResourcePatch, TerminalLifecycle, WorkspaceMutation, WorkspaceRegistry,
    apply_resource_patch, canonical_json, read_terminal,
    session_journal::append_resource_journal_record, transaction_resource_revision,
    transaction_terminal_revision, validate_terminal_transition,
};
use crate::resource::WireDecimal;
use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DurableTerminalExitReceipt {
    outcome: TerminalExitOutcome,
    exited_at: WireDecimal,
    revision: WireDecimal,
}

pub(super) fn validate_terminal_exit_receipt(value: &Value) -> anyhow::Result<()> {
    let DurableTerminalExitReceipt { outcome, exited_at, revision } =
        serde_json::from_value(value.clone()).context("terminal exit receipt is invalid")?;
    let _validated_revision = revision.get();
    anyhow::ensure!(
        TerminalExit { outcome, exited_at_ms: exited_at.get() }.is_valid(),
        "terminal exit receipt outcome is invalid"
    );
    Ok(())
}

fn legacy_terminal_exit_reason(value: &Value) -> anyhow::Result<String> {
    let present =
        |key: &str| value.get(key).and_then(Value::as_str).filter(|value| !value.trim().is_empty());
    Ok(match (present("reason"), present("error")) {
        (Some(reason), Some(error)) if reason != error => format!("{reason}: {error}"),
        (Some(reason), _) => reason.to_string(),
        (None, Some(error)) => error.to_string(),
        (None, None) => format!("legacy-terminal-exit: {}", canonical_json(value)?),
    })
}

pub(super) fn migrate_legacy_terminal_exit_receipts(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    // Legacy rows recorded neither an exit timestamp nor a resource revision.
    // Anchor the converted receipt to the upgrade observation and current head.
    let resource_revision = super::meta_value(transaction, "resource_revision")?
        .map(|value| value.parse::<u64>().context("resource revision is invalid"))
        .transpose()?
        .unwrap_or(0);
    let terminals = {
        let mut statement = transaction.prepare(
            "SELECT terminal_id, exit_json
             FROM terminal_hosts
             WHERE lifecycle = 'exited'
                OR (lifecycle = 'tombstoned' AND exit_json IS NOT NULL)
             ORDER BY terminal_id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
        })?;
        rows.collect::<rusqlite::Result<Vec<_>>>()?
    };
    for (terminal_id, stored) in terminals {
        let legacy = stored
            .as_deref()
            .map(serde_json::from_str::<Value>)
            .transpose()
            .with_context(|| format!("terminal {terminal_id} exit metadata is invalid JSON"))?
            .unwrap_or(Value::Null);
        if validate_terminal_exit_receipt(&legacy).is_ok() {
            continue;
        }
        let observed = TerminalExit::unknown(legacy_terminal_exit_reason(&legacy)?);
        let receipt = json!({
            "outcome": observed.outcome,
            "exited_at": observed.exited_at_ms.to_string(),
            "revision": resource_revision.to_string(),
        });
        validate_terminal_exit_receipt(&receipt)?;
        transaction.execute(
            "UPDATE terminal_hosts SET exit_json = ?1 WHERE terminal_id = ?2",
            params![canonical_json(&receipt)?, terminal_id],
        )?;
    }
    Ok(())
}

impl WorkspaceRegistry {
    /// Latch one authoritative process exit into both registry timelines.
    ///
    /// Terminal placement state and the public session delta share one SQLite
    /// transaction. Re-observing the same incarnation is a no-op, so live
    /// delivery, sidecar recovery, and restart reconciliation produce exactly
    /// one durable session event.
    pub(crate) fn commit_terminal_exit(
        &mut self,
        terminal_id: &str,
        incarnation: Option<&str>,
        observed: &TerminalExit,
        mut terminal_snapshot: Value,
        topology: Option<(&ResourcePatch, &Value)>,
    ) -> anyhow::Result<(RegistryTerminal, u64, u64, bool)> {
        anyhow::ensure!(observed.is_valid(), "terminal exit outcome is invalid");
        if let Some((patch, changes)) = topology {
            validate_resource_patch(patch)?;
            anyhow::ensure!(
                changes.is_array(),
                "terminal exit topology changes must be a JSON array"
            );
        }
        let tx = self.connection.transaction()?;
        let mut terminal = read_terminal(&tx, terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("unknown terminal {terminal_id}"))?;
        let terminal_revision = transaction_terminal_revision(&tx)?;
        let resource_revision = transaction_resource_revision(&tx)?;

        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            tx.commit()?;
            return Ok((terminal, terminal_revision, resource_revision, true));
        }
        if terminal
            .incarnation
            .as_deref()
            .is_some_and(|stored| incarnation.is_some_and(|observed| observed != stored))
        {
            anyhow::bail!("terminal_incarnation_mismatch");
        }
        if terminal.lifecycle == TerminalLifecycle::Exited {
            let exit_revision = terminal
                .exit
                .as_ref()
                .and_then(|exit| exit.get("revision"))
                .and_then(Value::as_str)
                .and_then(|revision| revision.parse::<u64>().ok())
                .unwrap_or(resource_revision);
            tx.commit()?;
            return Ok((terminal, terminal_revision, exit_revision, true));
        }

        let next_terminal_revision = terminal_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let next_resource_revision = resource_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_terminal_revision = i64::try_from(next_terminal_revision)
            .context("terminal revision exceeds SQLite integer range")?;
        let sqlite_resource_revision = i64::try_from(next_resource_revision)
            .context("resource revision exceeds SQLite integer range")?;
        let public_id = tx
            .query_row(
                "SELECT public_id FROM resource_terminals
                 WHERE terminal_id = ?1 AND deleted_revision IS NULL",
                [terminal_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .ok_or_else(|| anyhow::anyhow!("terminal {terminal_id} has no public resource id"))?;

        let exit = json!({
            "outcome": &observed.outcome,
            "exited_at": observed.exited_at_ms.to_string(),
            "revision": next_resource_revision.to_string(),
        });
        terminal.lifecycle = TerminalLifecycle::Exited;
        if let Some(incarnation) = incarnation {
            terminal.incarnation = Some(incarnation.to_string());
        }
        terminal.exit = Some(exit.clone());
        let existing = read_terminal(&tx, terminal_id)?
            .ok_or_else(|| anyhow::anyhow!("terminal disappeared during exit commit"))?;
        validate_terminal_transition(Some(&existing), &terminal)?;

        let snapshot = terminal_snapshot
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("terminal exit event snapshot must be a JSON object"))?;
        anyhow::ensure!(
            snapshot.get("id").and_then(Value::as_str) == Some(public_id.as_str()),
            "terminal exit event snapshot id does not match durable identity"
        );
        snapshot.insert("running".to_string(), Value::Bool(false));
        snapshot.insert("lifecycle".to_string(), Value::String("exited".to_string()));
        snapshot.insert("exit".to_string(), exit.clone());
        let terminal_snapshot = Value::Object(snapshot.clone());
        let mut changes = vec![json!({
            "kind": "upsert",
            "sequence": 0,
            "resource": "terminal",
            "id": public_id,
            "value": terminal_snapshot,
        })];
        if let Some((_, topology_changes)) = topology {
            for change in topology_changes.as_array().expect("validated topology changes") {
                let mut change = change.as_object().cloned().ok_or_else(|| {
                    anyhow::anyhow!("terminal exit topology change is not an object")
                })?;
                change.insert("sequence".to_string(), Value::from(changes.len()));
                changes.push(Value::Object(change));
            }
        }
        let changes = Value::Array(changes);
        let mutation = WorkspaceMutation::local("cmux-tui-runtime");
        let fingerprint = json!({
            "op": "terminal-exited",
            "terminal_id": terminal_id,
            "incarnation": incarnation,
            "outcome": &observed.outcome,
            "exited_at": observed.exited_at_ms.to_string(),
        });
        let fingerprint_json = canonical_json(&fingerprint)?;
        let exit_json = canonical_json(&exit)?;
        let result = json!({
            "terminal_id": terminal_id,
            "workspace_key": &terminal.workspace_key,
            "incarnation": incarnation,
            "state": "exited",
            "exit": &exit,
        });
        let result_json = canonical_json(&result)?;

        if let Some((patch, _)) = topology {
            apply_resource_patch(&tx, patch, sqlite_resource_revision)?;
        }

        tx.execute(
            "UPDATE terminal_hosts
             SET incarnation = ?1, lifecycle = 'exited', exit_json = ?2,
                 updated_revision = ?3, deleted_revision = NULL
             WHERE terminal_id = ?4",
            params![
                terminal.incarnation.as_deref(),
                exit_json,
                sqlite_terminal_revision,
                terminal_id
            ],
        )?;
        tx.execute(
            "UPDATE resource_terminals SET updated_revision = ?1
             WHERE public_id = ?2 AND deleted_revision IS NULL",
            params![sqlite_resource_revision, &public_id],
        )?;
        tx.execute(
            "UPDATE resource_identities SET updated_revision = ?1
             WHERE public_id = ?2 AND deleted_revision IS NULL",
            params![sqlite_resource_revision, &public_id],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [next_terminal_revision.to_string()],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [next_resource_revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO terminal_mutations(
               origin, mutation_id, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                &mutation.origin,
                &mutation.id,
                &fingerprint_json,
                &result_json,
                sqlite_terminal_revision,
            ],
        )?;
        tx.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, 'terminal-exited', ?2, ?3, ?4, ?5, ?6)",
            params![
                sqlite_terminal_revision,
                terminal_id,
                &terminal.workspace_key,
                &mutation.origin,
                &mutation.id,
                &result_json,
            ],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, 'terminal-exited', ?3, ?4, ?5)",
            params![
                &mutation.origin,
                &mutation.id,
                &fingerprint_json,
                &result_json,
                sqlite_resource_revision,
            ],
        )?;
        append_resource_journal_record(
            &tx,
            next_resource_revision,
            resource_revision,
            &mutation.origin,
            &mutation.id,
            "terminal.exited",
            None,
            &result,
            &changes,
        )?;
        super::resource_store::prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok((terminal, next_terminal_revision, next_resource_revision, false))
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_exit_failure(&self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.connection.execute_batch(
                "CREATE TEMP TRIGGER cmux_test_fail_terminal_exit
                 BEFORE INSERT ON terminal_mutations
                 BEGIN SELECT RAISE(ABORT, 'forced terminal exit failure'); END;",
            )?;
        } else {
            self.connection.execute_batch("DROP TRIGGER IF EXISTS cmux_test_fail_terminal_exit")?;
        }
        Ok(())
    }
}
