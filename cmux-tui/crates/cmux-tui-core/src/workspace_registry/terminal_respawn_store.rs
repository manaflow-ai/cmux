//! The registry half of a terminal respawn (cx-6so.49 L2).
//!
//! A placed terminal whose shell was lost with its host gets a new shell
//! under the same terminal id. Two first-writer-safe transactions carry it:
//! 1. [`WorkspaceRegistry::begin_terminal_respawn`]: `exited` (a host-loss
//!    receipt of the expected incarnation) to `launching`, clearing the
//!    incarnation and the exit receipt, so the normal launch path may start
//!    a host for the id. A close (tombstone) or any newer end wins: the
//!    transition then does nothing.
//! 2. [`WorkspaceRegistry::commit_terminal_respawned`]: `launching` to
//!    `running` with the new incarnation, and one public `terminal.respawned`
//!    upsert, so clients that saw the exit see the terminal run again.
//!
//! Placements are never touched: the tabs, splits and pins that reference
//! the terminal keep it. A daemon that stops between the two steps leaves a
//! `launching` row without a host record, which the next start reconciles
//! as a missing host record (a host loss).
//!
//! Also the seed fallback: the replay of the latest journal checkpoint that
//! captured a terminal.

use std::io::Read;

use anyhow::Context;
use base64::Engine;
use rusqlite::{OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::session_journal::append_resource_journal_record;
use super::{
    TerminalLifecycle, WorkspaceMutation, WorkspaceRegistry, canonical_json, read_terminal,
    transaction_resource_revision, transaction_terminal_revision,
};
use crate::terminal_end::TerminalEnd;

const RESPAWN_ORIGIN: &str = "cmux-tui-runtime";

/// The previous screen of a terminal as one VT replay.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct TerminalReplay {
    pub cols: u16,
    pub rows: u16,
    pub bytes: Vec<u8>,
}

fn next_revision(revision: u64, what: &str) -> anyhow::Result<(u64, i64)> {
    let next = revision.checked_add(1).with_context(|| format!("{what} revision exhausted"))?;
    Ok((next, i64::try_from(next).with_context(|| format!("{what} revision exceeds SQLite"))?))
}

impl WorkspaceRegistry {
    /// Step 1: reopen an exited terminal for a new launch. Only a host-loss
    /// receipt of `old_incarnation` qualifies; returns the terminal revision,
    /// or `None` when the terminal was closed, relaunched or ended otherwise.
    pub(crate) fn begin_terminal_respawn(
        &mut self,
        terminal_id: &str,
        old_incarnation: &str,
    ) -> anyhow::Result<Option<u64>> {
        let tx = self.connection.transaction()?;
        let Some(terminal) = read_terminal(&tx, terminal_id)? else { return Ok(None) };
        if terminal.lifecycle != TerminalLifecycle::Exited
            || terminal.incarnation.as_deref() != Some(old_incarnation)
            || !matches!(
                TerminalEnd::from_receipt(terminal.exit.as_ref()),
                TerminalEnd::HostLost(_)
            )
        {
            return Ok(None);
        }
        let (revision, sqlite_revision) =
            next_revision(transaction_terminal_revision(&tx)?, "terminal")?;
        let mutation = WorkspaceMutation::local(RESPAWN_ORIGIN);
        let result = json!({
            "terminal_id": terminal_id,
            "workspace_key": &terminal.workspace_key,
            "previous_incarnation": old_incarnation,
            "state": TerminalLifecycle::Launching.as_str(),
        });
        let fingerprint =
            canonical_json(&json!({"op": "terminal-respawning", "terminal_id": terminal_id}))?;
        let result_json = canonical_json(&result)?;
        tx.execute(
            "UPDATE terminal_hosts
             SET lifecycle = 'launching', incarnation = NULL, exit_json = NULL,
                 updated_revision = ?1
             WHERE terminal_id = ?2",
            params![sqlite_revision, terminal_id],
        )?;
        record_terminal_event(
            &tx,
            (revision, sqlite_revision),
            "terminal-respawning",
            (terminal_id, &terminal.workspace_key),
            &mutation,
            (&fingerprint, &result_json),
        )?;
        tx.commit()?;
        Ok(Some(revision))
    }

