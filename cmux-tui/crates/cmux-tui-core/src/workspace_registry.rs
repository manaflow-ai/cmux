//! Durable, single-writer workspace registry.
//!
//! The mux owns one of these behind its workspace-commit mutex. A registry
//! transaction commits before the corresponding in-memory projection and
//! event are published, so durable order, reply order, and event order are the
//! same order. Runtime pane/surface ids deliberately never enter this store.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::Context;
use fs4::FileExt;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::platform;
use crate::resource::{
    BrowserPublicId, ContentPublicId, MachinePublicId, PanePublicId, ScreenPublicId,
    SessionPublicId, SplitPublicId, TabPublicId, TerminalPublicId, WorkspacePublicId,
};

mod effect_store;
mod public_projection_store;
mod resource_store;
mod terminal_exit_store;

pub use effect_store::{
    ResourceCreationPreparation, ResourceCreationRecovery, ResourceEffectOutcome,
    ResourceEffectPreparation,
};
use effect_store::{
    create_resource_effect_schema, prune_resource_events, recover_resource_effects,
};
pub use public_projection_store::{
    RegistryAgentProjection, RegistryNotificationProjection, RegistryPublicProjections,
};
pub(crate) use resource_store::validate_registry_screen_projection;
#[allow(unused_imports)]
pub use resource_store::{
    RegistryBrowser, RegistryBrowserLaunch, RegistryBrowserReconnect, RegistryBrowserSource,
    RegistryBrowserStatus, RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryTab,
    RegistryViewport, RegistryViewportColumn, ResourceChange, ResourceEventBatch,
    ResourceEventPage, ResourcePatch, ResourcePatchCommit, ResourceTopologySnapshot,
};
use resource_store::{
    create_resource_schema, migrate_resource_browser_metadata,
    migrate_resource_mutations_to_session_scope, validate_resource_invariants,
};

