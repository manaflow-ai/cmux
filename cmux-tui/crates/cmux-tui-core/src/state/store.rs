//! Durable commit path of the cmux next state resources
//! (plans/cmux-next/state-ownership.md steps A and B).
//!
//! Every state mutation runs in one transaction that checks the idempotency
//! record first, then the revision precondition, then writes its rows,
//! advances the public resource revision, stores the replay record, and
//! appends one resource journal batch. Clients read the batch on
//! `session.events`: shared and personal state resources arrive as
//! `state_upsert` and `state_delete` changes, and workspace, screen, tab,
//! and browser rows arrive as ordinary upserts whose `extra` carries the new
//! fields. A personal change also advances `personal_revision` and appends
//! its `personal.*` journal fact, so the raw `personal-changed` readers stay
//! current.
//!
//! The tables here are additive and carry no foreign keys: an older binary
//! that opens the registry ignores them. Screen presentation and screen
//! groups live in `screen_store`'s tables (one storage for the raw screen
//! commands and the v2 operations).

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde_json::{Value, json};

use crate::workspace_registry::personal_store::personal_revision;
use crate::workspace_registry::resource_store::{prune_resource_mutations, resource_patch_replay};
use crate::workspace_registry::session_journal::append_resource_journal_record;
use crate::workspace_registry::{
    ResourcePatchCommit, WorkspaceMutation, WorkspaceRegistry, canonical_json,
    transaction_resource_revision, validate_identifier,
};

const SAVED_GROUPS_MIGRATED_META_KEY: &str = "personal_saved_tab_groups_v1";

pub(crate) fn create_state_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_state (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           ephemeral INTEGER NOT NULL DEFAULT 0 CHECK(ephemeral IN (0,1))
         );
         CREATE TABLE IF NOT EXISTS tab_state (
           tab_id TEXT PRIMARY KEY NOT NULL,
           zoom REAL,
           back_json TEXT,
           forward_json TEXT
         );
         CREATE TABLE IF NOT EXISTS workspace_status_entries (
           workspace_id TEXT NOT NULL,
           status_key TEXT NOT NULL,
           text TEXT NOT NULL,
           icon TEXT,
           color TEXT,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0),
           position INTEGER NOT NULL,
           PRIMARY KEY(workspace_id, status_key)
         );
         CREATE TABLE IF NOT EXISTS workspace_progress (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           value REAL,
           label TEXT,
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
         );
         CREATE TABLE IF NOT EXISTS workspace_log (
           workspace_id TEXT NOT NULL,
           sequence INTEGER NOT NULL,
           level TEXT NOT NULL,
           source TEXT,
           text TEXT NOT NULL,
           at_ms INTEGER NOT NULL CHECK(at_ms >= 0),
           PRIMARY KEY(workspace_id, sequence)
         );
         CREATE TABLE IF NOT EXISTS personal_saved_tab_groups (
           saved_id TEXT PRIMARY KEY NOT NULL,
           profile_id TEXT NOT NULL,
           name TEXT NOT NULL DEFAULT '',
           color TEXT NOT NULL,
           members_json TEXT NOT NULL,
           position INTEGER NOT NULL CHECK(position >= 0),
           updated_at_ms INTEGER NOT NULL CHECK(updated_at_ms >= 0)
         );",
    )?;
    super::closed_history_store::create_closed_history_schema(transaction)?;
    super::agent_folder::create_agent_folder_schema(transaction)?;
    super::window_record_store::create_window_record_schema(transaction)?;
    super::kept_tab_store::create_kept_tab_schema(transaction)?;
    super::home_store::create_home_schema(transaction)?;
    super::conversation_tabs_store::create_conversation_tabs_schema(transaction)?;
    super::frontend_browser_keys::create_frontend_browser_keys_schema(transaction)?;
    Ok(())
}