    /// Step 2: the respawned host of `terminal_id` runs `incarnation`.
    /// `terminal_snapshot` is the public terminal value to publish (its `id`
    /// must be the terminal's public id). Returns the terminal and resource
    /// revisions, or `None` when a close won meanwhile.
    pub(crate) fn commit_terminal_respawned(
        &mut self,
        terminal_id: &str,
        incarnation: &str,
        terminal_snapshot: Value,
    ) -> anyhow::Result<Option<(u64, u64)>> {
        let tx = self.connection.transaction()?;
        let Some(terminal) = read_terminal(&tx, terminal_id)? else { return Ok(None) };
        if terminal.lifecycle != TerminalLifecycle::Launching || terminal.incarnation.is_some() {
            return Ok(None);
        }
        let public_id = tx
            .query_row(
                "SELECT public_id FROM resource_terminals
                 WHERE terminal_id = ?1 AND deleted_revision IS NULL",
                [terminal_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .with_context(|| format!("terminal {terminal_id} has no public resource id"))?;
        anyhow::ensure!(
            terminal_snapshot.get("id").and_then(Value::as_str) == Some(public_id.as_str()),
            "respawned terminal snapshot id does not match its durable identity"
        );
        let resource_revision = transaction_resource_revision(&tx)?;
        let (revision, sqlite_revision) =
            next_revision(transaction_terminal_revision(&tx)?, "terminal")?;
        let (next_resource, sqlite_resource) = next_revision(resource_revision, "resource")?;
        let mutation = WorkspaceMutation::local(RESPAWN_ORIGIN);
        let result = json!({
            "terminal_id": terminal_id,
            "workspace_key": &terminal.workspace_key,
            "incarnation": incarnation,
            "state": TerminalLifecycle::Running.as_str(),
        });
        let fingerprint = canonical_json(&json!({
            "op": "terminal-respawned", "terminal_id": terminal_id, "incarnation": incarnation,
        }))?;
        let result_json = canonical_json(&result)?;
        tx.execute(
            "UPDATE terminal_hosts
             SET lifecycle = 'running', incarnation = ?1, exit_json = NULL, updated_revision = ?2
             WHERE terminal_id = ?3",
            params![incarnation, sqlite_revision, terminal_id],
        )?;
        record_terminal_event(
            &tx,
            (revision, sqlite_revision),
            "terminal-respawned",
            (terminal_id, &terminal.workspace_key),
            &mutation,
            (&fingerprint, &result_json),
        )?;
        for table in ["resource_terminals", "resource_identities"] {
            tx.execute(
                &format!(
                    "UPDATE {table} SET updated_revision = ?1
                     WHERE public_id = ?2 AND deleted_revision IS NULL"
                ),
                params![sqlite_resource, &public_id],
            )?;
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [next_resource.to_string()],
        )?;
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, 'terminal-respawned', ?3, ?4, ?5)",
            params![&mutation.origin, &mutation.id, &fingerprint, &result_json, sqlite_resource],
        )?;
        let changes = json!([{
            "kind": "upsert",
            "sequence": 0,
            "resource": "terminal",
            "id": public_id,
            "value": terminal_snapshot,
        }]);
        append_resource_journal_record(
            &tx,
            next_resource,
            resource_revision,
            &mutation.origin,
            &mutation.id,
            "terminal.respawned",
            None,
            &result,
            &changes,
        )?;
        super::resource_store::prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok(Some((revision, next_resource)))
    }

    /// The replay of terminal `terminal_public_id` in the latest journal
    /// checkpoint that captured it, verified against its digest.
    pub(crate) fn latest_checkpoint_terminal_replay(
        &self,
        terminal_public_id: &str,
    ) -> anyhow::Result<Option<TerminalReplay>> {
        let mut statement = self.connection.prepare(
            "SELECT content_refs_json FROM journal_checkpoints
             ORDER BY source_sequence DESC, created_at_ms DESC, checkpoint_id DESC LIMIT 16",
        )?;
        let refs = statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        let content_id = refs.iter().find_map(|refs| {
            serde_json::from_str::<Vec<Value>>(refs).ok()?.into_iter().find_map(|reference| {
                if reference["terminal_id"].as_str() != Some(terminal_public_id) {
                    return None;
                }
                reference["content_id"].as_str().map(str::to_string)
            })
        });
        let Some(content_id) = content_id else { return Ok(None) };
        let row = self
            .connection
            .query_row(
                "SELECT codec, content, uncompressed_bytes, sha256
                 FROM journal_content_blobs WHERE content_id = ?1",
                [&content_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Vec<u8>>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Vec<u8>>(3)?,
                    ))
                },
            )
            .optional()?;
        let Some((codec, compressed, uncompressed_bytes, digest)) = row else { return Ok(None) };
        anyhow::ensure!(codec == "gzip", "checkpoint content codec {codec:?} is unsupported");
        let expected = usize::try_from(uncompressed_bytes).context("checkpoint content size")?;
        anyhow::ensure!(
            expected <= crate::surface::VT_REPLAY_MAX_BYTES.saturating_mul(2),
            "checkpoint terminal content is too large to seed"
        );
        let mut uncompressed = Vec::with_capacity(expected);
        flate2::read::GzDecoder::new(compressed.as_slice())
            .take(u64::try_from(expected)?.saturating_add(1))
            .read_to_end(&mut uncompressed)
            .context("decompress checkpoint terminal content")?;
        anyhow::ensure!(
            uncompressed.len() == expected
                && Sha256::digest(&uncompressed).as_slice() == digest.as_slice(),
            "checkpoint terminal content does not match its digest"
        );
        let replay: Value = serde_json::from_slice(&uncompressed)?;
        anyhow::ensure!(
            replay["format"].as_str() == Some("cmux.vt-replay.v1"),
            "checkpoint terminal content format is unsupported"
        );
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(replay["bytes_base64"].as_str().context("checkpoint replay has no bytes")?)
            .context("decode checkpoint replay bytes")?;
        let size = |field: &str| {
            replay[field].as_u64().and_then(|value| u16::try_from(value).ok()).unwrap_or(0)
        };
        Ok(Some(TerminalReplay { cols: size("cols"), rows: size("rows"), bytes }))
    }
}

/// One terminal timeline event: its revision, mutation receipt and row.
fn record_terminal_event(
    tx: &rusqlite::Transaction<'_>,
    (revision, sqlite_revision): (u64, i64),
    kind: &str,
    (terminal_id, workspace_key): (&str, &str),
    mutation: &WorkspaceMutation,
    (fingerprint, result_json): (&str, &str),
) -> anyhow::Result<()> {
    tx.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
        [revision.to_string()],
    )?;
    tx.execute(
        "INSERT INTO terminal_mutations(
           origin, mutation_id, fingerprint, result_json, committed_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5)",
        params![&mutation.origin, &mutation.id, fingerprint, result_json, sqlite_revision],
    )?;
    tx.execute(
        "INSERT INTO terminal_events(
           revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            sqlite_revision,
            kind,
            terminal_id,
            workspace_key,
            &mutation.origin,
            &mutation.id,
            result_json
        ],
    )?;
    Ok(())
}