const SCHEMA_VERSION: i64 = 6;
const MAX_ID_LEN: usize = 128;
const MAX_WORKSPACE_KEY_LEN: usize = 256;
const MAX_PROJECTION_BYTES: usize = 1024 * 1024;
const MAX_LAUNCH_SPEC_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryWorkspace {
    pub id: u64,
    pub public_id: WorkspacePublicId,
    pub key: String,
    pub name: String,
    pub group_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistrySnapshot {
    pub registry_id: String,
    pub generation: String,
    pub revision: u64,
    pub resource_revision: u64,
    pub session_id: SessionPublicId,
    pub next_numeric_id: u64,
    pub workspaces: Vec<RegistryWorkspace>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceMutation {
    pub id: String,
    pub origin: String,
}

impl WorkspaceMutation {
    pub fn new(id: impl Into<String>, origin: impl Into<String>) -> anyhow::Result<Self> {
        let mutation = Self { id: id.into(), origin: origin.into() };
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        Ok(mutation)
    }

    pub fn local(origin: &str) -> Self {
        Self { id: new_uuid_v4(), origin: origin.to_string() }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegistryCommit {
    pub revision: u64,
    pub result: Value,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RegistryEvent {
    pub revision: u64,
    pub kind: String,
    pub workspace_key: String,
    pub origin: String,
    pub mutation_id: String,
    pub result: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalLifecycle {
    Launching,
    Adopting,
    Running,
    Exited,
    Tombstoned,
}

impl TerminalLifecycle {
    fn as_str(self) -> &'static str {
        match self {
            Self::Launching => "launching",
            Self::Adopting => "adopting",
            Self::Running => "running",
            Self::Exited => "exited",
            Self::Tombstoned => "tombstoned",
        }
    }

    fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "launching" => Ok(Self::Launching),
            "adopting" => Ok(Self::Adopting),
            "running" => Ok(Self::Running),
            "exited" => Ok(Self::Exited),
            "tombstoned" => Ok(Self::Tombstoned),
            other => anyhow::bail!("invalid terminal lifecycle {other:?}"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryTerminal {
    pub terminal_id: String,
    pub workspace_key: String,
    pub incarnation: Option<String>,
    pub lifecycle: TerminalLifecycle,
    pub launch_spec: Value,
    pub exit: Option<Value>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalRegistrySnapshot {
    pub registry_id: String,
    pub generation: String,
    pub revision: u64,
    pub terminals: Vec<RegistryTerminal>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalRegistryCommit {
    pub revision: u64,
    pub result: Value,
    pub replayed: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TerminalBatchClose {
    pub revision: u64,
    pub closed: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TerminalRegistryEvent {
    pub revision: u64,
    pub kind: String,
    pub terminal_id: String,
    pub workspace_key: String,
    pub origin: String,
    pub mutation_id: String,
    pub result: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FrontendProjection {
    pub frontend: String,
    pub scope: String,
    pub subject_key: String,
    pub schema_version: u32,
    pub projection_revision: u64,
    pub projection: Value,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProjectionCommit {
    pub projection: FrontendProjection,
    pub replayed: bool,
}

/// The sole durable writer for one session. The owning `Mux` serializes all
/// calls, and the OS lease prevents another daemon from opening the same
/// session concurrently.
pub struct WorkspaceRegistry {
    connection: Connection,
    registry_id: String,
    generation: String,
    session_name: String,
    machine_id: MachinePublicId,
    session_id: SessionPublicId,
    _lease: Option<SessionLease>,
}

impl std::fmt::Debug for WorkspaceRegistry {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("WorkspaceRegistry")
            .field("registry_id", &self.registry_id)
            .field("generation", &self.generation)
            .field("session_name", &self.session_name)
            .finish_non_exhaustive()
    }
}

impl WorkspaceRegistry {
    pub fn in_memory(session_name: &str) -> anyhow::Result<Self> {
        let connection = Connection::open_in_memory()?;
        Self::initialize(connection, session_name.to_string(), MachinePublicId::random()?, None)
    }

    pub fn open(root: &Path, session_name: &str) -> anyhow::Result<Self> {
        let machine_id = load_or_create_machine_id(root)?;
        let session_dir = root.join(session_storage_component(session_name));
        fs::create_dir_all(&session_dir).with_context(|| {
            format!("create workspace state directory {}", session_dir.display())
        })?;
        platform::restrict_directory(&session_dir)?;
        let lease = SessionLease::acquire(&session_dir.join("writer.lock"))?;
        let db_path = session_dir.join("workspace-registry.sqlite3");
        let connection = Connection::open(&db_path)
            .with_context(|| format!("open workspace registry {}", db_path.display()))?;
        platform::restrict_file(&db_path)?;
        Self::initialize(connection, session_name.to_string(), machine_id, Some(lease))
    }

    fn initialize(
        connection: Connection,
        session_name: String,
        machine_id: MachinePublicId,
        lease: Option<SessionLease>,
    ) -> anyhow::Result<Self> {
        connection.busy_timeout(std::time::Duration::from_secs(5))?;
        connection.execute_batch(
            "PRAGMA foreign_keys=ON;
             PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA fullfsync=ON;
             PRAGMA wal_autocheckpoint=1000;
             CREATE TABLE IF NOT EXISTS meta (
               key TEXT PRIMARY KEY NOT NULL,
               value TEXT NOT NULL
             );",
        )?;

        let stored_schema = meta_value(&connection, "schema_version")?;
        match stored_schema {
            Some(value) if value.parse::<i64>()? > SCHEMA_VERSION => {
                anyhow::bail!(
                    "unsupported workspace registry schema {value}; newest supported is {SCHEMA_VERSION}"
                );
            }
            Some(value) if value.parse::<i64>()? == SCHEMA_VERSION => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                tx.commit()?;
            }
            Some(value) if value.parse::<i64>()? == 5 => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(value) if value.parse::<i64>()? == 4 => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(value) if value.parse::<i64>()? == 3 => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                migrate_resource_mutations_to_session_scope(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(value) if matches!(value.parse::<i64>()?, 1 | 2) => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                migrate_resource_browser_metadata(&tx)?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('terminal_revision', '0')",
                    [],
                )?;
                tx.execute(
                    "INSERT OR IGNORE INTO meta(key, value) VALUES('resource_revision', '0')",
                    [],
                )?;
                ensure_session_public_id(&tx)?;
                backfill_workspace_public_ids(&tx)?;
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(value) => {
                anyhow::bail!(
                    "unsupported workspace registry schema {value}; expected 1, 2, 3, 4, 5, or {SCHEMA_VERSION}"
                );
            }
            None => {
                let tx = connection.unchecked_transaction()?;
                create_workspace_schema(&tx)?;
                create_terminal_schema(&tx)?;
                create_resource_schema(&tx)?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('schema_version', ?1)",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.execute("INSERT INTO meta(key, value) VALUES('revision', '0')", [])?;
                tx.execute("INSERT INTO meta(key, value) VALUES('terminal_revision', '0')", [])?;
                tx.execute("INSERT INTO meta(key, value) VALUES('resource_revision', '0')", [])?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('session_name', ?1)",
                    [&session_name],
                )?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('registry_id', ?1)",
                    [try_new_uuid_v4()?],
                )?;
                ensure_session_public_id(&tx)?;
                tx.commit()?;
            }
        }
        {
            let tx = connection.unchecked_transaction()?;
            create_resource_effect_schema(&tx)?;
            recover_resource_effects(&tx)?;
            tx.commit()?;
        }
        let stored_name = required_meta(&connection, "session_name")?;
        if stored_name != session_name {
            anyhow::bail!(
                "workspace registry belongs to session {stored_name:?}, not {session_name:?}"
            );
        }
        let registry_id = required_meta(&connection, "registry_id")?;
        validate_identifier("registry id", &registry_id)?;
        let session_id = SessionPublicId::parse(required_meta(&connection, "session_public_id")?)?;
        let quick_check: String =
            connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if quick_check != "ok" {
            anyhow::bail!("workspace registry integrity check failed: {quick_check}");
        }
        {
            let tx = connection.unchecked_transaction()?;
            validate_resource_invariants(&tx)?;
            tx.commit()?;
        }
        Ok(Self {
            connection,
            registry_id,
            generation: try_new_uuid_v4()?,
            session_name,
            machine_id,
            session_id,
            _lease: lease,
        })
    }

    pub fn snapshot(&self) -> anyhow::Result<RegistrySnapshot> {
        let revision = current_revision(&self.connection)?;
        let resource_revision = current_resource_revision(&self.connection)?;
        let max_numeric_id = self.connection.query_row(
            "SELECT COALESCE(MAX(numeric_id), 0) FROM workspaces",
            [],
            |row| row.get::<_, i64>(0),
        )?;
        let next_numeric_id = u64::try_from(max_numeric_id)
            .context("stored workspace id is negative")?
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("workspace id space exhausted"))?;
        let mut statement = self.connection.prepare(
            "SELECT w.numeric_id, w.workspace_key, w.name, w.group_key, rw.public_id
             FROM workspaces w
             JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
             WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL
             ORDER BY w.position ASC",
        )?;
        let workspaces = statement
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                Ok((id, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
            })?
            .map(|row| {
                let (id, key, name, group_key, public_id): (i64, String, String, String, String) =
                    row?;
                Ok::<RegistryWorkspace, anyhow::Error>(RegistryWorkspace {
                    id: u64::try_from(id).context("stored workspace id is negative")?,
                    public_id: WorkspacePublicId::parse(public_id)?,
                    key,
                    name,
                    group_key,
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        Ok(RegistrySnapshot {
            registry_id: self.registry_id.clone(),
            generation: self.generation.clone(),
            revision,
            resource_revision,
            session_id: self.session_id.clone(),
            next_numeric_id,
            workspaces,
        })
    }

    pub fn registry_id(&self) -> &str {
        &self.registry_id
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn session_id(&self) -> &SessionPublicId {
        &self.session_id
    }

    pub fn machine_id(&self) -> &MachinePublicId {
        &self.machine_id
    }

    /// Returns the canonical, non-tombstoned terminal placement projection.
    /// Runtime surface ids and renderer process ids are intentionally absent.
    pub fn terminal_snapshot(&self) -> anyhow::Result<TerminalRegistrySnapshot> {
        let revision = current_terminal_revision(&self.connection)?;
        let mut statement = self.connection.prepare(
            "SELECT terminal_id, workspace_key, incarnation, lifecycle,
                    launch_spec_json, exit_json
             FROM terminal_placements
             WHERE lifecycle != 'tombstoned'
             ORDER BY created_revision ASC, terminal_id ASC",
        )?;
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })?;
        let terminals =
            rows.map(|row| terminal_from_stored(row?)).collect::<anyhow::Result<Vec<_>>>()?;
        Ok(TerminalRegistrySnapshot {
            registry_id: self.registry_id.clone(),
            generation: self.generation.clone(),
            revision,
            terminals,
        })
    }

    /// Includes tombstones and is intended for reconciliation and idempotent
    /// close handling, not frontend materialization.
    pub fn terminal_record(&self, terminal_id: &str) -> anyhow::Result<Option<RegistryTerminal>> {
        validate_terminal_identity("terminal id", terminal_id)?;
        read_terminal(&self.connection, terminal_id)
    }

    pub fn replay_terminal(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<TerminalRegistryCommit>> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        terminal_replay(&self.connection, mutation, &fingerprint)
    }

    /// Commits one terminal state transition and its event in a single SQLite
    /// transaction. Callers reserve a stable id in `launching` before spawning
    /// a host, then advance it through `adopting`/`running` only after the host
    /// record is durable. A tombstoned id can never be resurrected.
    #[allow(clippy::too_many_arguments)]
    pub fn commit_terminal(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        terminal: &RegistryTerminal,
        result: &Value,
    ) -> anyhow::Result<TerminalRegistryCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("terminal event kind", event_kind)?;
        validate_terminal(terminal)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let launch_spec_json = canonical_json(&terminal.launch_spec)?;
        if launch_spec_json.len() > MAX_LAUNCH_SPEC_BYTES {
            anyhow::bail!("terminal launch spec exceeds {MAX_LAUNCH_SPEC_BYTES} bytes");
        }
        let exit_json = terminal.exit.as_ref().map(canonical_json).transpose()?;
        let tx = self.connection.transaction()?;

        if let Some(replay) = terminal_replay(&tx, mutation, &fingerprint)? {
            return Ok(replay);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "terminal generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let current_revision = transaction_terminal_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != current_revision
        {
            anyhow::bail!(
                "terminal revision conflict: expected {expected}, current {current_revision}"
            );
        }
        let existing = read_terminal(&tx, &terminal.terminal_id)?;
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
            tx.commit()?;
            return Ok(TerminalRegistryCommit {
                revision: current_revision,
                result: result.clone(),
                replayed: true,
            });
        }
        validate_terminal_transition(existing.as_ref(), terminal)?;
        if terminal.lifecycle != TerminalLifecycle::Tombstoned {
            require_live_workspace(&tx, &terminal.workspace_key)?;
        }

        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        tx.execute(
            "INSERT INTO terminal_placements(
               terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
               exit_json, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, ?8)
             ON CONFLICT(terminal_id) DO UPDATE SET
               workspace_key=excluded.workspace_key,
               incarnation=excluded.incarnation,
               lifecycle=excluded.lifecycle,
               launch_spec_json=excluded.launch_spec_json,
               exit_json=excluded.exit_json,
               updated_revision=excluded.updated_revision,
               deleted_revision=excluded.deleted_revision",
            params![
                terminal.terminal_id,
                terminal.workspace_key,
                terminal.incarnation,
                terminal.lifecycle.as_str(),
                launch_spec_json,
                exit_json,
                sqlite_revision,
                (terminal.lifecycle == TerminalLifecycle::Tombstoned).then_some(sqlite_revision),
            ],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO terminal_mutations(
               origin, mutation_id, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![mutation.origin, mutation.id, fingerprint, result_json, sqlite_revision],
        )?;
        tx.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                sqlite_revision,
                event_kind,
                terminal.terminal_id,
                terminal.workspace_key,
                mutation.origin,
                mutation.id,
                result_json,
            ],
        )?;
        tx.commit()?;
        Ok(TerminalRegistryCommit { revision, result: result.clone(), replayed: false })
    }

    /// Durably tombstones a terminal before the caller signals its host. This
    /// makes a repeated close safe even if the first success reply was lost.
    pub fn close_terminal(
        &mut self,
        mutation: &WorkspaceMutation,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        terminal_id: &str,
        expected_incarnation: Option<&str>,
    ) -> anyhow::Result<TerminalRegistryCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_terminal_identity("terminal id", terminal_id)?;
        if let Some(incarnation) = expected_incarnation {
            validate_terminal_identity("terminal incarnation", incarnation)?;
        }
        let fingerprint_value = serde_json::json!({
            "op": "close-terminal",
            "terminal_id": terminal_id,
            "incarnation": expected_incarnation,
        });
        let fingerprint = canonical_json(&fingerprint_value)?;
        let tx = self.connection.transaction()?;
        if let Some(replay) = terminal_replay(&tx, mutation, &fingerprint)? {
            return Ok(replay);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "terminal generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let current_revision = transaction_terminal_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != current_revision
        {
            anyhow::bail!(
                "terminal revision conflict: expected {expected}, current {current_revision}"
            );
        }
        let Some(terminal) = read_terminal(&tx, terminal_id)? else {
            anyhow::bail!("unknown terminal {terminal_id}; it may not have been adopted yet");
        };
        if let Some(expected) = expected_incarnation
            && terminal.incarnation.as_deref() != Some(expected)
        {
            anyhow::bail!("terminal_incarnation_mismatch");
        }

        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            let result = serde_json::json!({
                "terminal_id": terminal_id,
                "incarnation": terminal.incarnation,
                "closed": true,
                "already_closed": true,
            });
            let result_json = canonical_json(&result)?;
            tx.execute(
                "INSERT INTO terminal_mutations(
                   origin, mutation_id, fingerprint, result_json, committed_revision
                 ) VALUES(?1, ?2, ?3, ?4, ?5)",
                params![
                    mutation.origin,
                    mutation.id,
                    fingerprint,
                    result_json,
                    i64::try_from(current_revision)
                        .context("terminal revision exceeds SQLite integer range")?,
                ],
            )?;
            tx.commit()?;
            return Ok(TerminalRegistryCommit {
                revision: current_revision,
                result,
                replayed: false,
            });
        }

        let revision = current_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let result = serde_json::json!({
            "terminal_id": terminal_id,
            "incarnation": terminal.incarnation,
            "closed": true,
            "already_closed": false,
        });
        let result_json = canonical_json(&result)?;
        tx.execute(
            "UPDATE terminal_placements
             SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
             WHERE terminal_id = ?2",
            params![sqlite_revision, terminal_id],
        )?;
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
            [revision.to_string()],
        )?;
        tx.execute(
            "INSERT INTO terminal_mutations(
               origin, mutation_id, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![mutation.origin, mutation.id, fingerprint, result_json, sqlite_revision],
        )?;
        tx.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, 'terminal-closed', ?2, ?3, ?4, ?5, ?6)",
            params![
                sqlite_revision,
                terminal_id,
                terminal.workspace_key,
                mutation.origin,
                mutation.id,
                result_json,
            ],
        )?;
        tx.commit()?;
        Ok(TerminalRegistryCommit { revision, result, replayed: false })
    }

    /// Tombstone every hosted tab in one pane/screen as one SQLite unit. All
    /// identities and incarnations are validated before the first update, and
    /// any later SQLite failure rolls the entire set back. Hosts are signaled
    /// only after this method commits successfully.
    pub fn close_terminals_atomically(
        &mut self,
        mutation: &WorkspaceMutation,
        terminals: &[(String, Option<String>)],
    ) -> anyhow::Result<TerminalBatchClose> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let mut unique = HashSet::with_capacity(terminals.len());
        for (terminal_id, incarnation) in terminals {
            validate_terminal_identity("terminal id", terminal_id)?;
            if let Some(incarnation) = incarnation {
                validate_terminal_identity("terminal incarnation", incarnation)?;
            }
            if !unique.insert(terminal_id.as_str()) {
                anyhow::bail!("duplicate terminal in batch close: {terminal_id}");
            }
        }

        let tx = self.connection.transaction()?;
        let mut rows = Vec::with_capacity(terminals.len());
        for (terminal_id, expected_incarnation) in terminals {
            let terminal = read_terminal(&tx, terminal_id)?.ok_or_else(|| {
                anyhow::anyhow!("unknown terminal {terminal_id}; it may not have been adopted yet")
            })?;
            if let Some(expected) = expected_incarnation
                && terminal.incarnation.as_deref() != Some(expected)
            {
                anyhow::bail!("terminal_incarnation_mismatch");
            }
            rows.push(terminal);
        }

        let mut revision = transaction_terminal_revision(&tx)?;
        let mut closed = 0usize;
        for terminal in rows {
            if terminal.lifecycle == TerminalLifecycle::Tombstoned {
                continue;
            }
            revision = revision
                .checked_add(1)
                .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
            let sqlite_revision = i64::try_from(revision)
                .context("terminal revision exceeds SQLite integer range")?;
            let result_json = canonical_json(&serde_json::json!({
                "terminal_id": terminal.terminal_id,
                "workspace_key": terminal.workspace_key,
                "incarnation": terminal.incarnation,
                "closed": true,
                "reason": "topology-closed",
            }))?;
            tx.execute(
                "UPDATE terminal_placements
                 SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
                 WHERE terminal_id = ?2 AND lifecycle != 'tombstoned'",
                params![sqlite_revision, terminal.terminal_id],
            )?;
            tx.execute(
                "INSERT INTO terminal_events(
                   revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
                 ) VALUES(?1, 'terminal-closed', ?2, ?3, ?4, ?5, ?6)",
                params![
                    sqlite_revision,
                    terminal.terminal_id,
                    terminal.workspace_key,
                    mutation.origin,
                    mutation.id,
                    result_json,
                ],
            )?;
            closed += 1;
        }
        if closed != 0 {
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
                [revision.to_string()],
            )?;
        }
        tx.commit()?;
        Ok(TerminalBatchClose { revision, closed })
    }

    #[cfg(test)]
    pub(crate) fn set_terminal_close_failure(&self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.connection.execute_batch(
                "CREATE TEMP TRIGGER cmux_test_fail_terminal_close
                 BEFORE UPDATE OF lifecycle ON terminal_placements
                 BEGIN SELECT RAISE(ABORT, 'forced terminal close failure'); END;",
            )?;
        } else {
            self.connection
                .execute_batch("DROP TRIGGER IF EXISTS cmux_test_fail_terminal_close")?;
        }
        Ok(())
    }

    pub fn terminal_events_after(
        &self,
        revision: u64,
    ) -> anyhow::Result<Vec<TerminalRegistryEvent>> {
        let mut statement = self.connection.prepare(
            "SELECT revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             FROM terminal_events WHERE revision > ?1 ORDER BY revision ASC",
        )?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let rows = statement.query_map([sqlite_revision], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
            ))
        })?;
        rows.map(|row| {
            let (revision, kind, terminal_id, workspace_key, origin, mutation_id, result) = row?;
            Ok(TerminalRegistryEvent {
                revision: u64::try_from(revision).context("terminal event revision is negative")?,
                kind,
                terminal_id,
                workspace_key,
                origin,
                mutation_id,
                result: serde_json::from_str(&result)?,
            })
        })
        .collect()
    }

    /// Look up an already-committed mutation before resolving any live
    /// workspace selector. This is what lets a lost-response retry of a
    /// successful close return the original result after the workspace has
    /// become a tombstone.
    pub fn replay(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<Option<RegistryCommit>> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        let stored = self
            .connection
            .query_row(
                "SELECT fingerprint, result_json, committed_revision
                 FROM mutations WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
                },
            )
            .optional()?;
        let Some((stored_fingerprint, stored_result, revision)) = stored else {
            return Ok(None);
        };
        if stored_fingerprint != fingerprint {
            anyhow::bail!(
                "mutation {} from {} was retried with a different payload",
                mutation.id,
                mutation.origin
            );
        }
        Ok(Some(RegistryCommit {
            revision: u64::try_from(revision).context("stored mutation revision is negative")?,
            result: serde_json::from_str(&stored_result)?,
            replayed: true,
        }))
    }

    /// Atomically replace the live ordered registry and record the mutation.
    /// Duplicate lookup intentionally precedes revision validation: a retry of
    /// a committed command must return its original result even after newer
    /// commands have advanced the registry.
    #[allow(clippy::too_many_arguments)]
    pub fn commit(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        result: &Value,
    ) -> anyhow::Result<RegistryCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let tx = self.connection.transaction()?;

        if let Some((stored_fingerprint, stored_result, revision)) = tx
            .query_row(
                "SELECT fingerprint, result_json, committed_revision
                 FROM mutations WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
                },
            )
            .optional()?
        {
            if stored_fingerprint != fingerprint {
                anyhow::bail!(
                    "mutation {} from {} was retried with a different payload",
                    mutation.id,
                    mutation.origin
                );
            }
            return Ok(RegistryCommit {
                revision: u64::try_from(revision)
                    .context("stored mutation revision is negative")?,
                result: serde_json::from_str(&stored_result)?,
                replayed: true,
            });
        }

        validate_workspace_key(workspace_key)?;
        validate_registry(workspaces)?;
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "workspace generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        let current = transaction_revision(&tx)?;
        if let Some(expected) = expected_revision
            && expected != current
        {
            anyhow::bail!("workspace revision conflict: expected {expected}, current {current}");
        }
        let revision = current
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("workspace revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("workspace revision exceeds SQLite integer range")?;
        let previous_active_workspace = tx
            .query_row("SELECT value FROM meta WHERE key = 'active_workspace_id'", [], |row| {
                row.get::<_, String>(0)
            })
            .optional()?;

        for workspace in workspaces {
            let was_tombstoned = tx
                .query_row(
                    "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
                    [&workspace.key],
                    |row| row.get::<_, i64>(0),
                )
                .optional()?;
            if was_tombstoned == Some(1) {
                anyhow::bail!("tombstoned workspace key cannot be reused: {}", workspace.key);
            }
        }

        // Child terminals become durable tombstones in this same transaction,
        // before their workspace rows are tombstoned. Process termination is a
        // post-commit effect and can therefore be retried after a daemon crash
        // without ever letting a frontend resurrect the terminal elsewhere.
        tombstone_terminals_in_removed_workspaces(&tx, workspaces, mutation)?;
        tx.execute(
            "UPDATE workspaces SET tombstoned = 1, position = NULL,
             updated_revision = ?1, deleted_revision = ?1
             WHERE tombstoned = 0",
            [sqlite_revision],
        )?;
        // Tombstone first to release the partial unique position index, then
        // upsert the complete desired order in this same transaction.
        for (position, workspace) in workspaces.iter().enumerate() {
            tx.execute(
                "INSERT INTO workspaces(
                   workspace_key, numeric_id, name, group_key, position, tombstoned,
                   created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, NULL)
                 ON CONFLICT(workspace_key) DO UPDATE SET
                   numeric_id=excluded.numeric_id,
                   name=excluded.name,
                   group_key=excluded.group_key,
                   position=excluded.position,
                   tombstoned=0,
                   updated_revision=excluded.updated_revision,
                   deleted_revision=NULL",
                params![
                    workspace.key,
                    i64::try_from(workspace.id).context("workspace id exceeds SQLite range")?,
                    workspace.name,
                    workspace.group_key,
                    i64::try_from(position).context("workspace position exceeds SQLite range")?,
                    sqlite_revision
                ],
            )?;
        }
        let active_workspace = previous_active_workspace
            .filter(|active| {
                workspaces.iter().any(|workspace| workspace.public_id.as_str() == active)
            })
            .or_else(|| {
                workspaces
                    .iter()
                    .find(|workspace| workspace.key == workspace_key)
                    .map(|workspace| workspace.public_id.to_string())
            })
            .or_else(|| workspaces.first().map(|workspace| workspace.public_id.to_string()));
        if let Some(active_workspace) = active_workspace {
            tx.execute(
                "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                [active_workspace],
            )?;
        } else {
            tx.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
        }
        tx.execute("UPDATE meta SET value = ?1 WHERE key = 'revision'", [revision.to_string()])?;
        tx.execute(
            "INSERT INTO mutations(
               origin, mutation_id, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![mutation.origin, mutation.id, fingerprint, result_json, sqlite_revision],
        )?;
        tx.execute(
            "INSERT INTO workspace_events(
               revision, kind, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                sqlite_revision,
                event_kind,
                workspace_key,
                mutation.origin,
                mutation.id,
                result_json
            ],
        )?;
        tx.commit()?;
        Ok(RegistryCommit { revision, result: result.clone(), replayed: false })
    }

    pub fn events_after(&self, revision: u64) -> anyhow::Result<Vec<RegistryEvent>> {
        let mut statement = self.connection.prepare(
            "SELECT revision, kind, workspace_key, origin, mutation_id, result_json
             FROM workspace_events WHERE revision > ?1 ORDER BY revision ASC",
        )?;
        let sqlite_revision =
            i64::try_from(revision).context("workspace revision exceeds SQLite integer range")?;
        let rows = statement.query_map([sqlite_revision], |row| {
            let result: String = row.get(5)?;
            Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, result))
        })?;
        rows.map(|row| {
            let (revision, kind, workspace_key, origin, mutation_id, result): (
                i64,
                String,
                String,
                String,
                String,
                String,
            ) = row?;
            Ok(RegistryEvent {
                revision: u64::try_from(revision)
                    .context("workspace event revision is negative")?,
                kind,
                workspace_key,
                origin,
                mutation_id,
                result: serde_json::from_str(&result)?,
            })
        })
        .collect()
    }

    pub fn get_frontend_projection(
        &self,
        frontend: &str,
        scope: &str,
        subject_key: &str,
    ) -> anyhow::Result<Option<FrontendProjection>> {
        validate_identifier("frontend", frontend)?;
        validate_identifier("projection scope", scope)?;
        validate_identifier("projection subject", subject_key)?;
        let stored = self
            .connection
            .query_row(
                "SELECT schema_version, projection_revision, payload
                 FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![frontend, scope, subject_key],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, String>(2)?)),
            )
            .optional()?;
        stored
            .map(|(schema_version, projection_revision, payload)| {
                Ok(FrontendProjection {
                    frontend: frontend.to_string(),
                    scope: scope.to_string(),
                    subject_key: subject_key.to_string(),
                    schema_version: u32::try_from(schema_version)
                        .context("projection schema version is invalid")?,
                    projection_revision: u64::try_from(projection_revision)
                        .context("projection revision is negative")?,
                    projection: serde_json::from_str(&payload)?,
                })
            })
            .transpose()
    }

    #[allow(clippy::too_many_arguments)]
    pub fn put_frontend_projection(
        &mut self,
        mutation: &WorkspaceMutation,
        frontend: &str,
        scope: &str,
        subject_key: &str,
        schema_version: u32,
        expected_projection_revision: Option<u64>,
        projection: &Value,
    ) -> anyhow::Result<ProjectionCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("frontend", frontend)?;
        validate_identifier("projection scope", scope)?;
        validate_identifier("projection subject", subject_key)?;
        let payload = canonical_json(projection)?;
        if payload.len() > MAX_PROJECTION_BYTES {
            anyhow::bail!("frontend projection exceeds {MAX_PROJECTION_BYTES} bytes");
        }
        let fingerprint = canonical_json(&serde_json::json!({
            "frontend": frontend,
            "scope": scope,
            "subject_key": subject_key,
            "schema_version": schema_version,
            "projection": projection,
        }))?;
        let tx = self.connection.transaction()?;
        if let Some((stored_fingerprint, result_json)) = tx
            .query_row(
                "SELECT fingerprint, result_json FROM projection_mutations
                 WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
            )
            .optional()?
        {
            if stored_fingerprint != fingerprint {
                anyhow::bail!(
                    "mutation {} from {} was retried with a different payload",
                    mutation.id,
                    mutation.origin
                );
            }
            let stored: FrontendProjection = serde_json::from_str(&result_json)?;
            return Ok(ProjectionCommit { projection: stored, replayed: true });
        }
        let current = tx
            .query_row(
                "SELECT projection_revision FROM frontend_projections
                 WHERE frontend = ?1 AND scope = ?2 AND subject_key = ?3",
                params![frontend, scope, subject_key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?
            .map(u64::try_from)
            .transpose()
            .context("projection revision is negative")?
            .unwrap_or(0);
        if let Some(expected) = expected_projection_revision
            && expected != current
        {
            anyhow::bail!("projection revision conflict: expected {expected}, current {current}");
        }
        let projection_revision = current
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("projection revision exhausted"))?;
        tx.execute(
            "INSERT INTO frontend_projections(
               frontend, scope, subject_key, schema_version, projection_revision, payload
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(frontend, scope, subject_key) DO UPDATE SET
               schema_version=excluded.schema_version,
               projection_revision=excluded.projection_revision,
               payload=excluded.payload",
            params![
                frontend,
                scope,
                subject_key,
                i64::from(schema_version),
                i64::try_from(projection_revision)
                    .context("projection revision exceeds SQLite range")?,
                payload
            ],
        )?;
        let stored = FrontendProjection {
            frontend: frontend.to_string(),
            scope: scope.to_string(),
            subject_key: subject_key.to_string(),
            schema_version,
            projection_revision,
            projection: projection.clone(),
        };
        tx.execute(
            "INSERT INTO projection_mutations(origin, mutation_id, fingerprint, result_json)
             VALUES(?1, ?2, ?3, ?4)",
            params![
                mutation.origin,
                mutation.id,
                fingerprint,
                canonical_json(&serde_json::to_value(&stored)?)?
            ],
        )?;
        tx.commit()?;
        Ok(ProjectionCommit { projection: stored, replayed: false })
    }
}

