//! Durable, single-writer workspace registry.
//!
//! The mux owns one of these behind its workspace-commit mutex. A registry
//! transaction commits before the corresponding in-memory projection and
//! event are published, so durable order, reply order, and event order are the
//! same order. Runtime pane/surface ids deliberately never enter this store.

use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

use anyhow::Context;
use fs4::FileExt;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::platform;

const SCHEMA_VERSION: i64 = 1;
const MAX_ID_LEN: usize = 128;
const MAX_PROJECTION_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RegistryWorkspace {
    pub id: u64,
    pub key: String,
    pub name: String,
    pub group_key: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistrySnapshot {
    pub registry_id: String,
    pub generation: String,
    pub revision: u64,
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
        Self::initialize(connection, session_name.to_string(), None)
    }

    pub fn open(root: &Path, session_name: &str) -> anyhow::Result<Self> {
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
        Self::initialize(connection, session_name.to_string(), Some(lease))
    }

    fn initialize(
        connection: Connection,
        session_name: String,
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
             );
             CREATE TABLE IF NOT EXISTS workspaces (
               workspace_key TEXT PRIMARY KEY NOT NULL,
               numeric_id INTEGER UNIQUE NOT NULL,
               name TEXT NOT NULL,
               group_key TEXT NOT NULL,
               position INTEGER,
               tombstoned INTEGER NOT NULL DEFAULT 0 CHECK(tombstoned IN (0,1)),
               created_revision INTEGER NOT NULL,
               updated_revision INTEGER NOT NULL
               ,deleted_revision INTEGER
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

        let stored_schema = meta_value(&connection, "schema_version")?;
        match stored_schema {
            Some(value) if value.parse::<i64>()? != SCHEMA_VERSION => {
                anyhow::bail!(
                    "unsupported workspace registry schema {value}; expected {SCHEMA_VERSION}"
                );
            }
            Some(_) => {}
            None => {
                let tx = connection.unchecked_transaction()?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('schema_version', ?1)",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.execute("INSERT INTO meta(key, value) VALUES('revision', '0')", [])?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('session_name', ?1)",
                    [&session_name],
                )?;
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('registry_id', ?1)",
                    [new_uuid_v4()],
                )?;
                tx.commit()?;
            }
        }
        let stored_name = required_meta(&connection, "session_name")?;
        if stored_name != session_name {
            anyhow::bail!(
                "workspace registry belongs to session {stored_name:?}, not {session_name:?}"
            );
        }
        let registry_id = required_meta(&connection, "registry_id")?;
        validate_identifier("registry id", &registry_id)?;
        let quick_check: String =
            connection.query_row("PRAGMA quick_check", [], |row| row.get(0))?;
        if quick_check != "ok" {
            anyhow::bail!("workspace registry integrity check failed: {quick_check}");
        }
        Ok(Self { connection, registry_id, generation: new_uuid_v4(), session_name, _lease: lease })
    }

    pub fn snapshot(&self) -> anyhow::Result<RegistrySnapshot> {
        let revision = current_revision(&self.connection)?;
        let mut statement = self.connection.prepare(
            "SELECT numeric_id, workspace_key, name, group_key
             FROM workspaces WHERE tombstoned = 0 ORDER BY position ASC",
        )?;
        let workspaces = statement
            .query_map([], |row| {
                let id: i64 = row.get(0)?;
                Ok((id, row.get(1)?, row.get(2)?, row.get(3)?))
            })?
            .map(|row| {
                let (id, key, name, group_key): (i64, String, String, String) = row?;
                Ok::<RegistryWorkspace, anyhow::Error>(RegistryWorkspace {
                    id: u64::try_from(id).context("stored workspace id is negative")?,
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
            workspaces,
        })
    }

    pub fn registry_id(&self) -> &str {
        &self.registry_id
    }

    pub fn generation(&self) -> &str {
        &self.generation
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

        validate_identifier("workspace key", workspace_key)?;
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

fn validate_registry(workspaces: &[RegistryWorkspace]) -> anyhow::Result<()> {
    let mut keys = std::collections::HashSet::new();
    for workspace in workspaces {
        validate_identifier("workspace key", &workspace.key)?;
        validate_identifier("workspace group key", &workspace.group_key)?;
        if workspace.id == 0 {
            anyhow::bail!("workspace id cannot be zero");
        }
        if !keys.insert(&workspace.key) {
            anyhow::bail!("workspace key already exists: {}", workspace.key);
        }
    }
    Ok(())
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

fn canonical_json(value: &Value) -> anyhow::Result<String> {
    fn write(value: &Value, output: &mut String) -> anyhow::Result<()> {
        match value {
            Value::Object(map) => {
                output.push('{');
                let mut entries = map.iter().collect::<Vec<_>>();
                entries.sort_by(|(left, _), (right, _)| left.cmp(right));
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
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).expect("operating system randomness unavailable");
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
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
    )
}

struct SessionLease {
    file: File,
    path: PathBuf,
}

impl SessionLease {
    fn acquire(path: &Path) -> anyhow::Result<Self> {
        let file = OpenOptions::new().create(true).read(true).write(true).open(path)?;
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
mod tests {
    use super::*;
    use serde_json::json;

    fn temp_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
    }

    fn workspace(id: u64, key: &str, name: &str) -> RegistryWorkspace {
        RegistryWorkspace { id, key: key.into(), name: name.into(), group_key: "default".into() }
    }

    #[test]
    fn durable_commit_recovers_and_changes_generation() {
        let root = temp_root("recover");
        let first = {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            let before = registry.snapshot().unwrap();
            let mutation = WorkspaceMutation::new(new_uuid_v4(), "browser").unwrap();
            let result = json!({"key":"one"});
            let commit = registry
                .commit(
                    &mutation,
                    &json!({"op":"create","key":"one"}),
                    None,
                    Some(0),
                    "workspace-added",
                    "one",
                    &[RegistryWorkspace {
                        id: 1,
                        key: "one".into(),
                        name: "One".into(),
                        group_key: "default".into(),
                    }],
                    &result,
                )
                .unwrap();
            assert_eq!(commit.revision, 1);
            (before.registry_id, before.generation)
        };
        let recovered = WorkspaceRegistry::open(&root, "session").unwrap();
        let snapshot = recovered.snapshot().unwrap();
        assert_eq!(snapshot.registry_id, first.0);
        assert_ne!(snapshot.generation, first.1);
        assert_eq!(snapshot.revision, 1);
        assert_eq!(snapshot.workspaces[0].key, "one");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn retry_precedes_revision_check_and_payload_mismatch_is_rejected() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        let mutation = WorkspaceMutation::new("mutation", "browser").unwrap();
        let fingerprint = json!({"op":"create","key":"one"});
        let result = json!({"key":"one"});
        let workspaces = [RegistryWorkspace {
            id: 1,
            key: "one".into(),
            name: "One".into(),
            group_key: "default".into(),
        }];
        let first = registry
            .commit(
                &mutation,
                &fingerprint,
                None,
                Some(0),
                "workspace-added",
                "one",
                &workspaces,
                &result,
            )
            .unwrap();
        assert!(!first.replayed);
        let retry = registry
            .commit(
                &mutation,
                &fingerprint,
                None,
                Some(0),
                "workspace-added",
                "one",
                &workspaces,
                &result,
            )
            .unwrap();
        assert!(retry.replayed);
        assert_eq!(retry.revision, 1);
        assert!(
            registry
                .commit(
                    &mutation,
                    &json!({"op":"create","key":"different"}),
                    None,
                    None,
                    "workspace-added",
                    "different",
                    &workspaces,
                    &result,
                )
                .is_err()
        );
    }

    #[test]
    fn second_writer_is_rejected() {
        let root = temp_root("lease");
        let first = WorkspaceRegistry::open(&root, "same").unwrap();
        assert!(WorkspaceRegistry::open(&root, "same").is_err());
        drop(first);
        WorkspaceRegistry::open(&root, "same").unwrap();
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn tombstones_prevent_workspace_key_reuse() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        registry
            .commit(
                &WorkspaceMutation::new("create", "browser").unwrap(),
                &json!({"op":"create"}),
                None,
                Some(0),
                "workspace-added",
                "stable",
                &[workspace(1, "stable", "One")],
                &json!({"workspace":1,"key":"stable"}),
            )
            .unwrap();
        registry
            .commit(
                &WorkspaceMutation::new("close", "browser").unwrap(),
                &json!({"op":"close"}),
                None,
                Some(1),
                "workspace-closed",
                "stable",
                &[],
                &json!({"workspace":1,"key":"stable"}),
            )
            .unwrap();
        let error = registry
            .commit(
                &WorkspaceMutation::new("recreate", "browser").unwrap(),
                &json!({"op":"create"}),
                None,
                Some(2),
                "workspace-added",
                "stable",
                &[workspace(2, "stable", "Again")],
                &json!({"workspace":2,"key":"stable"}),
            )
            .unwrap_err();
        assert!(error.to_string().contains("tombstoned workspace key cannot be reused"));
    }

    #[test]
    fn frontend_projection_is_durable_cas_and_exactly_once() {
        let root = temp_root("projection");
        let mutation = WorkspaceMutation::new("layout-1", "browser-profile").unwrap();
        {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            let first = registry
                .put_frontend_projection(
                    &mutation,
                    "cmux-browser",
                    "window-group",
                    "group-a",
                    1,
                    Some(0),
                    &json!({"columns":[{"workspace":"one"}]}),
                )
                .unwrap();
            assert_eq!(first.projection.projection_revision, 1);
            assert!(!first.replayed);
            let retry = registry
                .put_frontend_projection(
                    &mutation,
                    "cmux-browser",
                    "window-group",
                    "group-a",
                    1,
                    Some(0),
                    &json!({"columns":[{"workspace":"one"}]}),
                )
                .unwrap();
            assert!(retry.replayed);
            assert_eq!(retry.projection.projection_revision, 1);
            assert!(
                registry
                    .put_frontend_projection(
                        &WorkspaceMutation::new("layout-2", "browser-profile").unwrap(),
                        "cmux-browser",
                        "window-group",
                        "group-a",
                        1,
                        Some(0),
                        &json!({}),
                    )
                    .unwrap_err()
                    .to_string()
                    .contains("projection revision conflict")
            );
        }
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let recovered = registry
            .get_frontend_projection("cmux-browser", "window-group", "group-a")
            .unwrap()
            .unwrap();
        assert_eq!(recovered.projection_revision, 1);
        assert_eq!(recovered.projection["columns"][0]["workspace"], "one");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn interrupted_transaction_and_newer_schema_fail_closed() {
        let root = temp_root("transaction");
        {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            let tx = registry.connection.transaction().unwrap();
            tx.execute("UPDATE meta SET value = '77' WHERE key = 'revision'", []).unwrap();
            drop(tx);
            assert_eq!(registry.snapshot().unwrap().revision, 0);
        }
        fs::remove_dir_all(&root).unwrap();

        let newer_root = temp_root("newer");
        let session_dir = newer_root.join(session_storage_component("session"));
        fs::create_dir_all(&session_dir).unwrap();
        let db = Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
        db.execute_batch(
            "CREATE TABLE meta(key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
             INSERT INTO meta(key,value) VALUES('schema_version','999');",
        )
        .unwrap();
        drop(db);
        assert!(
            WorkspaceRegistry::open(&newer_root, "session")
                .unwrap_err()
                .to_string()
                .contains("unsupported workspace registry schema")
        );
        fs::remove_dir_all(newer_root).unwrap();
    }
}