/// Whether this registry has the state tables yet. Migrations of older
/// registries append resource journal batches before the current schema
/// exists; those batches carry no state.
pub(crate) fn state_tables_ready(connection: &Connection) -> anyhow::Result<bool> {
    Ok(connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'state_pending_changes'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

/// One-time move of the shared saved tab groups into the personal table,
/// all in the `default` room. Idempotent: a `meta` flag records it, and the
/// shared rows are read only here.
pub(crate) fn migrate_saved_tab_groups_to_personal(connection: &Connection) -> anyhow::Result<()> {
    let tx = connection.unchecked_transaction()?;
    let migrated =
        tx.query_row("SELECT 1 FROM meta WHERE key = ?1", [SAVED_GROUPS_MIGRATED_META_KEY], |_| {
            Ok(())
        })
        .optional()?
        .is_some();
    if !migrated {
        tx.execute(
            "INSERT OR IGNORE INTO personal_saved_tab_groups(
               saved_id, profile_id, name, color, members_json, position, updated_at_ms
             )
             SELECT saved_id, ?1, name, color, members_json, position, updated_at_ms
             FROM saved_tab_groups",
            [crate::workspace_registry::personal_store::DEFAULT_PROFILE_ID],
        )?;
        tx.execute(
            "INSERT INTO meta(key, value) VALUES(?1, '1')",
            [SAVED_GROUPS_MIGRATED_META_KEY],
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// What one state mutation wrote: its result and its public changes.
pub(crate) struct StateChanges {
    pub(crate) result: Value,
    pub(crate) changes: Vec<Value>,
}

impl StateChanges {
    pub(crate) fn new(result: Value, changes: Vec<Value>) -> Self {
        Self { result, changes }
    }
}

/// The outcome of a committed or replayed state mutation.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct StateCommit {
    pub(crate) revision: u64,
    pub(crate) result: Value,
    pub(crate) replayed: bool,
    /// The new `personal_revision` when personal rows changed.
    pub(crate) personal_revision: Option<u64>,
}

impl From<ResourcePatchCommit> for StateCommit {
    fn from(commit: ResourcePatchCommit) -> Self {
        Self {
            revision: commit.revision,
            result: commit.result,
            replayed: commit.replayed,
            personal_revision: None,
        }
    }
}

/// An ordinary resource upsert. Sequences are assigned at commit.
pub(crate) fn resource_upsert(resource: &str, id: &str, value: Value) -> Value {
    json!({"kind": "upsert", "sequence": 0, "resource": resource, "id": id, "value": value})
}

pub(crate) fn state_upsert(resource: &str, id: &str, value: Value) -> Value {
    json!({"kind": "state_upsert", "sequence": 0, "resource": resource, "id": id, "value": value})
}

pub(crate) fn state_delete(resource: &str, id: &str) -> Value {
    json!({"kind": "state_delete", "sequence": 0, "resource": resource, "id": id})
}

/// Keep the last change for each `(kind family, resource, id)` and number
/// the batch. A later restatement of the same resource supersedes an earlier
/// one in the same batch.
pub(crate) fn finish_changes(changes: Vec<Value>) -> Vec<Value> {
    let key = |change: &Value| {
        let family = match change["kind"].as_str() {
            Some("upsert" | "delete") => "resource",
            _ => "state",
        };
        (
            family.to_string(),
            change["resource"].as_str().unwrap_or_default().to_string(),
            change["id"].as_str().unwrap_or_default().to_string(),
        )
    };
    let mut output: Vec<Value> = Vec::with_capacity(changes.len());
    for change in changes {
        let identity = key(&change);
        output.retain(|existing| key(existing) != identity);
        output.push(change);
    }
    for (sequence, change) in output.iter_mut().enumerate() {
        change["sequence"] = json!(sequence);
    }
    output
}

impl WorkspaceRegistry {
    /// Commit one state mutation. `apply` runs only when the idempotency key
    /// is new and the revision precondition holds; a replay returns the
    /// stored result without calling it.
    pub(crate) fn commit_state_mutation(
        &mut self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        apply: impl FnOnce(&Transaction<'_>) -> anyhow::Result<StateChanges>,
    ) -> anyhow::Result<StateCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        let fingerprint = canonical_json(fingerprint)?;
        let tx = self.connection.transaction()?;
        if let Some(replayed) = resource_patch_replay(&tx, mutation, operation, &fingerprint)? {
            return Ok(replayed.into());
        }
        let previous_revision = transaction_resource_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != previous_revision
        {
            anyhow::bail!(
                "resource revision conflict: expected {expected}, current {previous_revision}"
            );
        }
        let revision = previous_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("resource revision exceeds SQLite range")?;
        let personal_before = personal_revision(&tx)?;
        let StateChanges { result, changes } = apply(&tx)?;
        let changes = Value::Array(finish_changes(changes));
        // Personal mutations advance `personal_revision` and append their own
        // `personal.*` fact; the raw `personal-changed` event follows it.
        let personal_after = personal_revision(&tx)?;
        let personal_revision = (personal_after != personal_before).then_some(personal_after);
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
                canonical_json(&result)?,
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
            None,
            &result,
            &changes,
        )?;
        prune_resource_mutations(&tx)?;
        tx.commit()?;
        Ok(StateCommit { revision, result, replayed: false, personal_revision })
    }

    /// Run a read against the registry connection.
    pub(crate) fn read_state<T>(
        &self,
        read: impl FnOnce(&Connection) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        read(&self.connection)
    }
}

/// The state resources for a session snapshot's `extra.state`.
pub(crate) fn state_snapshot(connection: &Connection) -> anyhow::Result<Value> {
    Ok(json!({
        "tab_groups": super::tab_state_store::tab_group_snapshots(connection, None)?,
        "saved_tab_groups": super::tab_state_store::saved_tab_group_snapshots(connection, None)?,
        "workspace_groups": super::personal_state_store::workspace_group_snapshots(connection, None)?,
        "workspace_placements": super::personal_state_store::placement_snapshots(connection)?,
        "rooms": super::personal_state_store::room_snapshots(connection)?,
        "screen_groups": super::screen_state_store::screen_group_snapshots(connection, None)?,
        "closed": super::closed_history_store::closed_items(connection)?,
        "workspace_status": super::workspace_status_store::status_snapshots(connection)?,
        "window_records": super::window_record_store::record_snapshots(connection)?,
    }))
}

/// Write a workspace's shared identity (title, color, icon).
pub(crate) fn write_workspace_identity(
    transaction: &Transaction<'_>,
    workspace_key: &str,
    update: &crate::workspace_registry::WorkspacePresentationUpdate,
) -> anyhow::Result<()> {
    anyhow::ensure!(update.group.is_none(), "workspace groups are personal state");
    crate::workspace_registry::presentation_store::write_workspace_presentation(
        transaction,
        workspace_key,
        update,
    )
}

/// Mark a workspace ephemeral: the daemon closes it at its next start.
pub(crate) fn mark_workspace_ephemeral(
    transaction: &Transaction<'_>,
    workspace_id: &str,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO workspace_state(workspace_id, ephemeral) VALUES(?1, 1)
         ON CONFLICT(workspace_id) DO UPDATE SET ephemeral = 1",
        [workspace_id],
    )?;
    Ok(())
}

/// Live ephemeral workspaces, which the daemon closes at start.
pub(crate) fn ephemeral_workspaces(connection: &Connection) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT s.workspace_id FROM workspace_state AS s
         JOIN resource_workspaces AS rw ON rw.public_id = s.workspace_id
         WHERE s.ephemeral = 1 AND rw.deleted_revision IS NULL",
    )?;
    Ok(statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<Vec<_>, _>>()?)
}