fn create_workspace_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspaces (
           workspace_key TEXT PRIMARY KEY NOT NULL,
           numeric_id INTEGER UNIQUE NOT NULL,
           name TEXT NOT NULL,
           group_key TEXT NOT NULL,
           position INTEGER,
           tombstoned INTEGER NOT NULL DEFAULT 0 CHECK(tombstoned IN (0,1)),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_workspace_position
           ON workspaces(position) WHERE tombstoned = 0;
         CREATE TABLE IF NOT EXISTS mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );
         CREATE TABLE IF NOT EXISTS workspace_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           result_json TEXT NOT NULL
         );
         CREATE TABLE IF NOT EXISTS frontend_projections (
           frontend TEXT NOT NULL,
           scope TEXT NOT NULL,
           subject_key TEXT NOT NULL,
           schema_version INTEGER NOT NULL,
           projection_revision INTEGER NOT NULL,
           payload TEXT NOT NULL,
           PRIMARY KEY(frontend, scope, subject_key)
         );
         CREATE TABLE IF NOT EXISTS projection_mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );",
    )?;
    Ok(())
}

fn create_terminal_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS terminal_placements (
           terminal_id TEXT PRIMARY KEY NOT NULL,
           workspace_key TEXT NOT NULL REFERENCES workspaces(workspace_key)
             DEFERRABLE INITIALLY DEFERRED,
           incarnation TEXT,
           lifecycle TEXT NOT NULL CHECK(
             lifecycle IN ('launching','adopting','running','exited','tombstoned')
           ),
           launch_spec_json TEXT NOT NULL,
           exit_json TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE UNIQUE INDEX IF NOT EXISTS terminal_incarnation
           ON terminal_placements(incarnation) WHERE incarnation IS NOT NULL;
         CREATE INDEX IF NOT EXISTS live_terminals_by_workspace
           ON terminal_placements(workspace_key, updated_revision)
           WHERE lifecycle != 'tombstoned';
         CREATE TABLE IF NOT EXISTS terminal_mutations (
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, mutation_id)
         );
         CREATE TABLE IF NOT EXISTS terminal_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           terminal_id TEXT NOT NULL,
           workspace_key TEXT NOT NULL,
           origin TEXT NOT NULL,
           mutation_id TEXT NOT NULL,
           result_json TEXT NOT NULL
         );
         CREATE INDEX IF NOT EXISTS terminal_events_by_terminal
           ON terminal_events(terminal_id, revision);",
    )?;
    Ok(())
}

