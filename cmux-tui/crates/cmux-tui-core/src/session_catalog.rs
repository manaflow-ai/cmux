//! Durable discovery for the local device's independent mux sessions.
//!
//! The catalog owns names, aliases, immutable owner locators, and repair state.
//! A session owner remains authoritative for its workspace tree and live state.

use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::Context;
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Transaction, TransactionBehavior, params,
};
use serde::{Deserialize, Serialize};

use crate::platform;
use crate::resource::{MachinePublicId, SessionPublicId};
use crate::terminal_host_runtime;
use crate::workspace_registry::{
    WORKSPACE_REGISTRY_FILE, WorkspaceRegistry, load_or_create_machine_id,
    session_storage_component,
};

pub const SESSION_CATALOG_FILE: &str = "catalog.sqlite3";
const CATALOG_SCHEMA_VERSION: i64 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CatalogAliasKind {
    Primary,
    Legacy,
    User,
}

impl CatalogAliasKind {
    fn as_str(self) -> &'static str {
        match self {
            Self::Primary => "primary",
            Self::Legacy => "legacy",
            Self::User => "user",
        }
    }

    fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "primary" => Ok(Self::Primary),
            "legacy" => Ok(Self::Legacy),
            "user" => Ok(Self::User),
            _ => anyhow::bail!("session catalog contains an invalid alias kind"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CatalogRepairPhase {
    Creating,
    Ready,
    Deleting,
    Failed,
}

impl CatalogRepairPhase {
    fn parse(value: &str) -> anyhow::Result<Self> {
        match value {
            "creating" => Ok(Self::Creating),
            "ready" => Ok(Self::Ready),
            "deleting" => Ok(Self::Deleting),
            "failed" => Ok(Self::Failed),
            _ => anyhow::bail!("session catalog contains an invalid repair phase"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogLocator {
    pub kind: String,
    pub value: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogSessionLocators {
    pub storage_component: String,
    pub terminal_host_component: String,
    pub socket: CatalogLocator,
    pub remote_state: CatalogLocator,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogAlias {
    pub value: String,
    pub kind: CatalogAliasKind,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogSession {
    pub machine_id: MachinePublicId,
    pub session_id: SessionPublicId,
    pub registry_id: String,
    pub owner_key: String,
    pub display_name: String,
    pub locators: CatalogSessionLocators,
    pub aliases: Vec<CatalogAlias>,
    pub repair_phase: CatalogRepairPhase,
    pub created_sequence: u64,
    pub updated_revision: u64,
    pub deleted_revision: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CatalogSnapshot {
    pub machine_id: MachinePublicId,
    pub revision: u64,
    pub sessions: Vec<CatalogSession>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LegacyImportReport {
    pub examined: usize,
    pub imported: usize,
    pub unchanged: usize,
    pub migrated_registries: usize,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CatalogRepairReport {
    pub readied: usize,
    pub failed: usize,
    pub tombstoned: usize,
}

#[derive(Debug)]
struct LegacySession {
    session_id: SessionPublicId,
    registry_id: String,
    owner_key: String,
    display_name: String,
    locators: CatalogSessionLocators,
}

enum LegacyScan {
    Ready(LegacySession),
    NeedsMigration(String),
}

pub struct SessionCatalog {
    root: PathBuf,
    machine_id: MachinePublicId,
    connection: Connection,
}

impl std::fmt::Debug for SessionCatalog {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("SessionCatalog")
            .field("root", &self.root)
            .field("machine_id", &self.machine_id)
            .finish_non_exhaustive()
    }
}

impl SessionCatalog {
    pub fn open(root: &Path) -> anyhow::Result<Self> {
        fs::create_dir_all(root)
            .with_context(|| format!("create session catalog root {}", root.display()))?;
        platform::restrict_directory(root)?;
        let machine_id = load_or_create_machine_id(root)?;
        let database_path = root.join(SESSION_CATALOG_FILE);
        if fs::symlink_metadata(&database_path).is_ok_and(|metadata| metadata.is_symlink()) {
            anyhow::bail!("session catalog database cannot be a symbolic link");
        }
        let mut connection = Connection::open(&database_path)
            .with_context(|| format!("open session catalog {}", database_path.display()))?;
        platform::restrict_file(&database_path)?;
        connection.busy_timeout(Duration::from_secs(5))?;
        preflight_catalog_schema(&connection)?;
        connection.execute_batch(
            "PRAGMA foreign_keys=ON;
             PRAGMA journal_mode=WAL;
             PRAGMA synchronous=FULL;
             PRAGMA fullfsync=ON;
             PRAGMA wal_autocheckpoint=1000;
             CREATE TABLE IF NOT EXISTS catalog_meta (
               key TEXT PRIMARY KEY NOT NULL,
               value TEXT NOT NULL
             );
             CREATE TABLE IF NOT EXISTS local_sessions (
               session_id TEXT PRIMARY KEY NOT NULL,
               machine_id TEXT NOT NULL,
               registry_id TEXT NOT NULL,
               owner_key TEXT NOT NULL,
               display_name TEXT NOT NULL,
               storage_component TEXT NOT NULL,
               terminal_host_component TEXT NOT NULL,
               socket_kind TEXT NOT NULL,
               socket_value TEXT NOT NULL,
               remote_state_kind TEXT NOT NULL,
               remote_state_value TEXT NOT NULL,
               repair_phase TEXT NOT NULL CHECK(
                 repair_phase IN ('creating','ready','deleting','failed')
               ),
               created_sequence INTEGER NOT NULL UNIQUE,
               updated_revision INTEGER NOT NULL,
               deleted_revision INTEGER
             );
             CREATE TABLE IF NOT EXISTS local_session_aliases (
               alias TEXT NOT NULL COLLATE BINARY,
               session_id TEXT NOT NULL,
               kind TEXT NOT NULL CHECK(kind IN ('primary','legacy','user')),
               created_revision INTEGER NOT NULL,
               deleted_revision INTEGER,
               FOREIGN KEY(session_id) REFERENCES local_sessions(session_id)
             );
             CREATE UNIQUE INDEX IF NOT EXISTS live_local_session_registry
               ON local_sessions(registry_id COLLATE BINARY)
               WHERE deleted_revision IS NULL;
             CREATE UNIQUE INDEX IF NOT EXISTS live_local_session_owner
               ON local_sessions(owner_key COLLATE BINARY)
               WHERE deleted_revision IS NULL;
             CREATE UNIQUE INDEX IF NOT EXISTS live_local_session_storage
               ON local_sessions(storage_component COLLATE BINARY)
               WHERE deleted_revision IS NULL;
             CREATE UNIQUE INDEX IF NOT EXISTS live_local_session_terminal_host
               ON local_sessions(terminal_host_component COLLATE BINARY)
               WHERE deleted_revision IS NULL;
             CREATE UNIQUE INDEX IF NOT EXISTS live_local_session_alias
               ON local_session_aliases(alias COLLATE BINARY)
               WHERE deleted_revision IS NULL;
             CREATE INDEX IF NOT EXISTS local_session_aliases_by_session
               ON local_session_aliases(session_id, created_revision);",
        )?;
        initialize_meta(&mut connection)?;
        Ok(Self { root: root.to_path_buf(), machine_id, connection })
    }

    pub fn machine_id(&self) -> &MachinePublicId {
        &self.machine_id
    }

    pub fn import_legacy_sessions(&mut self) -> anyhow::Result<LegacyImportReport> {
        let mut scans = self.scan_legacy_sessions()?;
        let migration_names = scans
            .iter()
            .filter_map(|scan| match scan {
                LegacyScan::NeedsMigration(name) => Some(name.clone()),
                LegacyScan::Ready(_) => None,
            })
            .collect::<Vec<_>>();
        for name in &migration_names {
            drop(WorkspaceRegistry::open(&self.root, name).with_context(|| {
                format!("migrate legacy workspace registry for session {name:?}")
            })?);
        }
        if !migration_names.is_empty() {
            scans = self.scan_legacy_sessions()?;
        }
        let mut candidates = scans
            .into_iter()
            .map(|scan| match scan {
                LegacyScan::Ready(session) => Ok(session),
                LegacyScan::NeedsMigration(name) => {
                    anyhow::bail!("legacy session {name:?} did not gain a public session id")
                }
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        candidates.sort_by(|left, right| legacy_sort_key(left).cmp(&legacy_sort_key(right)));
        validate_legacy_candidates(&candidates)?;

        let mut report = LegacyImportReport {
            examined: candidates.len(),
            migrated_registries: migration_names.len(),
            ..LegacyImportReport::default()
        };
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let old_revision = meta_u64(&transaction, "revision")?;
        let revision = old_revision.checked_add(1).context("session catalog revision exhausted")?;
        let mut next_sequence = meta_u64(&transaction, "next_sequence")?;
        let mut changed = false;
        for candidate in candidates {
            if let Some(existing) = stored_immutable_session(&transaction, &candidate.session_id)? {
                verify_immutable_session(&self.machine_id, &candidate, &existing)?;
                let alias_changed = ensure_import_alias(&transaction, &candidate, revision)?;
                if alias_changed {
                    touch_session_revision(&transaction, &candidate.session_id, revision)?;
                }
                changed |= alias_changed;
                report.unchanged += 1;
                continue;
            }
            insert_legacy_session(
                &transaction,
                &self.machine_id,
                &candidate,
                next_sequence,
                revision,
            )?;
            next_sequence =
                next_sequence.checked_add(1).context("session catalog sequence exhausted")?;
            report.imported += 1;
            changed = true;
        }
        if changed {
            set_meta_u64(&transaction, "revision", revision)?;
            set_meta_u64(&transaction, "next_sequence", next_sequence)?;
        }
        transaction.commit()?;
        Ok(report)
    }

    pub fn snapshot(&self, include_deleted: bool) -> anyhow::Result<CatalogSnapshot> {
        let revision = connection_meta_u64(&self.connection, "revision")?;
        let mut statement = self.connection.prepare(
            "SELECT session_id, machine_id, registry_id, owner_key, display_name,
                    storage_component, terminal_host_component, socket_kind, socket_value,
                    remote_state_kind, remote_state_value, repair_phase, created_sequence,
                    updated_revision, deleted_revision
             FROM local_sessions
             WHERE ?1 OR deleted_revision IS NULL
             ORDER BY created_sequence ASC, session_id ASC",
        )?;
        let rows = statement.query_map([include_deleted], |row| {
            Ok(StoredSessionRow {
                session_id: row.get(0)?,
                machine_id: row.get(1)?,
                registry_id: row.get(2)?,
                owner_key: row.get(3)?,
                display_name: row.get(4)?,
                storage_component: row.get(5)?,
                terminal_host_component: row.get(6)?,
                socket_kind: row.get(7)?,
                socket_value: row.get(8)?,
                remote_state_kind: row.get(9)?,
                remote_state_value: row.get(10)?,
                repair_phase: row.get(11)?,
                created_sequence: row.get(12)?,
                updated_revision: row.get(13)?,
                deleted_revision: row.get(14)?,
            })
        })?;
        let sessions =
            rows.map(|row| self.decode_session(row?)).collect::<anyhow::Result<Vec<_>>>()?;
        Ok(CatalogSnapshot { machine_id: self.machine_id.clone(), revision, sessions })
    }

    pub fn resolve_alias(&self, alias: &str) -> anyhow::Result<Option<CatalogSession>> {
        let session_id = self
            .connection
            .query_row(
                "SELECT session_id FROM local_session_aliases
                 WHERE alias = ?1 COLLATE BINARY AND deleted_revision IS NULL",
                [alias],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        let Some(session_id) = session_id else { return Ok(None) };
        let session_id = SessionPublicId::parse(session_id)?;
        Ok(self
            .snapshot(false)?
            .sessions
            .into_iter()
            .find(|session| session.session_id == session_id))
    }

    pub fn rename(
        &mut self,
        session_id: &SessionPublicId,
        display_name: &str,
    ) -> anyhow::Result<u64> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_live_session(&transaction, session_id)?;
        let revision = next_revision(&transaction)?;
        transaction.execute(
            "UPDATE local_sessions
             SET display_name = ?1, updated_revision = ?2
             WHERE session_id = ?3",
            params![display_name, revision, session_id.as_str()],
        )?;
        set_meta_u64(&transaction, "revision", revision)?;
        transaction.commit()?;
        Ok(revision)
    }

    pub fn add_alias(
        &mut self,
        session_id: &SessionPublicId,
        alias: &str,
        kind: CatalogAliasKind,
    ) -> anyhow::Result<u64> {
        anyhow::ensure!(kind != CatalogAliasKind::Legacy, "legacy aliases are import-only");
        validate_new_alias(alias)?;
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_live_session(&transaction, session_id)?;
        let revision = next_revision(&transaction)?;
        transaction
            .execute(
                "INSERT INTO local_session_aliases(
                   alias, session_id, kind, created_revision, deleted_revision
                 ) VALUES(?1, ?2, ?3, ?4, NULL)",
                params![alias, session_id.as_str(), kind.as_str(), revision],
            )
            .with_context(|| format!("add exact session alias {alias:?}"))?;
        touch_session_revision(&transaction, session_id, revision)?;
        set_meta_u64(&transaction, "revision", revision)?;
        transaction.commit()?;
        Ok(revision)
    }

    pub fn begin_delete(&mut self, session_id: &SessionPublicId) -> anyhow::Result<u64> {
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        require_live_session(&transaction, session_id)?;
        let revision = next_revision(&transaction)?;
        transaction.execute(
            "UPDATE local_sessions
             SET repair_phase = 'deleting', updated_revision = ?1
             WHERE session_id = ?2",
            params![revision, session_id.as_str()],
        )?;
        set_meta_u64(&transaction, "revision", revision)?;
        transaction.commit()?;
        Ok(revision)
    }

    pub fn repair_incomplete(&mut self) -> anyhow::Result<CatalogRepairReport> {
        let pending = self.pending_repairs()?;
        let mut ready = Vec::new();
        let mut failed = Vec::new();
        let mut deleted = Vec::new();
        for session in pending {
            let storage = self.root.join(&session.storage_component);
            match session.repair_phase {
                CatalogRepairPhase::Creating => {
                    if registry_matches(&storage.join(WORKSPACE_REGISTRY_FILE), &session)? {
                        ready.push(session.session_id);
                    } else {
                        failed.push(session.session_id);
                    }
                }
                CatalogRepairPhase::Deleting if !storage.try_exists()? => {
                    deleted.push(session.session_id);
                }
                CatalogRepairPhase::Deleting
                | CatalogRepairPhase::Ready
                | CatalogRepairPhase::Failed => {}
            }
        }
        if ready.is_empty() && failed.is_empty() && deleted.is_empty() {
            return Ok(CatalogRepairReport::default());
        }
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let revision = next_revision(&transaction)?;
        for session_id in &ready {
            transaction.execute(
                "UPDATE local_sessions SET repair_phase = 'ready', updated_revision = ?1
                 WHERE session_id = ?2 AND deleted_revision IS NULL",
                params![revision, session_id.as_str()],
            )?;
        }
        for session_id in &failed {
            transaction.execute(
                "UPDATE local_sessions SET repair_phase = 'failed', updated_revision = ?1
                 WHERE session_id = ?2 AND deleted_revision IS NULL",
                params![revision, session_id.as_str()],
            )?;
        }
        for session_id in &deleted {
            transaction.execute(
                "UPDATE local_sessions
                 SET updated_revision = ?1, deleted_revision = ?1
                 WHERE session_id = ?2 AND deleted_revision IS NULL",
                params![revision, session_id.as_str()],
            )?;
            transaction.execute(
                "UPDATE local_session_aliases SET deleted_revision = ?1
                 WHERE session_id = ?2 AND deleted_revision IS NULL",
                params![revision, session_id.as_str()],
            )?;
        }
        set_meta_u64(&transaction, "revision", revision)?;
        transaction.commit()?;
        Ok(CatalogRepairReport {
            readied: ready.len(),
            failed: failed.len(),
            tombstoned: deleted.len(),
        })
    }

    fn scan_legacy_sessions(&self) -> anyhow::Result<Vec<LegacyScan>> {
        let mut scans = Vec::new();
        for entry in fs::read_dir(&self.root)
            .with_context(|| format!("scan session catalog root {}", self.root.display()))?
        {
            let entry = entry?;
            if !entry.file_type()?.is_dir() {
                continue;
            }
            let database = entry.path().join(WORKSPACE_REGISTRY_FILE);
            let metadata = match fs::symlink_metadata(&database) {
                Ok(metadata) => metadata,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.into()),
            };
            if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
                continue;
            }
            let connection =
                Connection::open_with_flags(&database, OpenFlags::SQLITE_OPEN_READ_ONLY)
                    .with_context(|| {
                        format!("inspect legacy session registry {}", database.display())
                    })?;
            connection.busy_timeout(Duration::from_millis(500))?;
            let session_name = required_registry_meta(&connection, "session_name")?;
            let expected_component = session_storage_component(&session_name);
            let actual_component = entry
                .file_name()
                .into_string()
                .map_err(|_| anyhow::anyhow!("legacy session directory name is not UTF-8"))?;
            anyhow::ensure!(
                actual_component == expected_component,
                "legacy session directory does not match its stored owner name"
            );
            let registry_id = required_registry_meta(&connection, "registry_id")?;
            validate_registry_id(&registry_id)?;
            let session_id = registry_meta(&connection, "session_public_id")?;
            let Some(session_id) = session_id else {
                scans.push(LegacyScan::NeedsMigration(session_name));
                continue;
            };
            let session_id = SessionPublicId::parse(session_id)?;
            let terminal_host_component =
                terminal_host_runtime::terminal_host_root(&self.root, &session_name)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .context("terminal-host locator is not UTF-8")?
                    .to_string();
            scans.push(LegacyScan::Ready(LegacySession {
                session_id,
                registry_id,
                owner_key: session_name.clone(),
                display_name: session_name.clone(),
                locators: CatalogSessionLocators {
                    storage_component: actual_component,
                    terminal_host_component,
                    socket: CatalogLocator {
                        kind: "legacy-default".to_string(),
                        value: session_name.clone(),
                    },
                    remote_state: CatalogLocator {
                        kind: "legacy-session-name".to_string(),
                        value: session_name,
                    },
                },
            }));
        }
        Ok(scans)
    }

    fn decode_session(&self, row: StoredSessionRow) -> anyhow::Result<CatalogSession> {
        let session_id = SessionPublicId::parse(row.session_id)?;
        let machine_id = MachinePublicId::parse(row.machine_id)?;
        anyhow::ensure!(
            machine_id == self.machine_id,
            "session catalog row has a different machine identity"
        );
        validate_registry_id(&row.registry_id)?;
        let mut statement = self.connection.prepare(
            "SELECT alias, kind FROM local_session_aliases
             WHERE session_id = ?1 AND deleted_revision IS NULL
             ORDER BY created_revision ASC, rowid ASC",
        )?;
        let aliases = statement
            .query_map([session_id.as_str()], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .map(|row| {
                let (value, kind) = row?;
                Ok(CatalogAlias { value, kind: CatalogAliasKind::parse(&kind)? })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        Ok(CatalogSession {
            machine_id,
            session_id,
            registry_id: row.registry_id,
            owner_key: row.owner_key,
            display_name: row.display_name,
            locators: CatalogSessionLocators {
                storage_component: row.storage_component,
                terminal_host_component: row.terminal_host_component,
                socket: CatalogLocator { kind: row.socket_kind, value: row.socket_value },
                remote_state: CatalogLocator {
                    kind: row.remote_state_kind,
                    value: row.remote_state_value,
                },
            },
            aliases,
            repair_phase: CatalogRepairPhase::parse(&row.repair_phase)?,
            created_sequence: stored_u64(row.created_sequence, "created sequence")?,
            updated_revision: stored_u64(row.updated_revision, "updated revision")?,
            deleted_revision: row
                .deleted_revision
                .map(|value| stored_u64(value, "deleted revision"))
                .transpose()?,
        })
    }

    fn pending_repairs(&self) -> anyhow::Result<Vec<CatalogSession>> {
        Ok(self
            .snapshot(false)?
            .sessions
            .into_iter()
            .filter(|session| {
                matches!(
                    session.repair_phase,
                    CatalogRepairPhase::Creating | CatalogRepairPhase::Deleting
                )
            })
            .collect())
    }
}

#[derive(Debug)]
struct StoredSessionRow {
    session_id: String,
    machine_id: String,
    registry_id: String,
    owner_key: String,
    display_name: String,
    storage_component: String,
    terminal_host_component: String,
    socket_kind: String,
    socket_value: String,
    remote_state_kind: String,
    remote_state_value: String,
    repair_phase: String,
    created_sequence: i64,
    updated_revision: i64,
    deleted_revision: Option<i64>,
}

#[derive(Debug)]
struct StoredImmutableSession {
    machine_id: String,
    registry_id: String,
    owner_key: String,
    storage_component: String,
    terminal_host_component: String,
    socket_kind: String,
    socket_value: String,
    remote_state_kind: String,
    remote_state_value: String,
    deleted_revision: Option<i64>,
}

fn initialize_meta(connection: &mut Connection) -> anyhow::Result<()> {
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    transaction.execute(
        "INSERT OR IGNORE INTO catalog_meta(key, value) VALUES('schema_version', ?1)",
        [CATALOG_SCHEMA_VERSION.to_string()],
    )?;
    transaction
        .execute("INSERT OR IGNORE INTO catalog_meta(key, value) VALUES('revision', '0')", [])?;
    transaction.execute(
        "INSERT OR IGNORE INTO catalog_meta(key, value) VALUES('next_sequence', '0')",
        [],
    )?;
    let stored = transaction.query_row(
        "SELECT value FROM catalog_meta WHERE key = 'schema_version'",
        [],
        |row| row.get::<_, String>(0),
    )?;
    let version = stored.parse::<i64>().context("session catalog schema is invalid")?;
    anyhow::ensure!(
        version == CATALOG_SCHEMA_VERSION,
        "unsupported session catalog schema {version}; expected {CATALOG_SCHEMA_VERSION}"
    );
    transaction.commit()?;
    Ok(())
}

fn preflight_catalog_schema(connection: &Connection) -> anyhow::Result<()> {
    let has_meta = connection.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'catalog_meta'
         )",
        [],
        |row| row.get::<_, bool>(0),
    )?;
    if !has_meta {
        return Ok(());
    }
    let stored = connection
        .query_row("SELECT value FROM catalog_meta WHERE key = 'schema_version'", [], |row| {
            row.get::<_, String>(0)
        })
        .optional()?
        .context("session catalog schema version is missing")?;
    let version = stored.parse::<i64>().context("session catalog schema is invalid")?;
    anyhow::ensure!(
        version == CATALOG_SCHEMA_VERSION,
        "unsupported session catalog schema {version}; expected {CATALOG_SCHEMA_VERSION}"
    );
    Ok(())
}

fn legacy_sort_key(session: &LegacySession) -> (u8, &[u8], &str) {
    (
        u8::from(session.owner_key != "main"),
        session.owner_key.as_bytes(),
        session.session_id.as_str(),
    )
}

fn validate_legacy_candidates(candidates: &[LegacySession]) -> anyhow::Result<()> {
    let mut session_ids = HashSet::new();
    let mut registry_ids = HashSet::new();
    let mut owner_keys = HashSet::new();
    let mut storage = HashSet::new();
    let mut terminal_hosts = HashSet::new();
    for session in candidates {
        anyhow::ensure!(session_ids.insert(session.session_id.as_str()), "duplicate session id");
        anyhow::ensure!(registry_ids.insert(session.registry_id.as_str()), "duplicate registry id");
        anyhow::ensure!(owner_keys.insert(session.owner_key.as_str()), "duplicate owner key");
        anyhow::ensure!(
            storage.insert(session.locators.storage_component.as_str()),
            "duplicate session storage locator"
        );
        anyhow::ensure!(
            terminal_hosts.insert(session.locators.terminal_host_component.as_str()),
            "duplicate terminal-host locator"
        );
    }
    Ok(())
}

fn insert_legacy_session(
    transaction: &Transaction<'_>,
    machine_id: &MachinePublicId,
    session: &LegacySession,
    sequence: u64,
    revision: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO local_sessions(
           session_id, machine_id, registry_id, owner_key, display_name,
           storage_component, terminal_host_component, socket_kind, socket_value,
           remote_state_kind, remote_state_value, repair_phase, created_sequence,
           updated_revision, deleted_revision
         ) VALUES(
           ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'ready', ?12, ?13, NULL
         )",
        params![
            session.session_id.as_str(),
            machine_id.as_str(),
            session.registry_id,
            session.owner_key,
            session.display_name,
            session.locators.storage_component,
            session.locators.terminal_host_component,
            session.locators.socket.kind,
            session.locators.socket.value,
            session.locators.remote_state.kind,
            session.locators.remote_state.value,
            sequence,
            revision,
        ],
    )?;
    insert_alias(
        transaction,
        &session.owner_key,
        &session.session_id,
        CatalogAliasKind::Legacy,
        revision,
    )?;
    if !is_safe_alias(&session.owner_key) {
        let generated = generated_primary_alias(&session.session_id);
        insert_alias(
            transaction,
            &generated,
            &session.session_id,
            CatalogAliasKind::Primary,
            revision,
        )?;
    }
    Ok(())
}

fn ensure_import_alias(
    transaction: &Transaction<'_>,
    session: &LegacySession,
    revision: u64,
) -> anyhow::Result<bool> {
    let mut changed = ensure_exact_alias(
        transaction,
        &session.owner_key,
        &session.session_id,
        CatalogAliasKind::Legacy,
        revision,
    )?;
    if !is_safe_alias(&session.owner_key) {
        changed |= ensure_exact_alias(
            transaction,
            &generated_primary_alias(&session.session_id),
            &session.session_id,
            CatalogAliasKind::Primary,
            revision,
        )?;
    }
    Ok(changed)
}

fn ensure_exact_alias(
    transaction: &Transaction<'_>,
    alias: &str,
    session_id: &SessionPublicId,
    kind: CatalogAliasKind,
    revision: u64,
) -> anyhow::Result<bool> {
    let existing = transaction
        .query_row(
            "SELECT session_id FROM local_session_aliases
             WHERE alias = ?1 COLLATE BINARY AND deleted_revision IS NULL",
            [alias],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    match existing {
        Some(existing) => {
            anyhow::ensure!(
                existing == session_id.as_str(),
                "session alias belongs to a different session"
            );
            Ok(false)
        }
        None => {
            insert_alias(transaction, alias, session_id, kind, revision)?;
            Ok(true)
        }
    }
}

fn insert_alias(
    transaction: &Transaction<'_>,
    alias: &str,
    session_id: &SessionPublicId,
    kind: CatalogAliasKind,
    revision: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO local_session_aliases(
           alias, session_id, kind, created_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, NULL)",
        params![alias, session_id.as_str(), kind.as_str(), revision],
    )?;
    Ok(())
}

fn generated_primary_alias(session_id: &SessionPublicId) -> String {
    let payload = session_id.as_str().strip_prefix("session_").unwrap_or(session_id.as_str());
    format!("session-{}", &payload[..12])
}

fn validate_new_alias(alias: &str) -> anyhow::Result<()> {
    anyhow::ensure!(is_safe_alias(alias), "new aliases must be a safe routing alias");
    Ok(())
}

fn is_safe_alias(alias: &str) -> bool {
    !alias.is_empty()
        && alias.len() <= 128
        && alias
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
}

fn stored_immutable_session(
    transaction: &Transaction<'_>,
    session_id: &SessionPublicId,
) -> anyhow::Result<Option<StoredImmutableSession>> {
    Ok(transaction
        .query_row(
            "SELECT machine_id, registry_id, owner_key, storage_component,
                    terminal_host_component, socket_kind, socket_value,
                    remote_state_kind, remote_state_value, deleted_revision
             FROM local_sessions WHERE session_id = ?1",
            [session_id.as_str()],
            |row| {
                Ok(StoredImmutableSession {
                    machine_id: row.get(0)?,
                    registry_id: row.get(1)?,
                    owner_key: row.get(2)?,
                    storage_component: row.get(3)?,
                    terminal_host_component: row.get(4)?,
                    socket_kind: row.get(5)?,
                    socket_value: row.get(6)?,
                    remote_state_kind: row.get(7)?,
                    remote_state_value: row.get(8)?,
                    deleted_revision: row.get(9)?,
                })
            },
        )
        .optional()?)
}

fn verify_immutable_session(
    machine_id: &MachinePublicId,
    candidate: &LegacySession,
    stored: &StoredImmutableSession,
) -> anyhow::Result<()> {
    anyhow::ensure!(stored.deleted_revision.is_none(), "legacy session is already tombstoned");
    anyhow::ensure!(stored.registry_id == candidate.registry_id, "session registry id changed");
    anyhow::ensure!(stored.owner_key == candidate.owner_key, "session owner key changed");
    anyhow::ensure!(
        stored.storage_component == candidate.locators.storage_component,
        "session storage locator changed"
    );
    anyhow::ensure!(
        stored.terminal_host_component == candidate.locators.terminal_host_component,
        "terminal-host locator changed"
    );
    anyhow::ensure!(
        stored.socket_kind == candidate.locators.socket.kind
            && stored.socket_value == candidate.locators.socket.value,
        "session socket locator changed"
    );
    anyhow::ensure!(
        stored.remote_state_kind == candidate.locators.remote_state.kind
            && stored.remote_state_value == candidate.locators.remote_state.value,
        "remote state locator changed"
    );
    anyhow::ensure!(stored.machine_id == machine_id.as_str(), "session machine id changed");
    Ok(())
}

fn require_live_session(
    transaction: &Transaction<'_>,
    session_id: &SessionPublicId,
) -> anyhow::Result<()> {
    let exists = transaction.query_row(
        "SELECT EXISTS(
           SELECT 1 FROM local_sessions WHERE session_id = ?1 AND deleted_revision IS NULL
         )",
        [session_id.as_str()],
        |row| row.get::<_, bool>(0),
    )?;
    anyhow::ensure!(exists, "session is absent from the local catalog");
    Ok(())
}

fn touch_session_revision(
    transaction: &Transaction<'_>,
    session_id: &SessionPublicId,
    revision: u64,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE local_sessions SET updated_revision = ?1
         WHERE session_id = ?2 AND deleted_revision IS NULL",
        params![revision, session_id.as_str()],
    )?;
    Ok(())
}

fn registry_matches(database: &Path, session: &CatalogSession) -> anyhow::Result<bool> {
    let metadata = match fs::symlink_metadata(database) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error.into()),
    };
    if !metadata.file_type().is_file() || metadata.file_type().is_symlink() {
        return Ok(false);
    }
    let connection = Connection::open_with_flags(database, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    Ok(registry_meta(&connection, "session_public_id")?.as_deref()
        == Some(session.session_id.as_str())
        && registry_meta(&connection, "registry_id")?.as_deref()
            == Some(session.registry_id.as_str()))
}

fn registry_meta(connection: &Connection, key: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get(0))
        .optional()?)
}

fn required_registry_meta(connection: &Connection, key: &str) -> anyhow::Result<String> {
    registry_meta(connection, key)?.with_context(|| format!("legacy registry is missing {key}"))
}

fn validate_registry_id(value: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !value.trim().is_empty() && value.len() <= 128 && !value.chars().any(char::is_control),
        "legacy registry id is invalid"
    );
    Ok(())
}

fn next_revision(transaction: &Transaction<'_>) -> anyhow::Result<u64> {
    meta_u64(transaction, "revision")?.checked_add(1).context("session catalog revision exhausted")
}

fn connection_meta_u64(connection: &Connection, key: &str) -> anyhow::Result<u64> {
    let value =
        connection.query_row("SELECT value FROM catalog_meta WHERE key = ?1", [key], |row| {
            row.get::<_, String>(0)
        })?;
    value.parse().with_context(|| format!("session catalog {key} is invalid"))
}

fn meta_u64(transaction: &Transaction<'_>, key: &str) -> anyhow::Result<u64> {
    let value =
        transaction.query_row("SELECT value FROM catalog_meta WHERE key = ?1", [key], |row| {
            row.get::<_, String>(0)
        })?;
    value.parse().with_context(|| format!("session catalog {key} is invalid"))
}

fn set_meta_u64(transaction: &Transaction<'_>, key: &str, value: u64) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE catalog_meta SET value = ?1 WHERE key = ?2",
        params![value.to_string(), key],
    )?;
    Ok(())
}

fn stored_u64(value: i64, name: &str) -> anyhow::Result<u64> {
    u64::try_from(value).with_context(|| format!("session catalog {name} is negative"))
}
