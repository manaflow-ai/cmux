//! Durable, single-writer workspace registry.
//!
//! The mux owns one of these behind its workspace-commit mutex. A registry
//! transaction commits before the corresponding in-memory projection and
//! event are published, so durable order, reply order, and event order are the
//! same order. Runtime pane/surface ids deliberately never enter this store.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File, OpenOptions};
use std::path::{Path, PathBuf};

use anyhow::Context;
use fs4::FileExt;
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::platform;
use crate::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, ScreenPublicId, SessionPublicId, SplitPublicId,
    TabPublicId, TerminalPublicId, WorkspacePublicId,
};

const SCHEMA_VERSION: i64 = 3;
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

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryScreen {
    pub public_id: ScreenPublicId,
    pub workspace_id: WorkspacePublicId,
    pub position: usize,
    pub name: Option<String>,
    pub layout: RegistryLayoutNode,
    pub active_pane: PanePublicId,
    pub zoomed_pane: Option<PanePublicId>,
    pub auto_layout: Option<Vec<PanePublicId>>,
    pub viewport: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum RegistryLayoutNode {
    Leaf {
        pane: PanePublicId,
    },
    Split {
        split: SplitPublicId,
        direction: String,
        ratio: f32,
        first: Box<RegistryLayoutNode>,
        second: Box<RegistryLayoutNode>,
    },
    Stack {
        panes: Vec<PanePublicId>,
        expanded: PanePublicId,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryPane {
    pub public_id: PanePublicId,
    pub screen_id: ScreenPublicId,
    pub name: Option<String>,
    pub active_tab: Option<TabPublicId>,
    pub creation_ordinal: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegistryTab {
    pub public_id: TabPublicId,
    pub pane_id: PanePublicId,
    pub position: usize,
    pub content_id: ContentPublicId,
    pub name: Option<String>,
    pub browser_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourceTopologySnapshot {
    pub session_id: SessionPublicId,
    pub generation: String,
    pub revision: u64,
    pub active_workspace: Option<WorkspacePublicId>,
    pub active_screens: Vec<(WorkspacePublicId, Option<ScreenPublicId>)>,
    pub screens: Vec<RegistryScreen>,
    pub panes: Vec<RegistryPane>,
    pub tabs: Vec<RegistryTab>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourcePatch {
    pub changes: Vec<ResourceChange>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ResourceChange {
    UpsertWorkspace {
        workspace: RegistryWorkspace,
        position: usize,
        active_screen: Option<ScreenPublicId>,
    },
    TombstoneWorkspace {
        workspace_id: WorkspacePublicId,
    },
    SetWorkspaceOrder {
        workspace_ids: Vec<WorkspacePublicId>,
    },
    SetActiveWorkspace {
        workspace_id: Option<WorkspacePublicId>,
    },
    UpsertScreen(RegistryScreen),
    TombstoneScreen {
        screen_id: ScreenPublicId,
    },
    SetScreenOrder {
        workspace_id: WorkspacePublicId,
        screen_ids: Vec<ScreenPublicId>,
    },
    UpsertPane(RegistryPane),
    TombstonePane {
        pane_id: PanePublicId,
    },
    UpsertTab(RegistryTab),
    TombstoneTab {
        tab_id: TabPublicId,
    },
    SetTabOrder {
        pane_id: PanePublicId,
        tab_ids: Vec<TabPublicId>,
    },
    UpsertTerminal {
        public_id: TerminalPublicId,
        terminal: RegistryTerminal,
    },
    TombstoneTerminal {
        public_id: TerminalPublicId,
        expected_incarnation: Option<String>,
    },
    UpsertBrowser {
        public_id: BrowserPublicId,
        url: String,
    },
    TombstoneBrowser {
        public_id: BrowserPublicId,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct ResourcePatchCommit {
    pub revision: u64,
    pub result: Value,
    pub replayed: bool,
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
            Some(value) if matches!(value.parse::<i64>()?, 1 | 2) => {
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
                tx.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [SCHEMA_VERSION.to_string()],
                )?;
                tx.commit()?;
            }
            Some(value) => {
                anyhow::bail!(
                    "unsupported workspace registry schema {value}; expected 1, 2, or {SCHEMA_VERSION}"
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

    pub fn resource_topology_snapshot(&self) -> anyhow::Result<ResourceTopologySnapshot> {
        let revision = current_resource_revision(&self.connection)?;
        let active_workspace = meta_value(&self.connection, "active_workspace_id")?
            .map(WorkspacePublicId::parse)
            .transpose()?;
        let active_screens = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, active_screen_id
                 FROM resource_workspaces
                 WHERE deleted_revision IS NULL
                 ORDER BY created_revision ASC, public_id ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?))
                })?
                .map(|row| {
                    let (workspace, screen) = row?;
                    Ok((
                        WorkspacePublicId::parse(workspace)?,
                        screen.map(ScreenPublicId::parse).transpose()?,
                    ))
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let screens = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, workspace_id, position, name, layout_json,
                        active_pane_id, zoomed_pane_id, auto_layout_json, viewport_json
                 FROM resource_screens
                 WHERE deleted_revision IS NULL
                 ORDER BY workspace_id ASC, position ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, Option<String>>(7)?,
                        row.get::<_, String>(8)?,
                    ))
                })?
                .map(|row| {
                    let (
                        public_id,
                        workspace_id,
                        position,
                        name,
                        layout,
                        active_pane,
                        zoomed_pane,
                        auto_layout,
                        viewport,
                    ) = row?;
                    Ok(RegistryScreen {
                        public_id: ScreenPublicId::parse(public_id)?,
                        workspace_id: WorkspacePublicId::parse(workspace_id)?,
                        position: usize::try_from(position)
                            .context("stored screen position is negative")?,
                        name,
                        layout: serde_json::from_str(&layout)?,
                        active_pane: PanePublicId::parse(active_pane)?,
                        zoomed_pane: zoomed_pane.map(PanePublicId::parse).transpose()?,
                        auto_layout: auto_layout
                            .map(|value| serde_json::from_str(&value))
                            .transpose()?,
                        viewport: serde_json::from_str(&viewport)?,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let panes = {
            let mut statement = self.connection.prepare(
                "SELECT public_id, screen_id, name, active_tab_id, creation_ordinal
                 FROM resource_panes
                 WHERE deleted_revision IS NULL
                 ORDER BY screen_id ASC, creation_ordinal ASC, public_id ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, i64>(4)?,
                    ))
                })?
                .map(|row| {
                    let (public_id, screen_id, name, active_tab, creation_ordinal) = row?;
                    Ok(RegistryPane {
                        public_id: PanePublicId::parse(public_id)?,
                        screen_id: ScreenPublicId::parse(screen_id)?,
                        name,
                        active_tab: active_tab.map(TabPublicId::parse).transpose()?,
                        creation_ordinal: u64::try_from(creation_ordinal)
                            .context("stored pane creation ordinal is negative")?,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        let tabs = {
            let mut statement = self.connection.prepare(
                "SELECT t.public_id, t.pane_id, t.position, t.content_kind,
                        t.content_id, t.name, b.url
                 FROM resource_tabs t
                 LEFT JOIN resource_browsers b ON b.public_id = t.content_id
                 WHERE t.deleted_revision IS NULL
                 ORDER BY t.pane_id ASC, t.position ASC",
            )?;
            statement
                .query_map([], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, Option<String>>(6)?,
                    ))
                })?
                .map(|row| {
                    let (public_id, pane_id, position, kind, content_id, name, browser_url) = row?;
                    let content_id = match kind.as_str() {
                        "terminal" => {
                            ContentPublicId::Terminal(TerminalPublicId::parse(content_id)?)
                        }
                        "browser" => ContentPublicId::Browser(BrowserPublicId::parse(content_id)?),
                        _ => anyhow::bail!("stored tab has invalid content kind {kind:?}"),
                    };
                    Ok(RegistryTab {
                        public_id: TabPublicId::parse(public_id)?,
                        pane_id: PanePublicId::parse(pane_id)?,
                        position: usize::try_from(position)
                            .context("stored tab position is negative")?,
                        content_id,
                        name,
                        browser_url,
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?
        };
        Ok(ResourceTopologySnapshot {
            session_id: self.session_id.clone(),
            generation: self.generation.clone(),
            revision,
            active_workspace,
            active_screens,
            screens,
            panes,
            tabs,
        })
    }

    #[allow(clippy::too_many_arguments)]
    pub fn commit_resource_patch(
        &mut self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        patch: &ResourcePatch,
        result: &Value,
        deltas: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        validate_identifier("resource operation", operation)?;
        validate_resource_patch(patch)?;
        let fingerprint = canonical_json(fingerprint)?;
        let result_json = canonical_json(result)?;
        let deltas_json = canonical_json(deltas)?;
        let tx = self.connection.transaction()?;
        if let Some(replayed) = resource_patch_replay(&tx, mutation, operation, &fingerprint)? {
            return Ok(replayed);
        }
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "resource generation conflict: expected {expected}, current {}",
                self.generation
            );
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

        apply_resource_patch(&tx, patch, sqlite_revision)?;
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
                result_json,
                sqlite_revision,
            ],
        )?;
        tx.execute(
            "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                sqlite_revision,
                i64::try_from(previous_revision)
                    .context("resource revision exceeds SQLite range")?,
                mutation.origin,
                mutation.id,
                deltas_json,
            ],
        )?;
        tx.commit()?;
        Ok(ResourcePatchCommit { revision, result: result.clone(), replayed: false })
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failure(&self, enabled: bool) -> anyhow::Result<()> {
        if enabled {
            self.connection.execute_batch(
                "CREATE TEMP TRIGGER cmux_test_fail_resource_patch
                 BEFORE INSERT ON resource_events
                 BEGIN SELECT RAISE(ABORT, 'forced resource patch failure'); END;",
            )?;
        } else {
            self.connection
                .execute_batch("DROP TRIGGER IF EXISTS cmux_test_fail_resource_patch")?;
        }
        Ok(())
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
        let previous_resource_revision = transaction_resource_revision(&tx)?;
        let resource_revision = previous_resource_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_resource_revision = i64::try_from(resource_revision)
            .context("resource revision exceeds SQLite integer range")?;

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
        tombstone_resources_in_removed_workspaces(&tx, workspaces, sqlite_resource_revision)?;

        tx.execute(
            "UPDATE workspaces SET tombstoned = 1, position = NULL,
             updated_revision = ?1, deleted_revision = ?1
             WHERE tombstoned = 0",
            [sqlite_revision],
        )?;
        // Tombstone first to release the partial unique position index, then
        // upsert the complete desired order in this same transaction.
        for (position, workspace) in workspaces.iter().enumerate() {
            upsert_workspace_resource(&tx, workspace, sqlite_resource_revision)?;
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
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [resource_revision.to_string()],
        )?;
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
        tx.execute(
            "INSERT INTO resource_mutations(
               origin, idempotency_key, operation, fingerprint, result_json, committed_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                mutation.origin,
                mutation.id,
                event_kind,
                fingerprint,
                result_json,
                sqlite_resource_revision
            ],
        )?;
        let resource_deltas = canonical_json(&serde_json::json!([{
            "event": event_kind,
            "workspace_id": workspaces
                .iter()
                .find(|workspace| workspace.key == workspace_key)
                .map(|workspace| workspace.public_id.as_str()),
            "workspace_key": workspace_key,
            "result": result,
        }]))?;
        tx.execute(
            "INSERT INTO resource_events(
               revision, previous_revision, origin, idempotency_key, deltas_json
             ) VALUES(?1, ?2, ?3, ?4, ?5)",
            params![
                sqlite_resource_revision,
                i64::try_from(previous_resource_revision)
                    .context("resource revision exceeds SQLite integer range")?,
                mutation.origin,
                mutation.id,
                resource_deltas,
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

fn create_resource_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS resource_identities (
           public_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (kind = 'workspace' AND length(public_id) = 35 AND substr(public_id, 1, 3) = 'ws_'
               AND substr(public_id, 4) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'screen' AND length(public_id) = 39 AND substr(public_id, 1, 7) = 'screen_'
               AND substr(public_id, 8) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'pane' AND length(public_id) = 37 AND substr(public_id, 1, 5) = 'pane_'
               AND substr(public_id, 6) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'tab' AND length(public_id) = 36 AND substr(public_id, 1, 4) = 'tab_'
               AND substr(public_id, 5) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'terminal' AND length(public_id) = 37 AND substr(public_id, 1, 5) = 'term_'
               AND substr(public_id, 6) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'browser' AND length(public_id) = 40 AND substr(public_id, 1, 8) = 'browser_'
               AND substr(public_id, 9) NOT GLOB '*[^0-9a-f]*') OR
             (kind = 'split' AND length(public_id) = 38 AND substr(public_id, 1, 6) = 'split_'
               AND substr(public_id, 7) NOT GLOB '*[^0-9a-f]*')
           )
         );
         CREATE TABLE IF NOT EXISTS resource_workspaces (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           workspace_key TEXT UNIQUE NOT NULL REFERENCES workspaces(workspace_key)
             DEFERRABLE INITIALLY DEFERRED,
           active_screen_id TEXT REFERENCES resource_screens(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE TABLE IF NOT EXISTS resource_screens (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           workspace_id TEXT NOT NULL REFERENCES resource_workspaces(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           position INTEGER,
           name TEXT,
           layout_json TEXT NOT NULL,
           active_pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           zoomed_pane_id TEXT REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           auto_layout_json TEXT,
           viewport_json TEXT NOT NULL,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND position IS NOT NULL) OR
             (deleted_revision IS NOT NULL AND position IS NULL)
           )
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_resource_screen_position
           ON resource_screens(workspace_id, position) WHERE deleted_revision IS NULL;
         CREATE TABLE IF NOT EXISTS resource_panes (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           screen_id TEXT NOT NULL REFERENCES resource_screens(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           name TEXT,
           active_tab_id TEXT REFERENCES resource_tabs(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           creation_ordinal INTEGER NOT NULL,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER
         );
         CREATE TABLE IF NOT EXISTS resource_tabs (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           pane_id TEXT NOT NULL REFERENCES resource_panes(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           position INTEGER,
           content_kind TEXT NOT NULL CHECK(content_kind IN ('terminal','browser')),
           content_id TEXT UNIQUE NOT NULL REFERENCES resource_identities(public_id)
             DEFERRABLE INITIALLY DEFERRED,
           name TEXT,
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND position IS NOT NULL) OR
             (deleted_revision IS NOT NULL AND position IS NULL)
           )
         );
         CREATE UNIQUE INDEX IF NOT EXISTS live_resource_tab_position
           ON resource_tabs(pane_id, position) WHERE deleted_revision IS NULL;
         CREATE TABLE IF NOT EXISTS resource_terminals (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           terminal_id TEXT UNIQUE NOT NULL REFERENCES terminal_placements(terminal_id)
             DEFERRABLE INITIALLY DEFERRED,
           lifecycle TEXT NOT NULL CHECK(lifecycle IN ('active','tombstoned')),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND lifecycle = 'active') OR
             (deleted_revision IS NOT NULL AND lifecycle = 'tombstoned')
           )
         );
         CREATE TABLE IF NOT EXISTS resource_browsers (
           public_id TEXT PRIMARY KEY NOT NULL REFERENCES resource_identities(public_id),
           url TEXT NOT NULL,
           lifecycle TEXT NOT NULL CHECK(lifecycle IN ('running','tombstoned')),
           created_revision INTEGER NOT NULL,
           updated_revision INTEGER NOT NULL,
           deleted_revision INTEGER,
           CHECK (
             (deleted_revision IS NULL AND lifecycle = 'running') OR
             (deleted_revision IS NOT NULL AND lifecycle = 'tombstoned')
           )
         );
         CREATE TABLE IF NOT EXISTS resource_mutations (
           origin TEXT NOT NULL,
           idempotency_key TEXT NOT NULL,
           operation TEXT NOT NULL,
           fingerprint TEXT NOT NULL,
           result_json TEXT NOT NULL,
           committed_revision INTEGER NOT NULL,
           PRIMARY KEY(origin, idempotency_key)
         );
         CREATE TABLE IF NOT EXISTS resource_events (
           revision INTEGER PRIMARY KEY NOT NULL,
           previous_revision INTEGER NOT NULL,
           origin TEXT NOT NULL,
           idempotency_key TEXT NOT NULL,
           deltas_json TEXT NOT NULL
         );",
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

fn tombstone_resources_in_removed_workspaces(
    transaction: &Transaction<'_>,
    remaining_workspaces: &[RegistryWorkspace],
    revision: i64,
) -> anyhow::Result<()> {
    let remaining = remaining_workspaces
        .iter()
        .map(|workspace| workspace.public_id.as_str())
        .collect::<HashSet<_>>();
    let removed = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_workspaces
             WHERE deleted_revision IS NULL ORDER BY created_revision ASC, public_id ASC",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
            .into_iter()
            .filter(|public_id| !remaining.contains(public_id.as_str()))
            .collect::<Vec<_>>()
    };
    for workspace_id in removed {
        let screens = {
            let mut statement = transaction.prepare(
                "SELECT public_id, layout_json FROM resource_screens
                 WHERE workspace_id = ?1 AND deleted_revision IS NULL",
            )?;
            statement
                .query_map([&workspace_id], |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?
        };
        let screen_ids = screens.iter().map(|(id, _)| id.clone()).collect::<Vec<_>>();
        let pane_ids = {
            let mut panes = Vec::new();
            for screen_id in &screen_ids {
                let mut statement = transaction.prepare(
                    "SELECT public_id FROM resource_panes
                     WHERE screen_id = ?1 AND deleted_revision IS NULL",
                )?;
                panes.extend(
                    statement
                        .query_map([screen_id], |row| row.get::<_, String>(0))?
                        .collect::<Result<Vec<_>, _>>()?,
                );
            }
            panes
        };
        let tab_and_content_ids = {
            let mut ids = Vec::new();
            for pane_id in &pane_ids {
                let mut statement = transaction.prepare(
                    "SELECT public_id, content_id FROM resource_tabs
                     WHERE pane_id = ?1 AND deleted_revision IS NULL",
                )?;
                ids.extend(
                    statement
                        .query_map([pane_id], |row| {
                            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
                        })?
                        .collect::<Result<Vec<_>, _>>()?,
                );
            }
            ids
        };
        let mut identity_ids = vec![workspace_id.clone()];
        identity_ids.extend(screen_ids.iter().cloned());
        identity_ids.extend(pane_ids.iter().cloned());
        for (tab_id, content_id) in &tab_and_content_ids {
            identity_ids.push(tab_id.clone());
            identity_ids.push(content_id.clone());
        }
        for (_, layout_json) in &screens {
            let layout: RegistryLayoutNode = serde_json::from_str(layout_json)?;
            collect_split_public_ids(&layout, &mut identity_ids);
        }

        for (_, content_id) in &tab_and_content_ids {
            transaction.execute(
                "UPDATE resource_terminals
                 SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
                 WHERE public_id = ?2 AND deleted_revision IS NULL",
                params![revision, content_id],
            )?;
            transaction.execute(
                "UPDATE resource_browsers
                 SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
                 WHERE public_id = ?2 AND deleted_revision IS NULL",
                params![revision, content_id],
            )?;
        }
        for (tab_id, _) in &tab_and_content_ids {
            transaction.execute(
                "UPDATE resource_tabs SET position = NULL, updated_revision = ?1,
                   deleted_revision = ?1
                 WHERE public_id = ?2 AND deleted_revision IS NULL",
                params![revision, tab_id],
            )?;
        }
        for pane_id in &pane_ids {
            transaction.execute(
                "UPDATE resource_panes SET updated_revision = ?1, deleted_revision = ?1
                 WHERE public_id = ?2 AND deleted_revision IS NULL",
                params![revision, pane_id],
            )?;
        }
        for screen_id in &screen_ids {
            transaction.execute(
                "UPDATE resource_screens SET position = NULL, updated_revision = ?1,
                   deleted_revision = ?1
                 WHERE public_id = ?2 AND deleted_revision IS NULL",
                params![revision, screen_id],
            )?;
        }
        transaction.execute(
            "UPDATE resource_workspaces SET updated_revision = ?1, deleted_revision = ?1
             WHERE public_id = ?2 AND deleted_revision IS NULL",
            params![revision, workspace_id],
        )?;
        for public_id in identity_ids {
            transaction.execute(
                "UPDATE resource_identities SET updated_revision = ?1, deleted_revision = ?1
                 WHERE public_id = ?2 AND deleted_revision IS NULL",
                params![revision, public_id],
            )?;
        }
    }
    Ok(())
}

fn collect_split_public_ids(layout: &RegistryLayoutNode, output: &mut Vec<String>) {
    match layout {
        RegistryLayoutNode::Leaf { .. } | RegistryLayoutNode::Stack { .. } => {}
        RegistryLayoutNode::Split { split, first, second, .. } => {
            output.push(split.to_string());
            collect_split_public_ids(first, output);
            collect_split_public_ids(second, output);
        }
    }
}

fn resource_patch_replay(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    operation: &str,
    fingerprint: &str,
) -> anyhow::Result<Option<ResourcePatchCommit>> {
    let stored = transaction
        .query_row(
            "SELECT operation, fingerprint, result_json, committed_revision
             FROM resource_mutations
             WHERE origin = ?1 AND idempotency_key = ?2",
            params![mutation.origin, mutation.id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((stored_operation, stored_fingerprint, result, revision)) = stored else {
        return Ok(None);
    };
    if stored_operation != operation || stored_fingerprint != fingerprint {
        anyhow::bail!(
            "idempotency.conflict: key {} from {} was reused with different input",
            mutation.id,
            mutation.origin
        );
    }
    Ok(Some(ResourcePatchCommit {
        revision: u64::try_from(revision).context("stored resource revision is negative")?,
        result: serde_json::from_str(&result)?,
        replayed: true,
    }))
}

fn validate_resource_patch(patch: &ResourcePatch) -> anyhow::Result<()> {
    if patch.changes.is_empty() {
        anyhow::bail!("resource patch cannot be empty");
    }
    let mut targets = HashSet::new();
    let mut singleton_changes = HashSet::new();
    for change in &patch.changes {
        let target = match change {
            ResourceChange::UpsertWorkspace { workspace, .. } => {
                validate_registry(std::slice::from_ref(workspace))?;
                format!("workspace:{}", workspace.public_id)
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                format!("workspace:{workspace_id}")
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                validate_order_ids("workspace", workspace_ids.iter().map(|id| id.as_str()))?;
                "singleton:workspace-order".to_string()
            }
            ResourceChange::SetActiveWorkspace { .. } => "singleton:active-workspace".to_string(),
            ResourceChange::UpsertScreen(screen) => {
                let mut panes = HashSet::new();
                let mut splits = HashSet::new();
                validate_layout_node(&screen.layout, &mut panes, &mut splits)?;
                if !panes.contains(&screen.active_pane)
                    || screen.zoomed_pane.as_ref().is_some_and(|pane| !panes.contains(pane))
                {
                    anyhow::bail!("screen {} has invalid selection", screen.public_id);
                }
                format!("screen:{}", screen.public_id)
            }
            ResourceChange::TombstoneScreen { screen_id } => format!("screen:{screen_id}"),
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                validate_order_ids("screen", screen_ids.iter().map(|id| id.as_str()))?;
                format!("screen-order:{workspace_id}")
            }
            ResourceChange::UpsertPane(pane) => format!("pane:{}", pane.public_id),
            ResourceChange::TombstonePane { pane_id } => format!("pane:{pane_id}"),
            ResourceChange::UpsertTab(tab) => {
                match (&tab.content_id, &tab.browser_url) {
                    (ContentPublicId::Terminal(_), None)
                    | (ContentPublicId::Browser(_), Some(_)) => {}
                    (ContentPublicId::Terminal(_), Some(_)) => {
                        anyhow::bail!("terminal tab {} cannot carry a browser URL", tab.public_id)
                    }
                    (ContentPublicId::Browser(_), None) => {
                        anyhow::bail!("browser tab {} is missing its URL", tab.public_id)
                    }
                }
                format!("tab:{}", tab.public_id)
            }
            ResourceChange::TombstoneTab { tab_id } => format!("tab:{tab_id}"),
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                validate_order_ids("tab", tab_ids.iter().map(|id| id.as_str()))?;
                format!("tab-order:{pane_id}")
            }
            ResourceChange::UpsertTerminal { public_id, terminal } => {
                validate_terminal(terminal)?;
                if public_id.terminal_host_id() != terminal.terminal_id {
                    anyhow::bail!(
                        "terminal resource {} does not match host id {}",
                        public_id,
                        terminal.terminal_id
                    );
                }
                format!("terminal:{public_id}")
            }
            ResourceChange::TombstoneTerminal { public_id, expected_incarnation } => {
                if let Some(incarnation) = expected_incarnation {
                    validate_terminal_identity("terminal incarnation", incarnation)?;
                }
                format!("terminal:{public_id}")
            }
            ResourceChange::UpsertBrowser { public_id, .. }
            | ResourceChange::TombstoneBrowser { public_id } => {
                format!("browser:{public_id}")
            }
        };
        if target.starts_with("singleton:") {
            if !singleton_changes.insert(target.clone()) {
                anyhow::bail!("duplicate resource patch change: {target}");
            }
        } else if !targets.insert(target.clone()) {
            anyhow::bail!("resource patch changes {target} more than once");
        }
    }
    Ok(())
}

fn validate_order_ids<'a>(
    kind: &str,
    ids: impl IntoIterator<Item = &'a str>,
) -> anyhow::Result<()> {
    let mut seen = HashSet::new();
    if ids.into_iter().any(|id| !seen.insert(id)) {
        anyhow::bail!("{kind} order contains a duplicate id");
    }
    Ok(())
}

fn validate_layout_node<'a>(
    layout: &'a RegistryLayoutNode,
    panes: &mut HashSet<&'a PanePublicId>,
    splits: &mut HashSet<&'a SplitPublicId>,
) -> anyhow::Result<()> {
    match layout {
        RegistryLayoutNode::Leaf { pane } => {
            if !panes.insert(pane) {
                anyhow::bail!("pane {pane} appears twice in one layout");
            }
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => {
            if !splits.insert(split) {
                anyhow::bail!("duplicate split public id: {split}");
            }
            if !matches!(direction.as_str(), "right" | "down") {
                anyhow::bail!("invalid split direction {direction:?}");
            }
            if !ratio.is_finite() || !(0.0..1.0).contains(ratio) {
                anyhow::bail!("split {split} has invalid ratio {ratio}");
            }
            validate_layout_node(first, panes, splits)?;
            validate_layout_node(second, panes, splits)?;
        }
        RegistryLayoutNode::Stack { panes: members, expanded } => {
            if members.is_empty() || !members.contains(expanded) {
                anyhow::bail!("stack layout has invalid expanded pane");
            }
            for pane in members {
                if !panes.insert(pane) {
                    anyhow::bail!("pane {pane} appears twice in one layout");
                }
            }
        }
    }
    Ok(())
}

fn apply_resource_patch(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
    revision: i64,
) -> anyhow::Result<()> {
    validate_resource_order_coverage(transaction, patch)?;
    prepare_resource_order_slots(transaction, patch)?;

    // Explicit leaf closes run first so their positions can be reused by
    // additions in this patch. Parent closes run after upserts so a tab or
    // pane can move out of the closing parent without losing its identity.
    for change in &patch.changes {
        match change {
            ResourceChange::TombstoneTab { tab_id } => {
                tombstone_resource_tab(transaction, tab_id.as_str(), revision, true)?;
            }
            ResourceChange::TombstoneTerminal { public_id, expected_incarnation } => {
                tombstone_resource_terminal(
                    transaction,
                    public_id.as_str(),
                    expected_incarnation.as_deref(),
                    revision,
                )?;
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                tombstone_resource_browser(transaction, public_id.as_str(), revision)?;
            }
            _ => {}
        }
    }

    for change in &patch.changes {
        if let ResourceChange::UpsertWorkspace { workspace, position, active_screen } = change {
            upsert_resource_workspace(
                transaction,
                workspace,
                *position,
                active_screen.as_ref(),
                revision,
            )?;
        }
    }
    for change in &patch.changes {
        if let ResourceChange::UpsertScreen(screen) = change {
            upsert_resource_screen(transaction, screen, revision)?;
        }
    }
    for change in &patch.changes {
        if let ResourceChange::UpsertPane(pane) = change {
            upsert_resource_pane(transaction, pane, revision)?;
        }
    }
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertTerminal { public_id, terminal } => {
                upsert_resource_terminal(transaction, public_id, terminal, revision)?;
            }
            ResourceChange::UpsertBrowser { public_id, url } => {
                upsert_resource_browser(transaction, public_id, url, revision)?;
            }
            _ => {}
        }
    }
    for change in &patch.changes {
        if let ResourceChange::UpsertTab(tab) = change {
            upsert_resource_tab(transaction, tab, revision)?;
        }
    }

    for change in &patch.changes {
        match change {
            ResourceChange::TombstonePane { pane_id } => {
                tombstone_resource_pane(transaction, pane_id.as_str(), revision)?;
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                tombstone_resource_screen(transaction, screen_id.as_str(), revision)?;
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                tombstone_resource_workspace(transaction, workspace_id.as_str(), revision)?;
            }
            _ => {}
        }
    }

    for change in &patch.changes {
        match change {
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                set_resource_workspace_order(transaction, workspace_ids, revision)?;
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                set_resource_screen_order(transaction, workspace_id, screen_ids, revision)?;
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                set_resource_tab_order(transaction, pane_id, tab_ids, revision)?;
            }
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                set_active_resource_workspace(transaction, workspace_id.as_ref())?;
            }
            _ => {}
        }
    }

    validate_touched_resource_invariants(transaction, patch)
}

fn validate_resource_order_coverage(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let workspace_order = patch
        .changes
        .iter()
        .any(|change| matches!(change, ResourceChange::SetWorkspaceOrder { .. }));
    let screen_orders = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::SetScreenOrder { workspace_id, .. } => Some(workspace_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let tab_orders = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::SetTabOrder { pane_id, .. } => Some(pane_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let closing_workspaces = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneWorkspace { workspace_id } => Some(workspace_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let closing_screens = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstoneScreen { screen_id } => Some(screen_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();
    let closing_panes = patch
        .changes
        .iter()
        .filter_map(|change| match change {
            ResourceChange::TombstonePane { pane_id } => Some(pane_id.as_str()),
            _ => None,
        })
        .collect::<HashSet<_>>();

    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, position, .. } => {
                let stored_position = transaction
                    .query_row(
                        "SELECT position FROM workspaces
                         WHERE workspace_key = ?1 AND tombstoned = 0",
                        [&workspace.key],
                        |row| row.get::<_, i64>(0),
                    )
                    .optional()?;
                let desired =
                    i64::try_from(*position).context("workspace position exceeds SQLite range")?;
                if stored_position != Some(desired) && !workspace_order {
                    anyhow::bail!(
                        "creating or moving workspace {} requires SetWorkspaceOrder",
                        workspace.public_id
                    );
                }
            }
            ResourceChange::TombstoneWorkspace { .. } if !workspace_order => {
                anyhow::bail!("closing a workspace requires SetWorkspaceOrder");
            }
            ResourceChange::UpsertScreen(screen) => {
                let stored = transaction
                    .query_row(
                        "SELECT workspace_id, position FROM resource_screens
                         WHERE public_id = ?1 AND deleted_revision IS NULL",
                        [screen.public_id.as_str()],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
                    )
                    .optional()?;
                let desired_position = i64::try_from(screen.position)
                    .context("screen position exceeds SQLite range")?;
                if stored.as_ref().is_none_or(|(workspace, position)| {
                    workspace != screen.workspace_id.as_str() || *position != desired_position
                }) {
                    if !screen_orders.contains(screen.workspace_id.as_str()) {
                        anyhow::bail!(
                            "creating or moving screen {} requires SetScreenOrder for {}",
                            screen.public_id,
                            screen.workspace_id
                        );
                    }
                    if let Some((old_workspace, _)) = stored
                        && old_workspace != screen.workspace_id.as_str()
                        && !closing_workspaces.contains(old_workspace.as_str())
                        && !screen_orders.contains(old_workspace.as_str())
                    {
                        anyhow::bail!(
                            "moving screen {} requires SetScreenOrder for old workspace {}",
                            screen.public_id,
                            old_workspace
                        );
                    }
                }
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                if let Some(workspace_id) = resource_field_any(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    screen_id.as_str(),
                )? && !closing_workspaces.contains(workspace_id.as_str())
                    && !screen_orders.contains(workspace_id.as_str())
                {
                    anyhow::bail!(
                        "closing screen {screen_id} requires SetScreenOrder for {workspace_id}"
                    );
                }
            }
            ResourceChange::UpsertTab(tab) => {
                let stored = transaction
                    .query_row(
                        "SELECT pane_id, position FROM resource_tabs
                         WHERE public_id = ?1 AND deleted_revision IS NULL",
                        [tab.public_id.as_str()],
                        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
                    )
                    .optional()?;
                let desired_position =
                    i64::try_from(tab.position).context("tab position exceeds SQLite range")?;
                if stored.as_ref().is_none_or(|(pane, position)| {
                    pane != tab.pane_id.as_str() || *position != desired_position
                }) {
                    if !pane_closes_in_patch(
                        transaction,
                        tab.pane_id.as_str(),
                        &closing_panes,
                        &closing_screens,
                        &closing_workspaces,
                    )? && !tab_orders.contains(tab.pane_id.as_str())
                    {
                        anyhow::bail!(
                            "creating or moving tab {} requires SetTabOrder for {}",
                            tab.public_id,
                            tab.pane_id
                        );
                    }
                    if let Some((old_pane, _)) = stored
                        && old_pane != tab.pane_id.as_str()
                        && !pane_closes_in_patch(
                            transaction,
                            &old_pane,
                            &closing_panes,
                            &closing_screens,
                            &closing_workspaces,
                        )?
                        && !tab_orders.contains(old_pane.as_str())
                    {
                        anyhow::bail!(
                            "moving tab {} requires SetTabOrder for old pane {}",
                            tab.public_id,
                            old_pane
                        );
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id } => {
                if let Some(pane_id) =
                    resource_field_any(transaction, "resource_tabs", "pane_id", tab_id.as_str())?
                    && !pane_closes_in_patch(
                        transaction,
                        &pane_id,
                        &closing_panes,
                        &closing_screens,
                        &closing_workspaces,
                    )?
                    && !tab_orders.contains(pane_id.as_str())
                {
                    anyhow::bail!("closing tab {tab_id} requires SetTabOrder for pane {pane_id}");
                }
            }
            ResourceChange::TombstoneTerminal { public_id, .. } => {
                require_content_tab_order(
                    transaction,
                    public_id.as_str(),
                    &tab_orders,
                    &closing_panes,
                    &closing_screens,
                    &closing_workspaces,
                )?;
            }
            ResourceChange::TombstoneBrowser { public_id } => {
                require_content_tab_order(
                    transaction,
                    public_id.as_str(),
                    &tab_orders,
                    &closing_panes,
                    &closing_screens,
                    &closing_workspaces,
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn require_content_tab_order(
    transaction: &Transaction<'_>,
    content_id: &str,
    tab_orders: &HashSet<&str>,
    closing_panes: &HashSet<&str>,
    closing_screens: &HashSet<&str>,
    closing_workspaces: &HashSet<&str>,
) -> anyhow::Result<()> {
    let pane_ids = {
        let mut statement = transaction.prepare(
            "SELECT pane_id FROM resource_tabs
             WHERE content_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([content_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for pane_id in pane_ids {
        if !pane_closes_in_patch(
            transaction,
            &pane_id,
            closing_panes,
            closing_screens,
            closing_workspaces,
        )? && !tab_orders.contains(pane_id.as_str())
        {
            anyhow::bail!("closing content {content_id} requires SetTabOrder for pane {pane_id}");
        }
    }
    Ok(())
}

fn pane_closes_in_patch(
    transaction: &Transaction<'_>,
    pane_id: &str,
    closing_panes: &HashSet<&str>,
    closing_screens: &HashSet<&str>,
    closing_workspaces: &HashSet<&str>,
) -> anyhow::Result<bool> {
    if closing_panes.contains(pane_id) {
        return Ok(true);
    }
    let Some(screen_id) = resource_field_any(transaction, "resource_panes", "screen_id", pane_id)?
    else {
        return Ok(false);
    };
    if closing_screens.contains(screen_id.as_str()) {
        return Ok(true);
    }
    let workspace_id =
        resource_field_any(transaction, "resource_screens", "workspace_id", &screen_id)?;
    Ok(workspace_id.is_some_and(|workspace| closing_workspaces.contains(workspace.as_str())))
}

fn resource_field_any(
    transaction: &Transaction<'_>,
    table: &str,
    field: &str,
    public_id: &str,
) -> anyhow::Result<Option<String>> {
    let query = format!("SELECT {field} FROM {table} WHERE public_id = ?1");
    Ok(transaction.query_row(&query, [public_id], |row| row.get::<_, String>(0)).optional()?)
}

fn prepare_resource_order_slots(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    for change in &patch.changes {
        match change {
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                let desired = workspace_ids
                    .iter()
                    .enumerate()
                    .map(|(position, id)| (id.as_str(), position))
                    .collect::<HashMap<_, _>>();
                let current = {
                    let mut statement = transaction.prepare(
                        "SELECT rw.public_id, w.workspace_key, w.position
                         FROM workspaces w
                         JOIN resource_workspaces rw ON rw.workspace_key = w.workspace_key
                         WHERE w.tombstoned = 0 AND rw.deleted_revision IS NULL",
                    )?;
                    statement
                        .query_map([], |row| {
                            Ok((
                                row.get::<_, String>(0)?,
                                row.get::<_, String>(1)?,
                                row.get::<_, i64>(2)?,
                            ))
                        })?
                        .collect::<Result<Vec<_>, _>>()?
                };
                for (public_id, workspace_key, position) in current {
                    let unchanged = desired
                        .get(public_id.as_str())
                        .and_then(|position| i64::try_from(*position).ok())
                        == Some(position);
                    if !unchanged {
                        transaction.execute(
                            "UPDATE workspaces SET position = -rowid
                             WHERE workspace_key = ?1 AND tombstoned = 0",
                            [&workspace_key],
                        )?;
                    }
                }
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                prepare_child_order_slots(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    workspace_id.as_str(),
                    screen_ids.iter().map(ScreenPublicId::as_str),
                )?;
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                prepare_child_order_slots(
                    transaction,
                    "resource_tabs",
                    "pane_id",
                    pane_id.as_str(),
                    tab_ids.iter().map(TabPublicId::as_str),
                )?;
            }
            _ => {}
        }
    }
    Ok(())
}

fn prepare_child_order_slots<'a>(
    transaction: &Transaction<'_>,
    table: &str,
    parent_field: &str,
    parent_id: &str,
    desired_ids: impl IntoIterator<Item = &'a str>,
) -> anyhow::Result<()> {
    let desired = desired_ids
        .into_iter()
        .enumerate()
        .map(|(position, id)| (id, position))
        .collect::<HashMap<_, _>>();
    let query = format!(
        "SELECT public_id, position FROM {table}
         WHERE {parent_field} = ?1 AND deleted_revision IS NULL"
    );
    let current = {
        let mut statement = transaction.prepare(&query)?;
        statement
            .query_map([parent_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (public_id, position) in current {
        let unchanged =
            desired.get(public_id.as_str()).and_then(|position| i64::try_from(*position).ok())
                == Some(position);
        if !unchanged {
            transaction.execute(
                &format!(
                    "UPDATE {table} SET position = -rowid
                     WHERE public_id = ?1 AND deleted_revision IS NULL"
                ),
                [&public_id],
            )?;
        }
    }
    Ok(())
}

fn upsert_resource_workspace(
    transaction: &Transaction<'_>,
    workspace: &RegistryWorkspace,
    position: usize,
    active_screen: Option<&ScreenPublicId>,
    revision: i64,
) -> anyhow::Result<()> {
    upsert_workspace_resource(transaction, workspace, revision)?;
    let position = i64::try_from(position).context("workspace position exceeds SQLite range")?;
    transaction.execute(
        "INSERT INTO workspaces(
           workspace_key, numeric_id, name, group_key, position, tombstoned,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, NULL)
         ON CONFLICT(workspace_key) DO UPDATE SET
           numeric_id=excluded.numeric_id,
           name=excluded.name,
           group_key=excluded.group_key,
           position=excluded.position,
           updated_revision=excluded.updated_revision",
        params![
            workspace.key,
            i64::try_from(workspace.id).context("workspace id exceeds SQLite range")?,
            workspace.name,
            workspace.group_key,
            position,
            revision,
        ],
    )?;
    transaction.execute(
        "UPDATE resource_workspaces
         SET active_screen_id = ?1, updated_revision = ?2
         WHERE public_id = ?3 AND deleted_revision IS NULL",
        params![active_screen.map(ScreenPublicId::as_str), revision, workspace.public_id.as_str(),],
    )?;
    Ok(())
}

fn upsert_resource_screen(
    transaction: &Transaction<'_>,
    screen: &RegistryScreen,
    revision: i64,
) -> anyhow::Result<()> {
    let old_splits = transaction
        .query_row(
            "SELECT layout_json FROM resource_screens WHERE public_id = ?1",
            [screen.public_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .optional()?
        .map(|layout| {
            let layout: RegistryLayoutNode = serde_json::from_str(&layout)?;
            let mut splits = Vec::new();
            collect_split_public_ids(&layout, &mut splits);
            Ok::<_, anyhow::Error>(splits)
        })
        .transpose()?
        .unwrap_or_default();
    upsert_resource_identity(transaction, screen.public_id.as_str(), "screen", revision)?;
    let mut desired_splits = Vec::new();
    collect_split_public_ids(&screen.layout, &mut desired_splits);
    for split in &desired_splits {
        upsert_resource_identity(transaction, split, "split", revision)?;
    }
    let desired_splits = desired_splits.into_iter().collect::<HashSet<_>>();
    for split in old_splits {
        if !desired_splits.contains(&split) {
            tombstone_resource_identity(transaction, &split, revision)?;
        }
    }
    let layout = canonical_json(&serde_json::to_value(&screen.layout)?)?;
    let auto_layout = screen
        .auto_layout
        .as_ref()
        .map(|value| canonical_json(&serde_json::to_value(value)?))
        .transpose()?;
    let viewport = canonical_json(&screen.viewport)?;
    transaction.execute(
        "INSERT INTO resource_screens(
           public_id, workspace_id, position, name, layout_json, active_pane_id,
           zoomed_pane_id, auto_layout_json, viewport_json,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           workspace_id=excluded.workspace_id,
           position=excluded.position,
           name=excluded.name,
           layout_json=excluded.layout_json,
           active_pane_id=excluded.active_pane_id,
           zoomed_pane_id=excluded.zoomed_pane_id,
           auto_layout_json=excluded.auto_layout_json,
           viewport_json=excluded.viewport_json,
           updated_revision=excluded.updated_revision",
        params![
            screen.public_id.as_str(),
            screen.workspace_id.as_str(),
            i64::try_from(screen.position).context("screen position exceeds SQLite range")?,
            screen.name,
            layout,
            screen.active_pane.as_str(),
            screen.zoomed_pane.as_ref().map(PanePublicId::as_str),
            auto_layout,
            viewport,
            revision,
        ],
    )?;
    Ok(())
}

fn upsert_resource_pane(
    transaction: &Transaction<'_>,
    pane: &RegistryPane,
    revision: i64,
) -> anyhow::Result<()> {
    upsert_resource_identity(transaction, pane.public_id.as_str(), "pane", revision)?;
    transaction.execute(
        "INSERT INTO resource_panes(
           public_id, screen_id, name, active_tab_id, creation_ordinal,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           screen_id=excluded.screen_id,
           name=excluded.name,
           active_tab_id=excluded.active_tab_id,
           creation_ordinal=excluded.creation_ordinal,
           updated_revision=excluded.updated_revision",
        params![
            pane.public_id.as_str(),
            pane.screen_id.as_str(),
            pane.name,
            pane.active_tab.as_ref().map(TabPublicId::as_str),
            i64::try_from(pane.creation_ordinal)
                .context("pane creation ordinal exceeds SQLite range")?,
            revision,
        ],
    )?;
    Ok(())
}

fn upsert_resource_tab(
    transaction: &Transaction<'_>,
    tab: &RegistryTab,
    revision: i64,
) -> anyhow::Result<()> {
    upsert_resource_identity(transaction, tab.public_id.as_str(), "tab", revision)?;
    let (content_kind, content_id) = match &tab.content_id {
        ContentPublicId::Terminal(id) => ("terminal", id.as_str()),
        ContentPublicId::Browser(id) => ("browser", id.as_str()),
    };
    let concrete_table = match content_kind {
        "terminal" => "resource_terminals",
        "browser" => "resource_browsers",
        _ => unreachable!("content kind is exhaustive"),
    };
    if live_resource_field(transaction, concrete_table, "public_id", content_id)?.is_none() {
        anyhow::bail!("tab {} references unknown {content_kind} {content_id}", tab.public_id);
    }
    if let (ContentPublicId::Browser(_), Some(expected_url)) = (&tab.content_id, &tab.browser_url) {
        let stored_url = live_resource_field(transaction, "resource_browsers", "url", content_id)?;
        if stored_url.as_deref() != Some(expected_url.as_str()) {
            anyhow::bail!(
                "tab {} browser URL does not match browser {}",
                tab.public_id,
                content_id
            );
        }
    }
    if let Some((stored_kind, stored_id)) = transaction
        .query_row(
            "SELECT content_kind, content_id FROM resource_tabs WHERE public_id = ?1",
            [tab.public_id.as_str()],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?
        && (stored_kind != content_kind || stored_id != content_id)
    {
        anyhow::bail!("tab {} cannot change its content identity", tab.public_id);
    }
    transaction.execute(
        "INSERT INTO resource_tabs(
           public_id, pane_id, position, content_kind, content_id, name,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           pane_id=excluded.pane_id,
           position=excluded.position,
           name=excluded.name,
           updated_revision=excluded.updated_revision",
        params![
            tab.public_id.as_str(),
            tab.pane_id.as_str(),
            i64::try_from(tab.position).context("tab position exceeds SQLite range")?,
            content_kind,
            content_id,
            tab.name,
            revision,
        ],
    )?;
    Ok(())
}

fn upsert_resource_terminal(
    transaction: &Transaction<'_>,
    public_id: &TerminalPublicId,
    terminal: &RegistryTerminal,
    revision: i64,
) -> anyhow::Result<()> {
    let existing = read_terminal(transaction, &terminal.terminal_id)?;
    validate_terminal_transition(existing.as_ref(), terminal)?;
    if terminal.lifecycle != TerminalLifecycle::Tombstoned {
        require_live_workspace(transaction, &terminal.workspace_key)?;
    }
    let launch_spec = canonical_json(&terminal.launch_spec)?;
    if launch_spec.len() > MAX_LAUNCH_SPEC_BYTES {
        anyhow::bail!("terminal launch spec exceeds {MAX_LAUNCH_SPEC_BYTES} bytes");
    }
    let exit = terminal.exit.as_ref().map(canonical_json).transpose()?;
    upsert_resource_identity(transaction, public_id.as_str(), "terminal", revision)?;
    transaction.execute(
        "INSERT INTO resource_terminals(
           public_id, terminal_id, lifecycle,
           created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, 'active', ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           lifecycle='active',
           updated_revision=excluded.updated_revision",
        params![public_id.as_str(), terminal.terminal_id, revision],
    )?;
    if existing.as_ref().is_some_and(|stored| {
        stored.lifecycle == TerminalLifecycle::Exited
            && terminal.lifecycle == TerminalLifecycle::Exited
    }) {
        if existing.as_ref().and_then(|stored| stored.incarnation.as_deref())
            != terminal.incarnation.as_deref()
        {
            anyhow::bail!("terminal_incarnation_mismatch");
        }
        return Ok(());
    }
    transaction.execute(
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
            launch_spec,
            exit,
            revision,
            (terminal.lifecycle == TerminalLifecycle::Tombstoned).then_some(revision),
        ],
    )?;
    Ok(())
}

fn upsert_resource_browser(
    transaction: &Transaction<'_>,
    public_id: &BrowserPublicId,
    url: &str,
    revision: i64,
) -> anyhow::Result<()> {
    if url.is_empty() {
        anyhow::bail!("browser URL cannot be empty");
    }
    upsert_resource_identity(transaction, public_id.as_str(), "browser", revision)?;
    transaction.execute(
        "INSERT INTO resource_browsers(
           public_id, url, lifecycle, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, 'running', ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET
           url=excluded.url,
           lifecycle='running',
           updated_revision=excluded.updated_revision",
        params![public_id.as_str(), url, revision],
    )?;
    Ok(())
}

fn tombstone_resource_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    let Some(workspace_key) =
        live_resource_field(transaction, "resource_workspaces", "workspace_key", workspace_id)?
    else {
        require_known_resource(transaction, workspace_id, "workspace")?;
        return Ok(());
    };
    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_screens
             WHERE workspace_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([workspace_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for screen in screens {
        tombstone_resource_screen(transaction, &screen, revision)?;
    }

    let terminal_ids = {
        let mut statement = transaction.prepare(
            "SELECT terminal_id FROM terminal_placements
             WHERE workspace_key = ?1 AND lifecycle != 'tombstoned'",
        )?;
        statement
            .query_map([&workspace_key], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for terminal_id in terminal_ids {
        let public_id = TerminalPublicId::from_terminal_host_id(&terminal_id)?;
        let is_resource_terminal = transaction
            .query_row(
                "SELECT 1 FROM resource_terminals WHERE public_id = ?1",
                [public_id.as_str()],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if is_resource_terminal {
            tombstone_resource_terminal(transaction, public_id.as_str(), None, revision)?;
        } else {
            transaction.execute(
                "UPDATE terminal_placements
                 SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
                 WHERE terminal_id = ?2 AND lifecycle != 'tombstoned'",
                params![revision, terminal_id],
            )?;
        }
    }
    transaction.execute(
        "UPDATE resource_workspaces
         SET active_screen_id = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, workspace_id],
    )?;
    transaction.execute(
        "UPDATE workspaces
         SET position = NULL, tombstoned = 1, updated_revision = ?1, deleted_revision = ?1
         WHERE workspace_key = ?2 AND tombstoned = 0",
        params![revision, workspace_key],
    )?;
    tombstone_resource_identity(transaction, workspace_id, revision)?;
    if meta_value(transaction, "active_workspace_id")?.as_deref() == Some(workspace_id) {
        transaction.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
    }
    Ok(())
}

fn tombstone_resource_screen(
    transaction: &Transaction<'_>,
    screen_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    let Some(layout_json) =
        live_resource_field(transaction, "resource_screens", "layout_json", screen_id)?
    else {
        require_known_resource(transaction, screen_id, "screen")?;
        return Ok(());
    };
    let panes = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_panes
             WHERE screen_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([screen_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for pane in panes {
        tombstone_resource_pane(transaction, &pane, revision)?;
    }
    let layout: RegistryLayoutNode = serde_json::from_str(&layout_json)?;
    let mut splits = Vec::new();
    collect_split_public_ids(&layout, &mut splits);
    for split in splits {
        tombstone_resource_identity(transaction, &split, revision)?;
    }
    transaction.execute(
        "UPDATE resource_screens
         SET position = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, screen_id],
    )?;
    transaction.execute(
        "UPDATE resource_workspaces
         SET active_screen_id = NULL, updated_revision = ?1
         WHERE active_screen_id = ?2 AND deleted_revision IS NULL",
        params![revision, screen_id],
    )?;
    tombstone_resource_identity(transaction, screen_id, revision)
}

fn tombstone_resource_pane(
    transaction: &Transaction<'_>,
    pane_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    if live_resource_field(transaction, "resource_panes", "screen_id", pane_id)?.is_none() {
        require_known_resource(transaction, pane_id, "pane")?;
        return Ok(());
    }
    let tabs = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_tabs
             WHERE pane_id = ?1 AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([pane_id], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for tab in tabs {
        tombstone_resource_tab(transaction, &tab, revision, true)?;
    }
    transaction.execute(
        "UPDATE resource_panes
         SET active_tab_id = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, pane_id],
    )?;
    tombstone_resource_identity(transaction, pane_id, revision)
}

fn tombstone_resource_tab(
    transaction: &Transaction<'_>,
    tab_id: &str,
    revision: i64,
    close_content: bool,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT content_kind, content_id FROM resource_tabs
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [tab_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?;
    let Some((content_kind, content_id)) = stored else {
        require_known_resource(transaction, tab_id, "tab")?;
        return Ok(());
    };
    transaction.execute(
        "UPDATE resource_tabs
         SET position = NULL, updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, tab_id],
    )?;
    transaction.execute(
        "UPDATE resource_panes
         SET active_tab_id = NULL, updated_revision = ?1
         WHERE active_tab_id = ?2 AND deleted_revision IS NULL",
        params![revision, tab_id],
    )?;
    tombstone_resource_identity(transaction, tab_id, revision)?;
    if close_content {
        match content_kind.as_str() {
            "terminal" => {
                tombstone_resource_terminal(transaction, &content_id, None, revision)?;
            }
            "browser" => tombstone_resource_browser(transaction, &content_id, revision)?,
            other => anyhow::bail!("stored tab {tab_id} has invalid content kind {other:?}"),
        }
    }
    Ok(())
}

fn tombstone_resource_terminal(
    transaction: &Transaction<'_>,
    public_id: &str,
    expected_incarnation: Option<&str>,
    revision: i64,
) -> anyhow::Result<()> {
    let terminal_id = transaction
        .query_row(
            "SELECT terminal_id FROM resource_terminals WHERE public_id = ?1",
            [public_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    let Some(terminal_id) = terminal_id else {
        require_known_resource(transaction, public_id, "terminal")?;
        return Ok(());
    };
    let terminal = read_terminal(transaction, &terminal_id)?;
    if let Some(expected) = expected_incarnation
        && terminal.as_ref().and_then(|stored| stored.incarnation.as_deref()) != Some(expected)
    {
        anyhow::bail!("terminal_incarnation_mismatch");
    }
    let tabs = live_tabs_for_content(transaction, public_id)?;
    for tab in tabs {
        tombstone_resource_tab(transaction, &tab, revision, false)?;
    }
    transaction.execute(
        "UPDATE resource_terminals
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, public_id],
    )?;
    transaction.execute(
        "UPDATE terminal_placements
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE terminal_id = ?2 AND lifecycle != 'tombstoned'",
        params![revision, terminal_id],
    )?;
    tombstone_resource_identity(transaction, public_id, revision)
}

fn tombstone_resource_browser(
    transaction: &Transaction<'_>,
    public_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    let known = transaction
        .query_row("SELECT 1 FROM resource_browsers WHERE public_id = ?1", [public_id], |_| Ok(()))
        .optional()?;
    if known.is_none() {
        require_known_resource(transaction, public_id, "browser")?;
        return Ok(());
    }
    let tabs = live_tabs_for_content(transaction, public_id)?;
    for tab in tabs {
        tombstone_resource_tab(transaction, &tab, revision, false)?;
    }
    transaction.execute(
        "UPDATE resource_browsers
         SET lifecycle = 'tombstoned', updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, public_id],
    )?;
    tombstone_resource_identity(transaction, public_id, revision)
}

fn live_tabs_for_content(
    transaction: &Transaction<'_>,
    content_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = transaction.prepare(
        "SELECT public_id FROM resource_tabs
         WHERE content_id = ?1 AND deleted_revision IS NULL",
    )?;
    Ok(statement
        .query_map([content_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?)
}

fn live_resource_field(
    transaction: &Transaction<'_>,
    table: &str,
    field: &str,
    public_id: &str,
) -> anyhow::Result<Option<String>> {
    let query =
        format!("SELECT {field} FROM {table} WHERE public_id = ?1 AND deleted_revision IS NULL");
    Ok(transaction.query_row(&query, [public_id], |row| row.get::<_, String>(0)).optional()?)
}

fn require_known_resource(
    transaction: &Transaction<'_>,
    public_id: &str,
    expected_kind: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT kind FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    match stored.as_deref() {
        Some(kind) if kind == expected_kind => Ok(()),
        Some(kind) => anyhow::bail!("public id {public_id} has resource kind {kind}"),
        None => anyhow::bail!("unknown {expected_kind} resource {public_id}"),
    }
}

fn tombstone_resource_identity(
    transaction: &Transaction<'_>,
    public_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE resource_identities
         SET updated_revision = ?1, deleted_revision = ?1
         WHERE public_id = ?2 AND deleted_revision IS NULL",
        params![revision, public_id],
    )?;
    Ok(())
}

fn set_resource_workspace_order(
    transaction: &Transaction<'_>,
    workspace_ids: &[WorkspacePublicId],
    revision: i64,
) -> anyhow::Result<()> {
    let live = {
        let mut statement = transaction.prepare(
            "SELECT rw.public_id
             FROM resource_workspaces rw
             JOIN workspaces w ON w.workspace_key = rw.workspace_key
             WHERE rw.deleted_revision IS NULL AND w.tombstoned = 0",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    require_exact_order_set(
        "workspace",
        &live,
        workspace_ids.iter().map(WorkspacePublicId::as_str),
    )?;
    for (position, workspace_id) in workspace_ids.iter().enumerate() {
        transaction.execute(
            "UPDATE workspaces
             SET position = ?1, updated_revision = ?2
             WHERE workspace_key = (
               SELECT workspace_key FROM resource_workspaces
               WHERE public_id = ?3 AND deleted_revision IS NULL
             ) AND tombstoned = 0 AND position != ?1",
            params![
                i64::try_from(position).context("workspace position exceeds SQLite range")?,
                revision,
                workspace_id.as_str(),
            ],
        )?;
    }
    Ok(())
}

fn set_resource_screen_order(
    transaction: &Transaction<'_>,
    workspace_id: &WorkspacePublicId,
    screen_ids: &[ScreenPublicId],
    revision: i64,
) -> anyhow::Result<()> {
    let live =
        resource_children(transaction, "resource_screens", "workspace_id", workspace_id.as_str())?;
    require_exact_order_set("screen", &live, screen_ids.iter().map(ScreenPublicId::as_str))?;
    for (position, screen_id) in screen_ids.iter().enumerate() {
        transaction.execute(
            "UPDATE resource_screens
             SET position = ?1, updated_revision = ?2
             WHERE public_id = ?3 AND workspace_id = ?4
               AND deleted_revision IS NULL AND position != ?1",
            params![
                i64::try_from(position).context("screen position exceeds SQLite range")?,
                revision,
                screen_id.as_str(),
                workspace_id.as_str(),
            ],
        )?;
    }
    Ok(())
}

fn set_resource_tab_order(
    transaction: &Transaction<'_>,
    pane_id: &PanePublicId,
    tab_ids: &[TabPublicId],
    revision: i64,
) -> anyhow::Result<()> {
    let live = resource_children(transaction, "resource_tabs", "pane_id", pane_id.as_str())?;
    require_exact_order_set("tab", &live, tab_ids.iter().map(TabPublicId::as_str))?;
    for (position, tab_id) in tab_ids.iter().enumerate() {
        transaction.execute(
            "UPDATE resource_tabs
             SET position = ?1, updated_revision = ?2
             WHERE public_id = ?3 AND pane_id = ?4
               AND deleted_revision IS NULL AND position != ?1",
            params![
                i64::try_from(position).context("tab position exceeds SQLite range")?,
                revision,
                tab_id.as_str(),
                pane_id.as_str(),
            ],
        )?;
    }
    Ok(())
}

fn resource_children(
    transaction: &Transaction<'_>,
    table: &str,
    parent_field: &str,
    parent_id: &str,
) -> anyhow::Result<HashSet<String>> {
    let query = format!(
        "SELECT public_id FROM {table}
         WHERE {parent_field} = ?1 AND deleted_revision IS NULL"
    );
    let mut statement = transaction.prepare(&query)?;
    Ok(statement
        .query_map([parent_id], |row| row.get::<_, String>(0))?
        .collect::<Result<HashSet<_>, _>>()?)
}

fn require_exact_order_set<'a>(
    kind: &str,
    live: &HashSet<String>,
    requested: impl IntoIterator<Item = &'a str>,
) -> anyhow::Result<()> {
    let requested = requested.into_iter().collect::<HashSet<_>>();
    if live.len() != requested.len() || live.iter().any(|id| !requested.contains(id.as_str())) {
        anyhow::bail!("{kind} order must contain every live sibling exactly once");
    }
    Ok(())
}

fn set_active_resource_workspace(
    transaction: &Transaction<'_>,
    workspace_id: Option<&WorkspacePublicId>,
) -> anyhow::Result<()> {
    if let Some(workspace_id) = workspace_id {
        transaction.execute(
            "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [workspace_id.as_str()],
        )?;
    } else {
        transaction.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
    }
    Ok(())
}

fn validate_touched_resource_invariants(
    transaction: &Transaction<'_>,
    patch: &ResourcePatch,
) -> anyhow::Result<()> {
    let mut workspaces = HashSet::<String>::new();
    let mut screens = HashSet::<String>::new();
    let mut panes = HashSet::<String>::new();
    let mut tabs = HashSet::<String>::new();
    let mut terminals = HashSet::<String>::new();
    let mut browsers = HashSet::<String>::new();

    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, active_screen, .. } => {
                workspaces.insert(workspace.public_id.to_string());
                if let Some(screen) = active_screen {
                    screens.insert(screen.to_string());
                }
            }
            ResourceChange::TombstoneWorkspace { workspace_id } => {
                workspaces.insert(workspace_id.to_string());
            }
            ResourceChange::SetWorkspaceOrder { workspace_ids } => {
                workspaces.extend(workspace_ids.iter().map(ToString::to_string));
            }
            ResourceChange::SetActiveWorkspace { workspace_id } => {
                if let Some(workspace) = workspace_id {
                    workspaces.insert(workspace.to_string());
                }
            }
            ResourceChange::UpsertScreen(screen) => {
                screens.insert(screen.public_id.to_string());
                workspaces.insert(screen.workspace_id.to_string());
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                screens.insert(screen_id.to_string());
                if let Some(workspace) = resource_field_any(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    screen_id.as_str(),
                )? {
                    workspaces.insert(workspace);
                }
            }
            ResourceChange::SetScreenOrder { workspace_id, screen_ids } => {
                workspaces.insert(workspace_id.to_string());
                screens.extend(screen_ids.iter().map(ToString::to_string));
            }
            ResourceChange::UpsertPane(pane) => {
                panes.insert(pane.public_id.to_string());
                screens.insert(pane.screen_id.to_string());
            }
            ResourceChange::TombstonePane { pane_id } => {
                panes.insert(pane_id.to_string());
                if let Some(screen) = resource_field_any(
                    transaction,
                    "resource_panes",
                    "screen_id",
                    pane_id.as_str(),
                )? {
                    screens.insert(screen);
                }
            }
            ResourceChange::UpsertTab(tab) => {
                tabs.insert(tab.public_id.to_string());
                panes.insert(tab.pane_id.to_string());
                match &tab.content_id {
                    ContentPublicId::Terminal(id) => {
                        terminals.insert(id.to_string());
                    }
                    ContentPublicId::Browser(id) => {
                        browsers.insert(id.to_string());
                    }
                }
            }
            ResourceChange::TombstoneTab { tab_id } => {
                tabs.insert(tab_id.to_string());
                collect_stored_tab_scope(
                    transaction,
                    tab_id.as_str(),
                    &mut panes,
                    &mut terminals,
                    &mut browsers,
                )?;
            }
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                panes.insert(pane_id.to_string());
                tabs.extend(tab_ids.iter().map(ToString::to_string));
            }
            ResourceChange::UpsertTerminal { public_id, .. }
            | ResourceChange::TombstoneTerminal { public_id, .. } => {
                terminals.insert(public_id.to_string());
                collect_content_tab_scope(transaction, public_id.as_str(), &mut tabs, &mut panes)?;
            }
            ResourceChange::UpsertBrowser { public_id, .. }
            | ResourceChange::TombstoneBrowser { public_id } => {
                browsers.insert(public_id.to_string());
                collect_content_tab_scope(transaction, public_id.as_str(), &mut tabs, &mut panes)?;
            }
        }
    }

    for workspace in &workspaces {
        validate_touched_workspace(transaction, workspace)?;
    }
    for screen in &screens {
        validate_touched_screen(transaction, screen)?;
    }
    for pane in &panes {
        validate_touched_pane(transaction, pane)?;
    }
    for tab in &tabs {
        validate_touched_tab(transaction, tab)?;
    }
    for terminal in &terminals {
        validate_touched_terminal(transaction, terminal)?;
    }
    for browser in &browsers {
        validate_touched_browser(transaction, browser)?;
    }

    for change in &patch.changes {
        match change {
            ResourceChange::SetWorkspaceOrder { .. } => validate_contiguous_positions(
                transaction,
                "SELECT '' AS parent, position FROM workspaces
                 WHERE tombstoned = 0 ORDER BY position ASC",
                "workspace",
            )?,
            ResourceChange::SetScreenOrder { workspace_id, .. } => {
                validate_positions_for_parent(
                    transaction,
                    "resource_screens",
                    "workspace_id",
                    workspace_id.as_str(),
                    "screen",
                )?;
            }
            ResourceChange::SetTabOrder { pane_id, .. } => {
                validate_positions_for_parent(
                    transaction,
                    "resource_tabs",
                    "pane_id",
                    pane_id.as_str(),
                    "tab",
                )?;
            }
            _ => {}
        }
    }
    if let Some(active_workspace) = meta_value(transaction, "active_workspace_id")? {
        if live_resource_field(transaction, "resource_workspaces", "public_id", &active_workspace)?
            .is_none()
        {
            anyhow::bail!("active workspace {active_workspace} is not live");
        }
    }
    Ok(())
}

fn collect_stored_tab_scope(
    transaction: &Transaction<'_>,
    tab_id: &str,
    panes: &mut HashSet<String>,
    terminals: &mut HashSet<String>,
    browsers: &mut HashSet<String>,
) -> anyhow::Result<()> {
    if let Some((pane, kind, content)) = transaction
        .query_row(
            "SELECT pane_id, content_kind, content_id
             FROM resource_tabs WHERE public_id = ?1",
            [tab_id],
            |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            },
        )
        .optional()?
    {
        panes.insert(pane);
        match kind.as_str() {
            "terminal" => {
                terminals.insert(content);
            }
            "browser" => {
                browsers.insert(content);
            }
            other => anyhow::bail!("stored tab {tab_id} has invalid content kind {other:?}"),
        }
    }
    Ok(())
}

fn collect_content_tab_scope(
    transaction: &Transaction<'_>,
    content_id: &str,
    tabs: &mut HashSet<String>,
    panes: &mut HashSet<String>,
) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction
            .prepare("SELECT public_id, pane_id FROM resource_tabs WHERE content_id = ?1")?;
        statement
            .query_map([content_id], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (tab, pane) in rows {
        tabs.insert(tab);
        panes.insert(pane);
    }
    Ok(())
}

fn validate_touched_workspace(
    transaction: &Transaction<'_>,
    workspace_id: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT workspace_key, active_screen_id, deleted_revision
             FROM resource_workspaces WHERE public_id = ?1",
            [workspace_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((workspace_key, active_screen, deleted)) = stored else {
        anyhow::bail!("unknown workspace resource {workspace_id}");
    };
    validate_identity_state(transaction, workspace_id, "workspace", deleted.is_none())?;
    if deleted.is_some() {
        let live_descendant: i64 = transaction.query_row(
            "SELECT
               EXISTS(SELECT 1 FROM resource_screens
                      WHERE workspace_id = ?1 AND deleted_revision IS NULL)
               OR EXISTS(
                 SELECT 1 FROM resource_panes p
                 JOIN resource_screens s ON s.public_id = p.screen_id
                 WHERE s.workspace_id = ?1 AND p.deleted_revision IS NULL
               )
               OR EXISTS(
                 SELECT 1 FROM resource_tabs t
                 JOIN resource_panes p ON p.public_id = t.pane_id
                 JOIN resource_screens s ON s.public_id = p.screen_id
                 WHERE s.workspace_id = ?1 AND t.deleted_revision IS NULL
               )",
            [workspace_id],
            |row| row.get(0),
        )?;
        if live_descendant != 0 {
            anyhow::bail!("closed workspace {workspace_id} retains live descendants");
        }
        return Ok(());
    }
    let workspace_live = transaction
        .query_row(
            "SELECT 1 FROM workspaces
             WHERE workspace_key = ?1 AND tombstoned = 0",
            [&workspace_key],
            |_| Ok(()),
        )
        .optional()?;
    if workspace_live.is_none() {
        anyhow::bail!("resource workspace {workspace_id} has no live workspace row");
    }
    if let Some(active_screen) = active_screen {
        let owner =
            live_resource_field(transaction, "resource_screens", "workspace_id", &active_screen)?;
        if owner.as_deref() != Some(workspace_id) {
            anyhow::bail!(
                "workspace {workspace_id} selects screen {active_screen} owned by {:?}",
                owner
            );
        }
    }
    Ok(())
}

fn validate_touched_screen(transaction: &Transaction<'_>, screen_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT workspace_id, layout_json, active_pane_id, zoomed_pane_id,
                    deleted_revision
             FROM resource_screens WHERE public_id = ?1",
            [screen_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                ))
            },
        )
        .optional()?;
    let Some((workspace_id, layout, active_pane, zoomed_pane, deleted)) = stored else {
        anyhow::bail!("unknown screen resource {screen_id}");
    };
    validate_identity_state(transaction, screen_id, "screen", deleted.is_none())?;
    if deleted.is_some() {
        if !resource_children(transaction, "resource_panes", "screen_id", screen_id)?.is_empty() {
            anyhow::bail!("closed screen {screen_id} retains live panes");
        }
        return Ok(());
    }
    if live_resource_field(transaction, "resource_workspaces", "public_id", &workspace_id)?
        .is_none()
    {
        anyhow::bail!("screen {screen_id} has closed workspace {workspace_id}");
    }
    let layout: RegistryLayoutNode = serde_json::from_str(&layout)?;
    let mut layout_panes = HashSet::new();
    let mut layout_splits = HashSet::new();
    validate_layout_node(&layout, &mut layout_panes, &mut layout_splits)?;
    let layout_panes = layout_panes.into_iter().map(ToString::to_string).collect::<HashSet<_>>();
    let stored_panes = resource_children(transaction, "resource_panes", "screen_id", screen_id)?;
    if layout_panes != stored_panes {
        anyhow::bail!("screen {screen_id} layout does not match its live pane rows");
    }
    if !stored_panes.contains(&active_pane)
        || zoomed_pane.as_ref().is_some_and(|pane| !stored_panes.contains(pane))
    {
        anyhow::bail!("screen {screen_id} selects a pane outside its layout");
    }
    for split in layout_splits {
        validate_identity_state(transaction, split.as_str(), "split", true)?;
    }
    Ok(())
}

fn validate_touched_pane(transaction: &Transaction<'_>, pane_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT screen_id, active_tab_id, deleted_revision
             FROM resource_panes WHERE public_id = ?1",
            [pane_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((screen_id, active_tab, deleted)) = stored else {
        anyhow::bail!("unknown pane resource {pane_id}");
    };
    validate_identity_state(transaction, pane_id, "pane", deleted.is_none())?;
    if deleted.is_some() {
        if !resource_children(transaction, "resource_tabs", "pane_id", pane_id)?.is_empty() {
            anyhow::bail!("closed pane {pane_id} retains live tabs");
        }
        return Ok(());
    }
    if live_resource_field(transaction, "resource_screens", "public_id", &screen_id)?.is_none() {
        anyhow::bail!("pane {pane_id} has closed screen {screen_id}");
    }
    if let Some(active_tab) = active_tab {
        let owner = live_resource_field(transaction, "resource_tabs", "pane_id", &active_tab)?;
        if owner.as_deref() != Some(pane_id) {
            anyhow::bail!("pane {pane_id} selects tab {active_tab} owned by {:?}", owner);
        }
    }
    Ok(())
}

fn validate_touched_tab(transaction: &Transaction<'_>, tab_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT pane_id, content_kind, content_id, deleted_revision
             FROM resource_tabs WHERE public_id = ?1",
            [tab_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<i64>>(3)?,
                ))
            },
        )
        .optional()?;
    let Some((pane_id, content_kind, content_id, deleted)) = stored else {
        anyhow::bail!("unknown tab resource {tab_id}");
    };
    validate_identity_state(transaction, tab_id, "tab", deleted.is_none())?;
    if deleted.is_some() {
        return Ok(());
    }
    if live_resource_field(transaction, "resource_panes", "public_id", &pane_id)?.is_none() {
        anyhow::bail!("tab {tab_id} has closed pane {pane_id}");
    }
    let table = match content_kind.as_str() {
        "terminal" => "resource_terminals",
        "browser" => "resource_browsers",
        other => anyhow::bail!("tab {tab_id} has invalid content kind {other:?}"),
    };
    if live_resource_field(transaction, table, "public_id", &content_id)?.is_none() {
        anyhow::bail!("tab {tab_id} references closed {content_kind} {content_id}");
    }
    validate_identity_state(transaction, &content_id, &content_kind, true)
}

fn validate_touched_terminal(
    transaction: &Transaction<'_>,
    terminal_id: &str,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT terminal_id, lifecycle, deleted_revision
             FROM resource_terminals WHERE public_id = ?1",
            [terminal_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, Option<i64>>(2)?,
                ))
            },
        )
        .optional()?;
    let Some((host_id, lifecycle, deleted)) = stored else {
        anyhow::bail!("unknown terminal resource {terminal_id}");
    };
    validate_identity_state(transaction, terminal_id, "terminal", deleted.is_none())?;
    if (deleted.is_none() && lifecycle != "active")
        || (deleted.is_some() && lifecycle != "tombstoned")
    {
        anyhow::bail!("terminal {terminal_id} has inconsistent lifecycle {lifecycle}");
    }
    if TerminalPublicId::from_terminal_host_id(&host_id)?.as_str() != terminal_id {
        anyhow::bail!("terminal resource {terminal_id} has mismatched host id {host_id}");
    }
    let placement = read_terminal(transaction, &host_id)?;
    if deleted.is_none()
        && placement
            .as_ref()
            .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned)
    {
        anyhow::bail!("terminal resource {terminal_id} has no live placement");
    }
    if deleted.is_some()
        && placement
            .as_ref()
            .is_some_and(|terminal| terminal.lifecycle != TerminalLifecycle::Tombstoned)
    {
        anyhow::bail!("closed terminal resource {terminal_id} retains a live placement");
    }
    Ok(())
}

fn validate_touched_browser(transaction: &Transaction<'_>, browser_id: &str) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT lifecycle, deleted_revision
             FROM resource_browsers WHERE public_id = ?1",
            [browser_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?;
    let Some((lifecycle, deleted)) = stored else {
        anyhow::bail!("unknown browser resource {browser_id}");
    };
    validate_identity_state(transaction, browser_id, "browser", deleted.is_none())?;
    if (deleted.is_none() && lifecycle != "running")
        || (deleted.is_some() && lifecycle != "tombstoned")
    {
        anyhow::bail!("browser {browser_id} has inconsistent lifecycle {lifecycle}");
    }
    Ok(())
}

fn validate_identity_state(
    transaction: &Transaction<'_>,
    public_id: &str,
    expected_kind: &str,
    expected_live: bool,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?;
    let Some((kind, deleted)) = stored else {
        anyhow::bail!("{expected_kind} {public_id} has no identity ledger row");
    };
    if kind != expected_kind || deleted.is_none() != expected_live {
        anyhow::bail!(
            "{expected_kind} {public_id} identity state mismatch: kind={kind}, live={}",
            deleted.is_none()
        );
    }
    Ok(())
}

fn validate_positions_for_parent(
    transaction: &Transaction<'_>,
    table: &str,
    parent_field: &str,
    parent_id: &str,
    kind: &str,
) -> anyhow::Result<()> {
    let query = format!(
        "SELECT {parent_field}, position FROM {table}
         WHERE {parent_field} = ?1 AND deleted_revision IS NULL
         ORDER BY position ASC"
    );
    let rows = {
        let mut statement = transaction.prepare(&query)?;
        statement
            .query_map([parent_id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (expected, (_, position)) in rows.into_iter().enumerate() {
        if position != i64::try_from(expected)? {
            anyhow::bail!(
                "{kind} positions under {parent_id} are not contiguous: expected {expected}, found {position}"
            );
        }
    }
    Ok(())
}

fn validate_resource_invariants(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    ensure_no_foreign_key_violations(transaction)?;
    validate_concrete_identity_lifecycles(transaction)?;
    validate_contiguous_positions(
        transaction,
        "SELECT '' AS parent, position FROM workspaces
         WHERE tombstoned = 0 ORDER BY position ASC",
        "workspace",
    )?;
    validate_contiguous_positions(
        transaction,
        "SELECT workspace_id, position FROM resource_screens
         WHERE deleted_revision IS NULL ORDER BY workspace_id ASC, position ASC",
        "screen",
    )?;
    validate_contiguous_positions(
        transaction,
        "SELECT pane_id, position FROM resource_tabs
         WHERE deleted_revision IS NULL ORDER BY pane_id ASC, position ASC",
        "tab",
    )?;

    let unmapped_workspace = transaction
        .query_row(
            "SELECT w.workspace_key
             FROM workspaces w
             LEFT JOIN resource_workspaces rw
               ON rw.workspace_key = w.workspace_key AND rw.deleted_revision IS NULL
             WHERE w.tombstoned = 0 AND rw.public_id IS NULL
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(workspace_key) = unmapped_workspace {
        anyhow::bail!("live workspace {workspace_key} has no live public identity");
    }
    let closed_workspace = transaction
        .query_row(
            "SELECT rw.public_id
             FROM resource_workspaces rw
             LEFT JOIN workspaces w
               ON w.workspace_key = rw.workspace_key AND w.tombstoned = 0
             WHERE rw.deleted_revision IS NULL AND w.workspace_key IS NULL
             LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(workspace_id) = closed_workspace {
        anyhow::bail!("resource workspace {workspace_id} has no live workspace row");
    }

    if let Some(active_workspace) = meta_value(transaction, "active_workspace_id")? {
        let live = transaction
            .query_row(
                "SELECT 1 FROM resource_workspaces
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [&active_workspace],
                |_| Ok(()),
            )
            .optional()?;
        if live.is_none() {
            anyhow::bail!("active workspace {active_workspace} is not live");
        }
    }

    let active_screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id, active_screen_id FROM resource_workspaces
             WHERE deleted_revision IS NULL AND active_screen_id IS NOT NULL",
        )?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (workspace_id, screen_id) in active_screens {
        let owner =
            live_resource_field(transaction, "resource_screens", "workspace_id", &screen_id)?;
        if owner.as_deref() != Some(workspace_id.as_str()) {
            anyhow::bail!(
                "workspace {workspace_id} selects screen {screen_id} owned by {:?}",
                owner
            );
        }
    }

    let screens = {
        let mut statement = transaction.prepare(
            "SELECT public_id, workspace_id, layout_json, active_pane_id, zoomed_pane_id
             FROM resource_screens WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<String>>(4)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut expected_splits = HashSet::new();
    for (screen_id, workspace_id, layout_json, active_pane, zoomed_pane) in screens {
        if live_resource_field(transaction, "resource_workspaces", "public_id", &workspace_id)?
            .is_none()
        {
            anyhow::bail!("screen {screen_id} has closed workspace {workspace_id}");
        }
        let layout: RegistryLayoutNode = serde_json::from_str(&layout_json)?;
        let mut layout_panes = HashSet::new();
        let mut layout_splits = HashSet::new();
        validate_layout_node(&layout, &mut layout_panes, &mut layout_splits)?;
        let layout_panes =
            layout_panes.into_iter().map(ToString::to_string).collect::<HashSet<_>>();
        let stored_panes =
            resource_children(transaction, "resource_panes", "screen_id", &screen_id)?;
        if layout_panes != stored_panes {
            anyhow::bail!("screen {screen_id} layout does not match its live pane rows");
        }
        if !stored_panes.contains(&active_pane)
            || zoomed_pane.as_ref().is_some_and(|pane| !stored_panes.contains(pane))
        {
            anyhow::bail!("screen {screen_id} selects a pane outside its layout");
        }
        expected_splits.extend(layout_splits.into_iter().map(ToString::to_string));
    }
    let live_splits = {
        let mut statement = transaction.prepare(
            "SELECT public_id FROM resource_identities
             WHERE kind = 'split' AND deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<HashSet<_>, _>>()?
    };
    if live_splits != expected_splits {
        anyhow::bail!("live split identities do not match persisted screen layouts");
    }

    let panes = {
        let mut statement = transaction.prepare(
            "SELECT public_id, screen_id, active_tab_id FROM resource_panes
             WHERE deleted_revision IS NULL",
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
    for (pane_id, screen_id, active_tab) in panes {
        if live_resource_field(transaction, "resource_screens", "public_id", &screen_id)?.is_none()
        {
            anyhow::bail!("pane {pane_id} has closed screen {screen_id}");
        }
        if let Some(active_tab) = active_tab {
            let owner = live_resource_field(transaction, "resource_tabs", "pane_id", &active_tab)?;
            if owner.as_deref() != Some(pane_id.as_str()) {
                anyhow::bail!("pane {pane_id} selects tab {active_tab} owned by {:?}", owner);
            }
        }
    }

    let tabs = {
        let mut statement = transaction.prepare(
            "SELECT public_id, pane_id, content_kind, content_id
             FROM resource_tabs WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (tab_id, pane_id, content_kind, content_id) in tabs {
        if live_resource_field(transaction, "resource_panes", "public_id", &pane_id)?.is_none() {
            anyhow::bail!("tab {tab_id} has closed pane {pane_id}");
        }
        let table = match content_kind.as_str() {
            "terminal" => "resource_terminals",
            "browser" => "resource_browsers",
            other => anyhow::bail!("tab {tab_id} has invalid content kind {other:?}"),
        };
        if live_resource_field(transaction, table, "public_id", &content_id)?.is_none() {
            anyhow::bail!("tab {tab_id} references closed {content_kind} {content_id}");
        }
        let identity_kind = transaction
            .query_row(
                "SELECT kind FROM resource_identities
                 WHERE public_id = ?1 AND deleted_revision IS NULL",
                [&content_id],
                |row| row.get::<_, String>(0),
            )
            .optional()?;
        if identity_kind.as_deref() != Some(content_kind.as_str()) {
            anyhow::bail!(
                "tab {tab_id} content {content_id} has identity kind {:?}",
                identity_kind
            );
        }
    }

    let terminals = {
        let mut statement = transaction.prepare(
            "SELECT public_id, terminal_id, lifecycle FROM resource_terminals
             WHERE deleted_revision IS NULL",
        )?;
        statement
            .query_map([], |row| {
                Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    for (public_id, terminal_id, lifecycle) in terminals {
        if lifecycle != "active" {
            anyhow::bail!("live terminal {public_id} has lifecycle {lifecycle}");
        }
        if TerminalPublicId::from_terminal_host_id(&terminal_id)?.as_str() != public_id {
            anyhow::bail!("terminal resource {public_id} has mismatched host id {terminal_id}");
        }
        let placement = read_terminal(transaction, &terminal_id)?;
        if placement
            .as_ref()
            .is_none_or(|terminal| terminal.lifecycle == TerminalLifecycle::Tombstoned)
        {
            anyhow::bail!("terminal resource {public_id} has no live placement");
        }
    }
    let closed_browser = transaction
        .query_row(
            "SELECT public_id FROM resource_browsers
             WHERE deleted_revision IS NULL AND lifecycle != 'running' LIMIT 1",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()?;
    if let Some(browser_id) = closed_browser {
        anyhow::bail!("live browser {browser_id} is not running");
    }
    Ok(())
}

fn validate_concrete_identity_lifecycles(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    for (table, kind) in [
        ("resource_workspaces", "workspace"),
        ("resource_screens", "screen"),
        ("resource_panes", "pane"),
        ("resource_tabs", "tab"),
        ("resource_terminals", "terminal"),
        ("resource_browsers", "browser"),
    ] {
        let query = format!(
            "SELECT r.public_id
             FROM {table} r
             LEFT JOIN resource_identities i ON i.public_id = r.public_id
             WHERE i.public_id IS NULL OR i.kind != ?1
                OR ((r.deleted_revision IS NULL) != (i.deleted_revision IS NULL))
             LIMIT 1"
        );
        let mismatch =
            transaction.query_row(&query, [kind], |row| row.get::<_, String>(0)).optional()?;
        if let Some(public_id) = mismatch {
            anyhow::bail!("{kind} row {public_id} disagrees with its identity ledger");
        }
    }
    Ok(())
}

fn validate_contiguous_positions(
    transaction: &Transaction<'_>,
    query: &str,
    kind: &str,
) -> anyhow::Result<()> {
    let rows = {
        let mut statement = transaction.prepare(query)?;
        statement
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut next_by_parent = HashMap::<String, i64>::new();
    for (parent, position) in rows {
        let expected = next_by_parent.entry(parent.clone()).or_default();
        if position != *expected {
            anyhow::bail!(
                "{kind} positions under {parent:?} are not contiguous: expected {}, found {position}",
                *expected
            );
        }
        *expected += 1;
    }
    Ok(())
}

fn upsert_resource_identity(
    transaction: &Transaction<'_>,
    public_id: &str,
    kind: &str,
    revision: i64,
) -> anyhow::Result<()> {
    if let Some((stored_kind, deleted_revision)) = transaction
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?)),
        )
        .optional()?
    {
        if stored_kind != kind {
            anyhow::bail!("public id {public_id} has resource kind {stored_kind}, not {kind}");
        }
        if deleted_revision.is_some() {
            anyhow::bail!("tombstoned public id cannot be reused: {public_id}");
        }
    }
    transaction.execute(
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, ?2, ?3, ?3, NULL)
         ON CONFLICT(public_id) DO UPDATE SET updated_revision=excluded.updated_revision",
        params![public_id, kind, revision],
    )?;
    Ok(())
}

fn ensure_no_foreign_key_violations(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let violation = transaction
        .query_row("PRAGMA foreign_key_check", [], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })
        .optional()?;
    if let Some((table, rowid, parent, index)) = violation {
        anyhow::bail!(
            "resource topology foreign-key violation: table={table} rowid={rowid} parent={parent:?} index={index}"
        );
    }
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
mod tests {
    use super::*;

    const TERMINAL_ONE: &str = "00000000000040008000000000000001";
    const TERMINAL_TWO: &str = "00000000000040008000000000000002";
    const INCARNATION_ONE: &str = "10000000000040008000000000000001";
    use serde_json::json;

    fn temp_root(label: &str) -> PathBuf {
        std::env::temp_dir().join(format!("cmux-registry-{label}-{}", new_uuid_v4()))
    }

    fn workspace(id: u64, key: &str, name: &str) -> RegistryWorkspace {
        RegistryWorkspace {
            id,
            public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
            key: key.into(),
            name: name.into(),
            group_key: "default".into(),
        }
    }

    fn seed_workspace(registry: &mut WorkspaceRegistry, key: &str) {
        registry
            .commit(
                &WorkspaceMutation::new(format!("create-{key}"), "test").unwrap(),
                &json!({"op":"create","key":key}),
                None,
                Some(registry.snapshot().unwrap().revision),
                "workspace-added",
                key,
                &[workspace(1, key, "Workspace")],
                &json!({"key":key}),
            )
            .unwrap();
    }

    fn terminal(id: &str, workspace_key: &str) -> RegistryTerminal {
        RegistryTerminal {
            terminal_id: id.into(),
            workspace_key: workspace_key.into(),
            incarnation: None,
            lifecycle: TerminalLifecycle::Launching,
            launch_spec: json!({"command":["/bin/zsh"],"cwd":"/tmp","rows":24,"cols":80}),
            exit: None,
        }
    }

    fn screen_id(value: u128) -> ScreenPublicId {
        ScreenPublicId::parse(format!("screen_{value:032x}")).unwrap()
    }

    fn pane_id(value: u128) -> PanePublicId {
        PanePublicId::parse(format!("pane_{value:032x}")).unwrap()
    }

    fn tab_id(value: u128) -> TabPublicId {
        TabPublicId::parse(format!("tab_{value:032x}")).unwrap()
    }

    fn split_id(value: u128) -> SplitPublicId {
        SplitPublicId::parse(format!("split_{value:032x}")).unwrap()
    }

    fn terminal_resource(id: &str) -> TerminalPublicId {
        TerminalPublicId::from_terminal_host_id(id).unwrap()
    }

    fn browser_id(value: u128) -> BrowserPublicId {
        BrowserPublicId::parse(format!("browser_{value:032x}")).unwrap()
    }

    fn terminal_topology_patch() -> ResourcePatch {
        let workspace = workspace(1, "one", "One");
        let screen = screen_id(1);
        let pane = pane_id(1);
        let tab = tab_id(1);
        let terminal_id = terminal_resource(TERMINAL_ONE);
        ResourcePatch {
            changes: vec![
                ResourceChange::UpsertWorkspace {
                    workspace: workspace.clone(),
                    position: 0,
                    active_screen: Some(screen.clone()),
                },
                ResourceChange::UpsertScreen(RegistryScreen {
                    public_id: screen.clone(),
                    workspace_id: workspace.public_id.clone(),
                    position: 0,
                    name: Some("Main".into()),
                    layout: RegistryLayoutNode::Leaf { pane: pane.clone() },
                    active_pane: pane.clone(),
                    zoomed_pane: None,
                    auto_layout: None,
                    viewport: json!({"offset":0}),
                }),
                ResourceChange::UpsertPane(RegistryPane {
                    public_id: pane.clone(),
                    screen_id: screen.clone(),
                    name: Some("Shell".into()),
                    active_tab: Some(tab.clone()),
                    creation_ordinal: 1,
                }),
                ResourceChange::UpsertTerminal {
                    public_id: terminal_id.clone(),
                    terminal: terminal(TERMINAL_ONE, "one"),
                },
                ResourceChange::UpsertTab(RegistryTab {
                    public_id: tab.clone(),
                    pane_id: pane.clone(),
                    position: 0,
                    content_id: ContentPublicId::Terminal(terminal_id),
                    name: Some("zsh".into()),
                    browser_url: None,
                }),
                ResourceChange::SetWorkspaceOrder {
                    workspace_ids: vec![workspace.public_id.clone()],
                },
                ResourceChange::SetScreenOrder {
                    workspace_id: workspace.public_id.clone(),
                    screen_ids: vec![screen],
                },
                ResourceChange::SetTabOrder { pane_id: pane, tab_ids: vec![tab] },
                ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace.public_id) },
            ],
        }
    }

    fn commit_terminal_topology(
        registry: &mut WorkspaceRegistry,
        mutation_id: &str,
    ) -> ResourcePatchCommit {
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new(mutation_id, "test").unwrap(),
                "workspace.create",
                &json!({"operation":"workspace.create","name":"One"}),
                None,
                Some(0),
                &terminal_topology_patch(),
                &json!({"workspace_id":workspace(1, "one", "One").public_id}),
                &json!([{"kind":"workspace.created"}]),
            )
            .unwrap()
    }

    #[test]
    fn resource_patch_commits_terminal_and_topology_in_one_revision() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        let commit = commit_terminal_topology(&mut registry, "create-one");
        assert_eq!(commit.revision, 1);
        assert!(!commit.replayed);

        let snapshot = registry.resource_topology_snapshot().unwrap();
        assert_eq!(snapshot.revision, 1);
        assert_eq!(snapshot.active_workspace, Some(workspace(1, "one", "One").public_id));
        assert_eq!(snapshot.screens.len(), 1);
        assert_eq!(snapshot.panes.len(), 1);
        assert_eq!(snapshot.tabs.len(), 1);
        assert_eq!(
            registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Launching
        );
        assert_eq!(
            registry
                .connection
                .query_row("SELECT COUNT(*) FROM resource_events", [], |row| row.get::<_, i64>(0))
                .unwrap(),
            1
        );
        assert_eq!(
            registry
                .connection
                .query_row("SELECT COUNT(*) FROM resource_mutations", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            1
        );
    }

    #[test]
    fn resource_patch_replay_precedes_revision_and_rejects_changed_input() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        let first = commit_terminal_topology(&mut registry, "same-key");
        let retry = registry
            .commit_resource_patch(
                &WorkspaceMutation::new("same-key", "test").unwrap(),
                "workspace.create",
                &json!({"operation":"workspace.create","name":"One"}),
                None,
                Some(0),
                &terminal_topology_patch(),
                &json!({"workspace_id":workspace(1, "one", "One").public_id}),
                &json!([{"kind":"workspace.created"}]),
            )
            .unwrap();
        assert_eq!(retry.revision, first.revision);
        assert!(retry.replayed);
        let error = registry
            .commit_resource_patch(
                &WorkspaceMutation::new("same-key", "test").unwrap(),
                "workspace.create",
                &json!({"operation":"workspace.create","name":"Different"}),
                None,
                None,
                &terminal_topology_patch(),
                &json!({}),
                &json!([]),
            )
            .unwrap_err();
        assert!(error.to_string().contains("idempotency.conflict"));
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 1);
    }

    #[test]
    fn resource_patch_failure_rolls_back_every_projection_and_log() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        registry.set_resource_patch_failure(true).unwrap();
        let error = registry
            .commit_resource_patch(
                &WorkspaceMutation::new("forced-failure", "test").unwrap(),
                "workspace.create",
                &json!({"operation":"workspace.create"}),
                None,
                Some(0),
                &terminal_topology_patch(),
                &json!({}),
                &json!([]),
            )
            .unwrap_err();
        assert!(error.to_string().contains("forced resource patch failure"));
        registry.set_resource_patch_failure(false).unwrap();
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 0);
        assert!(registry.snapshot().unwrap().workspaces.is_empty());
        assert!(registry.terminal_record(TERMINAL_ONE).unwrap().is_none());
        for table in [
            "resource_identities",
            "resource_screens",
            "resource_panes",
            "resource_tabs",
            "resource_terminals",
            "resource_mutations",
            "resource_events",
        ] {
            let count = registry
                .connection
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| row.get::<_, i64>(0))
                .unwrap();
            assert_eq!(count, 0, "{table} was not rolled back");
        }
    }

    #[test]
    fn targeted_resource_patch_does_not_rewrite_unrelated_rows() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        commit_terminal_topology(&mut registry, "create");
        let pane = pane_id(1);
        let screen = screen_id(1);
        let tab = tab_id(1);
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("rename-pane", "test").unwrap(),
                "pane.rename",
                &json!({"operation":"pane.rename","pane_id":pane,"name":"Build"}),
                None,
                Some(1),
                &ResourcePatch {
                    changes: vec![ResourceChange::UpsertPane(RegistryPane {
                        public_id: pane.clone(),
                        screen_id: screen.clone(),
                        name: Some("Build".into()),
                        active_tab: Some(tab.clone()),
                        creation_ordinal: 1,
                    })],
                },
                &json!({"pane_id":pane}),
                &json!([{"kind":"pane.renamed"}]),
            )
            .unwrap();
        let revisions = |table: &str, public_id: &str| {
            registry
                .connection
                .query_row(
                    &format!("SELECT updated_revision FROM {table} WHERE public_id = ?1"),
                    [public_id],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap()
        };
        assert_eq!(revisions("resource_panes", pane.as_str()), 2);
        assert_eq!(revisions("resource_screens", screen.as_str()), 1);
        assert_eq!(revisions("resource_tabs", tab.as_str()), 1);
        assert_eq!(revisions("resource_terminals", terminal_resource(TERMINAL_ONE).as_str()), 1);
    }

    #[test]
    fn resource_tombstones_prevent_public_id_and_workspace_key_reuse() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        commit_terminal_topology(&mut registry, "create");
        let workspace = workspace(1, "one", "One");
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("close", "test").unwrap(),
                "workspace.close",
                &json!({"operation":"workspace.close","workspace_id":workspace.public_id}),
                None,
                Some(1),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::TombstoneWorkspace {
                            workspace_id: workspace.public_id.clone(),
                        },
                        ResourceChange::SetWorkspaceOrder { workspace_ids: vec![] },
                        ResourceChange::SetActiveWorkspace { workspace_id: None },
                    ],
                },
                &json!({"closed":true}),
                &json!([{"kind":"workspace.closed"}]),
            )
            .unwrap();
        assert!(registry.resource_topology_snapshot().unwrap().screens.is_empty());
        assert!(registry.terminal_snapshot().unwrap().terminals.is_empty());
        let error = registry
            .commit_resource_patch(
                &WorkspaceMutation::new("recreate", "test").unwrap(),
                "workspace.create",
                &json!({"operation":"workspace.create"}),
                None,
                Some(2),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertWorkspace {
                            workspace,
                            position: 0,
                            active_screen: None,
                        },
                        ResourceChange::SetWorkspaceOrder {
                            workspace_ids: vec![
                                WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
                            ],
                        },
                    ],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap_err();
        assert!(error.to_string().contains("tombstoned workspace key cannot be reused"));
        assert_eq!(registry.resource_topology_snapshot().unwrap().revision, 2);
    }

    #[test]
    fn resource_order_is_exact_and_positions_are_contiguous() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        let one = workspace(1, "one", "One");
        let two = workspace(2, "two", "Two");
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("create-two", "test").unwrap(),
                "workspace.create",
                &json!({"operation":"workspace.create"}),
                None,
                Some(0),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertWorkspace {
                            workspace: one.clone(),
                            position: 0,
                            active_screen: None,
                        },
                        ResourceChange::UpsertWorkspace {
                            workspace: two.clone(),
                            position: 1,
                            active_screen: None,
                        },
                        ResourceChange::SetWorkspaceOrder {
                            workspace_ids: vec![one.public_id.clone(), two.public_id.clone()],
                        },
                    ],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("move", "test").unwrap(),
                "workspace.move",
                &json!({"operation":"workspace.move"}),
                None,
                Some(1),
                &ResourcePatch {
                    changes: vec![ResourceChange::SetWorkspaceOrder {
                        workspace_ids: vec![two.public_id.clone(), one.public_id.clone()],
                    }],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap();
        assert_eq!(
            registry
                .snapshot()
                .unwrap()
                .workspaces
                .into_iter()
                .map(|workspace| workspace.public_id)
                .collect::<Vec<_>>(),
            vec![two.public_id, one.public_id]
        );
    }

    #[test]
    fn resource_ids_survive_registry_restart() {
        let root = temp_root("resource-restart");
        let before = {
            let mut registry = WorkspaceRegistry::open(&root, "session").unwrap();
            commit_terminal_topology(&mut registry, "create");
            registry.resource_topology_snapshot().unwrap()
        };
        let registry = WorkspaceRegistry::open(&root, "session").unwrap();
        let after = registry.resource_topology_snapshot().unwrap();
        assert_eq!(after.session_id, before.session_id);
        assert_eq!(after.revision, before.revision);
        assert_eq!(after.active_workspace, before.active_workspace);
        assert_eq!(after.screens, before.screens);
        assert_eq!(after.panes, before.panes);
        assert_eq!(after.tabs, before.tabs);
        assert_ne!(after.generation, before.generation);
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn split_and_browser_identities_follow_targeted_parent_lifecycle() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        commit_terminal_topology(&mut registry, "create");
        let workspace_public_id = workspace(1, "one", "One").public_id;
        let screen = screen_id(1);
        let first_pane = pane_id(1);
        let second_pane = pane_id(2);
        let second_tab = tab_id(2);
        let split = split_id(1);
        let browser = browser_id(1);
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("split", "test").unwrap(),
                "pane.split",
                &json!({"operation":"pane.split"}),
                None,
                Some(1),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertScreen(RegistryScreen {
                            public_id: screen.clone(),
                            workspace_id: workspace_public_id.clone(),
                            position: 0,
                            name: Some("Main".into()),
                            layout: RegistryLayoutNode::Split {
                                split: split.clone(),
                                direction: "right".into(),
                                ratio: 0.5,
                                first: Box::new(RegistryLayoutNode::Leaf {
                                    pane: first_pane.clone(),
                                }),
                                second: Box::new(RegistryLayoutNode::Leaf {
                                    pane: second_pane.clone(),
                                }),
                            },
                            active_pane: first_pane.clone(),
                            zoomed_pane: None,
                            auto_layout: None,
                            viewport: json!({"offset":0}),
                        }),
                        ResourceChange::UpsertPane(RegistryPane {
                            public_id: second_pane.clone(),
                            screen_id: screen.clone(),
                            name: Some("Docs".into()),
                            active_tab: Some(second_tab.clone()),
                            creation_ordinal: 2,
                        }),
                        ResourceChange::UpsertBrowser {
                            public_id: browser.clone(),
                            url: "https://cmux.dev".into(),
                        },
                        ResourceChange::UpsertTab(RegistryTab {
                            public_id: second_tab.clone(),
                            pane_id: second_pane.clone(),
                            position: 0,
                            content_id: ContentPublicId::Browser(browser.clone()),
                            name: Some("Docs".into()),
                            browser_url: Some("https://cmux.dev".into()),
                        }),
                        ResourceChange::SetTabOrder {
                            pane_id: second_pane.clone(),
                            tab_ids: vec![second_tab],
                        },
                    ],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap();
        assert_eq!(
            registry
                .connection
                .query_row(
                    "SELECT kind FROM resource_identities
                     WHERE public_id = ?1 AND deleted_revision IS NULL",
                    [split.as_str()],
                    |row| row.get::<_, String>(0),
                )
                .unwrap(),
            "split"
        );

        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("unsplit", "test").unwrap(),
                "pane.close",
                &json!({"operation":"pane.close"}),
                None,
                Some(2),
                &ResourcePatch {
                    changes: vec![
                        ResourceChange::UpsertScreen(RegistryScreen {
                            public_id: screen.clone(),
                            workspace_id: workspace_public_id,
                            position: 0,
                            name: Some("Main".into()),
                            layout: RegistryLayoutNode::Leaf { pane: first_pane.clone() },
                            active_pane: first_pane,
                            zoomed_pane: None,
                            auto_layout: None,
                            viewport: json!({"offset":0}),
                        }),
                        ResourceChange::TombstonePane { pane_id: second_pane },
                    ],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap();
        for public_id in [split.as_str(), browser.as_str()] {
            assert!(
                registry
                    .connection
                    .query_row(
                        "SELECT deleted_revision FROM resource_identities WHERE public_id = ?1",
                        [public_id],
                        |row| row.get::<_, Option<i64>>(0),
                    )
                    .unwrap()
                    .is_some()
            );
        }
    }

    #[test]
    fn resource_identity_sql_check_rejects_non_hex_payload() {
        let registry = WorkspaceRegistry::in_memory("test").unwrap();
        let invalid = format!("pane_{}", "z".repeat(32));
        let error = registry
            .connection
            .execute(
                "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'pane', 1, 1, NULL)",
                [&invalid],
            )
            .unwrap_err();
        assert!(error.to_string().contains("CHECK constraint failed"));
    }

    #[test]
    fn deferred_terminal_foreign_keys_reject_orphans_at_commit() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        let public_id = terminal_resource(TERMINAL_TWO);
        {
            let tx = registry.connection.transaction().unwrap();
            tx.execute(
                "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'terminal', 1, 1, NULL)",
                [public_id.as_str()],
            )
            .unwrap();
            tx.execute(
                "INSERT INTO resource_terminals(
                   public_id, terminal_id, lifecycle,
                   created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, ?2, 'active', 1, 1, NULL)",
                params![public_id.as_str(), TERMINAL_TWO],
            )
            .unwrap();
            assert!(tx.commit().unwrap_err().to_string().contains("FOREIGN KEY constraint failed"));
        }
        assert_eq!(
            registry
                .connection
                .query_row("SELECT COUNT(*) FROM resource_terminals", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            0
        );

        let tx = registry.connection.transaction().unwrap();
        tx.execute(
            "INSERT INTO terminal_placements(
               terminal_id, workspace_key, incarnation, lifecycle, launch_spec_json,
               exit_json, created_revision, updated_revision, deleted_revision
             ) VALUES(?1, 'missing', NULL, 'launching', '{}', NULL, 1, 1, NULL)",
            [TERMINAL_TWO],
        )
        .unwrap();
        assert!(tx.commit().unwrap_err().to_string().contains("FOREIGN KEY constraint failed"));
    }

    #[test]
    fn thousand_workspace_rename_has_bounded_writes_and_time() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        let workspaces = (1..=1_000)
            .map(|id| workspace(id, &format!("workspace-{id}"), &format!("Workspace {id}")))
            .collect::<Vec<_>>();
        let mut changes = workspaces
            .iter()
            .enumerate()
            .map(|(position, workspace)| ResourceChange::UpsertWorkspace {
                workspace: workspace.clone(),
                position,
                active_screen: None,
            })
            .collect::<Vec<_>>();
        changes.push(ResourceChange::SetWorkspaceOrder {
            workspace_ids: workspaces.iter().map(|workspace| workspace.public_id.clone()).collect(),
        });
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("seed-1000", "perf-test").unwrap(),
                "workspace.create",
                &json!({"count":1000}),
                None,
                Some(0),
                &ResourcePatch { changes },
                &json!({}),
                &json!([]),
            )
            .unwrap();

        let target = workspaces[499].clone();
        let mut renamed = target.clone();
        renamed.name = "Renamed".into();
        let changes_before = registry.connection.total_changes();
        let started = std::time::Instant::now();
        registry
            .commit_resource_patch(
                &WorkspaceMutation::new("rename-one-of-1000", "perf-test").unwrap(),
                "workspace.rename",
                &json!({"workspace_id":target.public_id,"name":"Renamed"}),
                None,
                Some(1),
                &ResourcePatch {
                    changes: vec![ResourceChange::UpsertWorkspace {
                        workspace: renamed,
                        position: 499,
                        active_screen: None,
                    }],
                },
                &json!({}),
                &json!([]),
            )
            .unwrap();
        let elapsed = started.elapsed();
        let changed_rows = registry.connection.total_changes() - changes_before;
        assert!(changed_rows <= 8, "rename changed {changed_rows} rows");
        assert!(elapsed < std::time::Duration::from_secs(1), "targeted rename took {elapsed:?}");
        assert_eq!(
            registry
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM workspaces WHERE updated_revision = 2",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            1
        );
        assert_eq!(
            registry
                .connection
                .query_row(
                    "SELECT COUNT(*) FROM resource_workspaces WHERE updated_revision = 2",
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            1
        );
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
                        public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
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
            public_id: WorkspacePublicId::parse(format!("ws_{:032x}", 1)).unwrap(),
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
        assert_eq!(registry.snapshot().unwrap().next_numeric_id, 2);
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
        assert_eq!(registry.snapshot().unwrap().next_numeric_id, 2);
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
    fn terminal_lifecycle_is_exactly_once_and_has_an_independent_revision() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        seed_workspace(&mut registry, "one");
        assert_eq!(registry.snapshot().unwrap().revision, 1);
        assert_eq!(registry.terminal_snapshot().unwrap().revision, 0);

        let terminal = terminal(TERMINAL_ONE, "one");
        let reserve = WorkspaceMutation::new("reserve-1", "browser").unwrap();
        let fingerprint = json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE});
        let result = json!({"terminal_id":TERMINAL_ONE,"state":"launching"});
        let first = registry
            .commit_terminal(
                &reserve,
                &fingerprint,
                None,
                Some(0),
                "terminal-added",
                &terminal,
                &result,
            )
            .unwrap();
        assert_eq!(first.revision, 1);
        assert!(!first.replayed);
        let retry = registry
            .commit_terminal(
                &reserve,
                &fingerprint,
                None,
                Some(0),
                "terminal-added",
                &terminal,
                &result,
            )
            .unwrap();
        assert_eq!(retry.revision, 1);
        assert!(retry.replayed);

        let mut adopting = terminal.clone();
        adopting.lifecycle = TerminalLifecycle::Adopting;
        adopting.incarnation = Some(INCARNATION_ONE.into());
        registry
            .commit_terminal(
                &WorkspaceMutation::new("adopt-1", "daemon").unwrap(),
                &json!({"op":"adopt-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(1),
                "terminal-adopting",
                &adopting,
                &json!({"terminal_id":TERMINAL_ONE,"state":"adopting"}),
            )
            .unwrap();
        let mut running = adopting;
        running.lifecycle = TerminalLifecycle::Running;
        registry
            .commit_terminal(
                &WorkspaceMutation::new("ready-1", "daemon").unwrap(),
                &json!({"op":"terminal-ready","terminal_id":TERMINAL_ONE}),
                None,
                Some(2),
                "terminal-ready",
                &running,
                &json!({"terminal_id":TERMINAL_ONE,"state":"running"}),
            )
            .unwrap();

        let terminals = registry.terminal_snapshot().unwrap();
        assert_eq!(terminals.revision, 3);
        assert_eq!(terminals.terminals, vec![running]);
        assert_eq!(registry.snapshot().unwrap().revision, 1);
        assert_eq!(registry.terminal_events_after(0).unwrap().len(), 3);
    }

    #[test]
    fn first_exit_metadata_wins_and_exited_ids_cannot_be_relaunched() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        seed_workspace(&mut registry, "one");
        let launching = terminal(TERMINAL_ONE, "one");
        registry
            .commit_terminal(
                &WorkspaceMutation::new("reserve", "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(0),
                "terminal-reserved",
                &launching,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap();

        let mut first_exit = launching.clone();
        first_exit.lifecycle = TerminalLifecycle::Exited;
        first_exit.exit = Some(json!({"reason":"first-observer","status":17}));
        let first = registry
            .commit_terminal(
                &WorkspaceMutation::new("exit-one", "daemon").unwrap(),
                &json!({"op":"terminal-exited","terminal_id":TERMINAL_ONE}),
                None,
                Some(1),
                "terminal-exited",
                &first_exit,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap();
        assert_eq!(first.revision, 2);

        let mut late_exit = first_exit.clone();
        late_exit.exit = Some(json!({"reason":"late-observer","status":99}));
        let duplicate = registry
            .commit_terminal(
                &WorkspaceMutation::new("exit-two", "daemon").unwrap(),
                &json!({"op":"terminal-exited-again","terminal_id":TERMINAL_ONE}),
                None,
                Some(2),
                "terminal-exited",
                &late_exit,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap();
        assert!(duplicate.replayed);
        assert_eq!(duplicate.revision, 2);
        assert_eq!(registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().exit, first_exit.exit);
        assert_eq!(registry.terminal_events_after(0).unwrap().len(), 2);

        let error = registry
            .commit_terminal(
                &WorkspaceMutation::new("reuse-exited", "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(2),
                "terminal-reserved",
                &launching,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap_err();
        assert!(error.to_string().contains("invalid terminal transition Exited -> Launching"));
        assert_eq!(
            registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Exited
        );
    }

    #[test]
    fn batch_terminal_close_rolls_back_every_tab_on_mid_transaction_failure() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        seed_workspace(&mut registry, "one");
        for (revision, terminal_id) in [(0, TERMINAL_ONE), (1, TERMINAL_TWO)] {
            registry
                .commit_terminal(
                    &WorkspaceMutation::new(format!("reserve-{revision}"), "browser").unwrap(),
                    &json!({"op":"reserve-terminal","terminal_id":terminal_id}),
                    None,
                    Some(revision),
                    "terminal-reserved",
                    &terminal(terminal_id, "one"),
                    &json!({"terminal_id":terminal_id}),
                )
                .unwrap();
        }
        registry
            .connection
            .execute_batch(&format!(
                "CREATE TEMP TRIGGER fail_second_terminal_close
                 BEFORE UPDATE OF lifecycle ON terminal_placements
                 WHEN NEW.terminal_id = '{TERMINAL_TWO}'
                 BEGIN SELECT RAISE(ABORT, 'forced batch failure'); END;"
            ))
            .unwrap();
        let requests = vec![(TERMINAL_ONE.to_string(), None), (TERMINAL_TWO.to_string(), None)];
        let error = registry
            .close_terminals_atomically(
                &WorkspaceMutation::new("close-pane-failed", "tui").unwrap(),
                &requests,
            )
            .unwrap_err();
        assert!(error.to_string().contains("forced batch failure"));
        assert_eq!(registry.terminal_snapshot().unwrap().revision, 2);
        for terminal_id in [TERMINAL_ONE, TERMINAL_TWO] {
            assert_eq!(
                registry.terminal_record(terminal_id).unwrap().unwrap().lifecycle,
                TerminalLifecycle::Launching
            );
        }
        registry.connection.execute_batch("DROP TRIGGER fail_second_terminal_close").unwrap();

        let closed = registry
            .close_terminals_atomically(
                &WorkspaceMutation::new("close-pane", "tui").unwrap(),
                &requests,
            )
            .unwrap();
        assert_eq!(closed, TerminalBatchClose { revision: 4, closed: 2 });
        assert_eq!(registry.terminal_events_after(2).unwrap().len(), 2);
        for terminal_id in [TERMINAL_ONE, TERMINAL_TWO] {
            assert_eq!(
                registry.terminal_record(terminal_id).unwrap().unwrap().lifecycle,
                TerminalLifecycle::Tombstoned
            );
        }
    }

    #[test]
    fn terminal_close_tombstones_before_kill_and_retries_safely() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        seed_workspace(&mut registry, "one");
        let terminal = terminal(TERMINAL_ONE, "one");
        registry
            .commit_terminal(
                &WorkspaceMutation::new("reserve-1", "browser").unwrap(),
                &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(0),
                "terminal-added",
                &terminal,
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap();

        let close = WorkspaceMutation::new("close-1", "browser").unwrap();
        let first = registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
        assert_eq!(first.revision, 2);
        assert_eq!(first.result["already_closed"], false);
        assert_eq!(
            registry.terminal_record(TERMINAL_ONE).unwrap().unwrap().lifecycle,
            TerminalLifecycle::Tombstoned
        );
        assert!(registry.terminal_snapshot().unwrap().terminals.is_empty());

        let lost_reply_retry =
            registry.close_terminal(&close, None, Some(1), TERMINAL_ONE, None).unwrap();
        assert!(lost_reply_retry.replayed);
        assert_eq!(lost_reply_retry.revision, 2);

        let second_close = registry
            .close_terminal(
                &WorkspaceMutation::new("close-2", "tui").unwrap(),
                None,
                Some(2),
                TERMINAL_ONE,
                None,
            )
            .unwrap();
        assert_eq!(second_close.revision, 2);
        assert_eq!(second_close.result["already_closed"], true);
        assert_eq!(registry.terminal_events_after(0).unwrap().len(), 2);

        assert!(
            registry
                .commit_terminal(
                    &WorkspaceMutation::new("reuse", "browser").unwrap(),
                    &json!({"op":"reserve-terminal","terminal_id":TERMINAL_ONE}),
                    None,
                    Some(2),
                    "terminal-added",
                    &terminal,
                    &json!({"terminal_id":TERMINAL_ONE}),
                )
                .unwrap_err()
                .to_string()
                .contains("tombstoned terminal id cannot be reused")
        );
    }

    #[test]
    fn closing_workspace_atomically_tombstones_all_child_terminals() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        seed_workspace(&mut registry, "one");
        for (index, id) in [TERMINAL_ONE, TERMINAL_TWO].into_iter().enumerate() {
            let revision = u64::try_from(index).unwrap();
            registry
                .commit_terminal(
                    &WorkspaceMutation::new(format!("reserve-{}", index + 1), "browser").unwrap(),
                    &json!({"op":"reserve-terminal","terminal_id":id}),
                    None,
                    Some(revision),
                    "terminal-added",
                    &terminal(id, "one"),
                    &json!({"terminal_id":id}),
                )
                .unwrap();
        }
        registry
            .commit(
                &WorkspaceMutation::new("close-workspace", "browser").unwrap(),
                &json!({"op":"close-workspace","workspace_key":"one"}),
                None,
                Some(1),
                "workspace-closed",
                "one",
                &[],
                &json!({"workspace_key":"one"}),
            )
            .unwrap();

        assert!(registry.snapshot().unwrap().workspaces.is_empty());
        let terminals = registry.terminal_snapshot().unwrap();
        assert_eq!(terminals.revision, 4);
        assert!(terminals.terminals.is_empty());
        for id in [TERMINAL_ONE, TERMINAL_TWO] {
            assert_eq!(
                registry.terminal_record(id).unwrap().unwrap().lifecycle,
                TerminalLifecycle::Tombstoned
            );
        }
        let events = registry.terminal_events_after(2).unwrap();
        assert_eq!(events.len(), 2);
        assert!(events.iter().all(|event| event.result["reason"] == "workspace-closed"));
    }

    #[test]
    fn terminal_reserve_after_workspace_close_fails_referentially() {
        let mut registry = WorkspaceRegistry::in_memory("test").unwrap();
        seed_workspace(&mut registry, "one");
        registry
            .commit(
                &WorkspaceMutation::new("close", "browser").unwrap(),
                &json!({"op":"close-workspace"}),
                None,
                Some(1),
                "workspace-closed",
                "one",
                &[],
                &json!({"key":"one"}),
            )
            .unwrap();
        let error = registry
            .commit_terminal(
                &WorkspaceMutation::new("late-reserve", "browser").unwrap(),
                &json!({"op":"create-terminal","terminal_id":TERMINAL_ONE}),
                None,
                Some(0),
                "terminal-reserved",
                &terminal(TERMINAL_ONE, "one"),
                &json!({"terminal_id":TERMINAL_ONE}),
            )
            .unwrap_err();
        assert!(error.to_string().contains("workspace is missing or closed"));
        assert!(registry.terminal_record(TERMINAL_ONE).unwrap().is_none());
        assert_eq!(registry.terminal_snapshot().unwrap().revision, 0);
    }

    #[test]
    fn schema_one_migrates_transactionally_to_terminal_registry() {
        let root = temp_root("schema-one");
        let session_dir = root.join(session_storage_component("session"));
        {
            let registry = WorkspaceRegistry::open(&root, "session").unwrap();
            drop(registry);
            let connection =
                Connection::open(session_dir.join("workspace-registry.sqlite3")).unwrap();
            connection
                .execute_batch(
                    "DROP TABLE terminal_events;
                     DROP TABLE terminal_mutations;
                     DROP TABLE terminal_placements;
                     DELETE FROM meta WHERE key = 'terminal_revision';
                     UPDATE meta SET value = '1' WHERE key = 'schema_version';",
                )
                .unwrap();
        }
        let migrated = WorkspaceRegistry::open(&root, "session").unwrap();
        assert_eq!(migrated.terminal_snapshot().unwrap().revision, 0);
        assert!(migrated.terminal_snapshot().unwrap().terminals.is_empty());
        assert_eq!(required_meta(&migrated.connection, "schema_version").unwrap(), "3");
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