fn ensure_session_public_id(transaction: &Transaction<'_>) -> anyhow::Result<SessionPublicId> {
    let stored = transaction
        .query_row("SELECT value FROM meta WHERE key = 'session_public_id'", [], |row| {
            row.get::<_, String>(0)
        })
        .optional()?;
    if let Some(stored) = stored {
        return Ok(SessionPublicId::parse(stored)?);
    }
    let session_id = SessionPublicId::random()?;
    transaction.execute(
        "INSERT INTO meta(key, value) VALUES('session_public_id', ?1)",
        [session_id.as_str()],
    )?;
    Ok(session_id)
}

fn backfill_workspace_public_ids(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(
            "SELECT workspace_key, created_revision, updated_revision, deleted_revision
             FROM workspaces
             WHERE workspace_key NOT IN (SELECT workspace_key FROM resource_workspaces)
             ORDER BY created_revision ASC, workspace_key ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (workspace_key, created_revision, updated_revision, deleted_revision) in rows {
        let public_id = WorkspacePublicId::random()?;
        transaction.execute(
            "INSERT INTO resource_identities(
               public_id, kind, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'workspace', ?2, ?3, ?4)",
            params![public_id.as_str(), created_revision, updated_revision, deleted_revision],
        )?;
        transaction.execute(
            "INSERT INTO resource_workspaces(
               public_id, workspace_key, active_screen_id,
               created_revision, updated_revision, deleted_revision
             ) VALUES(?1, ?2, NULL, ?3, ?4, ?5)",
            params![
                public_id.as_str(),
                workspace_key,
                created_revision,
                updated_revision,
                deleted_revision
            ],
        )?;
    }
    Ok(())
}

fn upsert_workspace_resource(
    transaction: &Transaction<'_>,
    workspace: &RegistryWorkspace,
    revision: i64,
) -> anyhow::Result<()> {
    if transaction
        .query_row(
            "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?
        == Some(1)
    {
        anyhow::bail!("tombstoned workspace key cannot be reused: {}", workspace.key);
    }
    if let Some((stored_id, deleted_revision)) = transaction
        .query_row(
            "SELECT public_id, deleted_revision
             FROM resource_workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_id != workspace.public_id.as_str() {
            anyhow::bail!(
                "workspace key {} is already bound to public id {}",
                workspace.key,
                stored_id
            );
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    if let Some((stored_key, deleted_revision)) = transaction
        .query_row(
            "SELECT workspace_key, deleted_revision
             FROM resource_workspaces WHERE public_id = ?1",
            [workspace.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_key != workspace.key {
            anyhow::bail!(
                "workspace public id {} is already bound to key {}",
                workspace.public_id,
                stored_key
            );
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    if let Some((kind, deleted_revision)) = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [workspace.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if kind != "workspace" {
            anyhow::bail!("public id {} has resource kind {kind}", workspace.public_id);
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned workspace id cannot be reused: {}", workspace.public_id);
        }
    }
    transaction.execute(
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, 'workspace', ?2, ?2, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           updated_revision=excluded.updated_revision",
        params![workspace.public_id.as_str(), revision],
    )?;
    transaction.execute(
        "INSERT INTO resource_workspaces(
           public_id, workspace_key, active_screen_id,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, NULL, ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           updated_revision=excluded.updated_revision",
        params![workspace.public_id.as_str(), workspace.key, revision],
    )?;
    Ok(())
}

fn tombstone_terminals_in_removed_workspaces(
    transaction: &Transaction<'_>,
    remaining_workspaces: &[RegistryWorkspace],
    mutation: &WorkspaceMutation,
) -> anyhow::Result<()> {
    let remaining =
        remaining_workspaces.iter().map(|workspace| workspace.key.as_str()).collect::<HashSet<_>>();
    let terminals = {
        let mut statement = transaction.prepare(
            "SELECT terminal_id, workspace_key, incarnation
             FROM terminal_placements
             WHERE lifecycle != 'tombstoned'
             ORDER BY created_revision ASC, terminal_id ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let removed = terminals
        .into_iter()
        .filter(|(_, workspace_key, _)| !remaining.contains(workspace_key.as_str()))
        .collect::<Vec<_>>();
    if removed.is_empty() {
        return Ok(());
    }

    let mut revision = transaction_terminal_revision(transaction)?;
    for (terminal_id, workspace_key, incarnation) in removed {
        revision = revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("terminal revision exhausted"))?;
        let sqlite_revision =
            i64::try_from(revision).context("terminal revision exceeds SQLite integer range")?;
        let result = serde_json::json!({
            "terminal_id": terminal_id,
            "workspace_key": workspace_key,
            "incarnation": incarnation,
            "closed": true,
            "reason": "workspace-closed",
        });
        let result_json = canonical_json(&result)?;
        transaction.execute(
            "UPDATE terminal_placements
             SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
             WHERE terminal_id = ?2 AND lifecycle != 'tombstoned'",
            params![sqlite_revision, terminal_id],
        )?;
        transaction.execute(
            "INSERT INTO terminal_events(
               revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
             ) VALUES(?1, 'terminal-closed', ?2, ?3, ?4, ?5, ?6)",
            params![
                sqlite_revision,
                terminal_id,
                workspace_key,
                mutation.origin,
                mutation.id,
                result_json,
            ],
        )?;
    }
    transaction.execute(
        "UPDATE meta SET value = ?1 WHERE key = 'terminal_revision'",
        [revision.to_string()],
    )?;
    Ok(())
}

fn validate_registry(workspaces: &[RegistryWorkspace]) -> anyhow::Result<()> {
    let mut keys = HashSet::new();
    let mut public_ids = HashSet::new();
    for workspace in workspaces {
        validate_workspace_key(&workspace.key)?;
        validate_identifier("workspace group key", &workspace.group_key)?;
        if workspace.id == 0 {
            anyhow::bail!("workspace id cannot be zero");
        }
        if !keys.insert(&workspace.key) {
            anyhow::bail!("workspace key already exists: {}", workspace.key);
        }
        if !public_ids.insert(workspace.public_id.as_str()) {
            anyhow::bail!("workspace public id already exists: {}", workspace.public_id);
        }
    }
    Ok(())
}

fn validate_terminal(terminal: &RegistryTerminal) -> anyhow::Result<()> {
    validate_terminal_identity("terminal id", &terminal.terminal_id)?;
    validate_workspace_key(&terminal.workspace_key)?;
    if let Some(incarnation) = &terminal.incarnation {
        validate_terminal_identity("terminal incarnation", incarnation)?;
    }
    match terminal.lifecycle {
        TerminalLifecycle::Launching if terminal.incarnation.is_some() => {
            anyhow::bail!("launching terminal cannot have an incarnation before host adoption");
        }
        TerminalLifecycle::Adopting | TerminalLifecycle::Running
            if terminal.incarnation.is_none() =>
        {
            anyhow::bail!("{:?} terminal requires a host incarnation", terminal.lifecycle);
        }
        _ => {}
    }
    if terminal.lifecycle != TerminalLifecycle::Exited && terminal.exit.is_some() {
        anyhow::bail!("only an exited terminal can carry exit metadata");
    }
    Ok(())
}

fn validate_terminal_identity(label: &str, value: &str) -> anyhow::Result<()> {
    if value.len() != 32
        || !value.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f'))
        || value.as_bytes()[12] != b'4'
        || !matches!(value.as_bytes()[16], b'8'..=b'b')
    {
        anyhow::bail!("{label} must be a 32-character lowercase UUIDv4 hex value");
    }
    Ok(())
}

fn validate_terminal_transition(
    existing: Option<&RegistryTerminal>,
    desired: &RegistryTerminal,
) -> anyhow::Result<()> {
    let Some(existing) = existing else {
        if desired.lifecycle != TerminalLifecycle::Launching {
            anyhow::bail!("new terminal must be reserved in launching state before host spawn");
        }
        return Ok(());
    };
    if existing.lifecycle == TerminalLifecycle::Tombstoned {
        anyhow::bail!("tombstoned terminal id cannot be reused: {}", desired.terminal_id);
    }
    let allowed = matches!(
        (existing.lifecycle, desired.lifecycle),
        (TerminalLifecycle::Launching, TerminalLifecycle::Launching)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Adopting)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Running)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Launching, TerminalLifecycle::Tombstoned)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Adopting)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Running)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Adopting, TerminalLifecycle::Tombstoned)
            | (TerminalLifecycle::Running, TerminalLifecycle::Adopting)
            | (TerminalLifecycle::Running, TerminalLifecycle::Running)
            | (TerminalLifecycle::Running, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Running, TerminalLifecycle::Tombstoned)
            | (TerminalLifecycle::Exited, TerminalLifecycle::Exited)
            | (TerminalLifecycle::Exited, TerminalLifecycle::Tombstoned)
    );
    if !allowed {
        anyhow::bail!(
            "invalid terminal transition {:?} -> {:?}",
            existing.lifecycle,
            desired.lifecycle
        );
    }
    if matches!(existing.lifecycle, TerminalLifecycle::Adopting | TerminalLifecycle::Running)
        && matches!(desired.lifecycle, TerminalLifecycle::Adopting | TerminalLifecycle::Running)
        && existing.incarnation != desired.incarnation
    {
        anyhow::bail!("live terminal incarnation cannot change without an exit transition");
    }
    if existing.lifecycle != TerminalLifecycle::Exited
        && existing.launch_spec != desired.launch_spec
    {
        anyhow::bail!("terminal launch spec cannot change during a live incarnation");
    }
    Ok(())
}

fn require_live_workspace(connection: &Connection, workspace_key: &str) -> anyhow::Result<()> {
    let live = connection
        .query_row(
            "SELECT 1 FROM workspaces WHERE workspace_key = ?1 AND tombstoned = 0",
            [workspace_key],
            |_| Ok(()),
        )
        .optional()?;
    if live.is_none() {
        anyhow::bail!("terminal workspace is missing or closed: {workspace_key}");
    }
    Ok(())
}

type StoredTerminal = (String, String, Option<String>, String, String, Option<String>);

fn terminal_from_stored(stored: StoredTerminal) -> anyhow::Result<RegistryTerminal> {
    let (terminal_id, workspace_key, incarnation, lifecycle, launch_spec, exit) = stored;
    Ok(RegistryTerminal {
        terminal_id,
        workspace_key,
        incarnation,
        lifecycle: TerminalLifecycle::parse(&lifecycle)?,
        launch_spec: serde_json::from_str(&launch_spec)?,
        exit: exit.map(|value| serde_json::from_str(&value)).transpose()?,
    })
}

fn read_terminal(
    connection: &Connection,
    terminal_id: &str,
) -> anyhow::Result<Option<RegistryTerminal>> {
    let stored = connection
        .query_row(
            "SELECT terminal_id, workspace_key, incarnation, lifecycle,
                    launch_spec_json, exit_json
             FROM terminal_placements WHERE terminal_id = ?1",
            [terminal_id],
            |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?, row.get(5)?))
            },
        )
        .optional()?;
    stored.map(terminal_from_stored).transpose()
}

fn terminal_replay(
    connection: &Connection,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
) -> anyhow::Result<Option<TerminalRegistryCommit>> {
    let stored = connection
        .query_row(
            "SELECT fingerprint, result_json, committed_revision
             FROM terminal_mutations WHERE origin = ?1 AND mutation_id = ?2",
            params![mutation.origin, mutation.id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    let Some((stored_fingerprint, stored_result, revision)) = stored else {
        return Ok(None);
    };
    if stored_fingerprint != fingerprint {
        anyhow::bail!(
            "terminal mutation {} from {} was retried with a different payload",
            mutation.id,
            mutation.origin
        );
    }
    Ok(Some(TerminalRegistryCommit {
        revision: u64::try_from(revision).context("stored terminal revision is negative")?,
        result: serde_json::from_str(&stored_result)?,
        replayed: true,
    }))
}

fn validate_identifier(label: &str, value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        anyhow::bail!("{label} cannot be empty");
    }
    if value.len() > MAX_ID_LEN {
        anyhow::bail!("{label} exceeds {MAX_ID_LEN} bytes");
    }
    if value.chars().any(char::is_control) {
        anyhow::bail!("{label} contains a control character");
    }
    Ok(())
}

fn validate_workspace_key(value: &str) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        anyhow::bail!("workspace key cannot be empty");
    }
    if value.len() > MAX_WORKSPACE_KEY_LEN {
        anyhow::bail!("workspace key exceeds {MAX_WORKSPACE_KEY_LEN} bytes");
    }
    if value.chars().any(char::is_control) {
        anyhow::bail!("workspace key contains a control character");
    }
    Ok(())
}

fn canonical_json(value: &Value) -> anyhow::Result<String> {
    fn write(value: &Value, output: &mut String) -> anyhow::Result<()> {
        match value {
            Value::Object(map) => {
                output.push('{');
                let mut entries = map.iter().collect::<Vec<_>>();
                entries.sort_by_key(|(key, _)| *key);
                for (index, (key, value)) in entries.into_iter().enumerate() {
                    if index != 0 {
                        output.push(',');
                    }
                    output.push_str(&serde_json::to_string(key)?);
                    output.push(':');
                    write(value, output)?;
                }
                output.push('}');
            }
            Value::Array(values) => {
                output.push('[');
                for (index, value) in values.iter().enumerate() {
                    if index != 0 {
                        output.push(',');
                    }
                    write(value, output)?;
                }
                output.push(']');
            }
            primitive => output.push_str(&serde_json::to_string(primitive)?),
        }
        Ok(())
    }
    let mut output = String::new();
    write(value, &mut output)?;
    Ok(output)
}

fn meta_value(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
        .optional()?)
}

fn required_meta(connection: &Connection, key: &str) -> anyhow::Result<String> {
    meta_value(connection, key)?
        .ok_or_else(|| anyhow::anyhow!("workspace registry is missing {key}"))
}

fn current_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "revision")?.parse().context("workspace registry revision is invalid")
}

fn transaction_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value: String =
        transaction
            .query_row("SELECT value FROM meta WHERE key = 'revision'", [], |row| row.get(0))?;
    value.parse().context("workspace registry revision is invalid")
}

fn current_terminal_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "terminal_revision")?
        .parse()
        .context("terminal registry revision is invalid")
}

fn current_resource_revision(connection: &Connection) -> anyhow::Result<u64> {
    required_meta(connection, "resource_revision")?.parse().context("resource revision is invalid")
}

fn transaction_resource_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value: String = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'resource_revision'",
        [],
        |row| row.get(0),
    )?;
    value.parse().context("resource revision is invalid")
}

fn transaction_terminal_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    let value: String = transaction.query_row(
        "SELECT value FROM meta WHERE key = 'terminal_revision'",
        [],
        |row| row.get(0),
    )?;
    value.parse().context("terminal registry revision is invalid")
}

const MACHINE_ID_FILE: &str = "machine-id";
const MACHINE_ID_LOCK_FILE: &str = "machine-id.lock";

fn load_or_create_machine_id(root: &Path) -> anyhow::Result<MachinePublicId> {
    fs::create_dir_all(root).with_context(|| format!("create state root {}", root.display()))?;
    platform::restrict_directory(root)?;
    let lock_path = root.join(MACHINE_ID_LOCK_FILE);
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("open machine identity lock {}", lock_path.display()))?;
    platform::restrict_file(&lock_path)?;
    FileExt::lock(&lock)
        .with_context(|| format!("lock machine identity {}", lock_path.display()))?;

    let path = root.join(MACHINE_ID_FILE);
    let result = match fs::read(&path) {
        Ok(bytes) => {
            platform::restrict_file(&path)?;
            parse_machine_id_file(&path, &bytes)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let id = MachinePublicId::random()?;
            let mut options = OpenOptions::new();
            options.create_new(true).write(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options
                .open(&path)
                .with_context(|| format!("create machine identity {}", path.display()))?;
            platform::restrict_file(&path)?;
            file.write_all(id.as_str().as_bytes())
                .and_then(|()| file.write_all(b"\n"))
                .with_context(|| format!("write machine identity {}", path.display()))?;
            file.sync_all().with_context(|| format!("sync machine identity {}", path.display()))?;
            File::open(root)
                .and_then(|directory| directory.sync_all())
                .with_context(|| format!("sync state root {}", root.display()))?;
            Ok(id)
        }
        Err(error) => {
            Err(error).with_context(|| format!("read machine identity {}", path.display()))
        }
    };
    let _ = FileExt::unlock(&lock);
    result
}

fn parse_machine_id_file(path: &Path, bytes: &[u8]) -> anyhow::Result<MachinePublicId> {
    let content = std::str::from_utf8(bytes)
        .with_context(|| format!("machine identity is not UTF-8: {}", path.display()))?;
    let value = content.strip_suffix('\n').unwrap_or(content);
    anyhow::ensure!(
        !value.is_empty()
            && !value.contains('\n')
            && !value.contains('\r')
            && value.trim() == value,
        "machine identity file is corrupt: {}",
        path.display()
    );
    MachinePublicId::parse(value)
        .with_context(|| format!("machine identity file is corrupt: {}", path.display()))
}

fn session_storage_component(session: &str) -> String {
    let mut readable = String::new();
    let mut hash = 0xcbf29ce484222325u64;
    for byte in session.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x100000001b3);
        if readable.len() < 48 && (byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')) {
            readable.push(char::from(byte));
        } else if readable.len() < 48 {
            readable.push('_');
        }
    }
    if readable.is_empty() {
        readable.push_str("session");
    }
    format!("{readable}-{hash:016x}")
}

pub(crate) fn new_uuid_v4() -> String {
    try_new_uuid_v4().expect("operating system randomness unavailable")
}

pub(crate) fn try_new_uuid_v4() -> anyhow::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| crate::resource::ResourceError::allocation("uuid"))?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Ok(format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    ))
}

pub(crate) fn is_canonical_workspace_key(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.len() == 36
        && bytes.iter().enumerate().all(|(index, byte)| {
            if matches!(index, 8 | 13 | 18 | 23) {
                *byte == b'-'
            } else {
                matches!(*byte, b'0'..=b'9' | b'a'..=b'f')
            }
        })
}

struct SessionLease {
    file: File,
    path: PathBuf,
}

impl SessionLease {
    fn acquire(path: &Path) -> anyhow::Result<Self> {
        let file =
            OpenOptions::new().create(true).truncate(false).read(true).write(true).open(path)?;
        platform::restrict_file(path)?;
        FileExt::try_lock(&file).with_context(|| {
            format!("workspace session is already owned by another daemon: {}", path.display())
        })?;
        Ok(Self { file, path: path.to_path_buf() })
    }
}

impl Drop for SessionLease {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.file);
        let _ = &self.path;
    }
}

#[cfg(test)]
mod tests;
