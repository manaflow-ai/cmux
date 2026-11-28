//! `workspace-kind-v1`: the home workspace record (plans/cmux-next/home.md
//! section 7). A workspace is `normal` unless a row here marks it `home`, or
//! `app` with its `app_id` (`app-screens-v1`, state/app_workspaces.rs: one
//! live app workspace per app).
//!
//! Owner rules, all enforced in the store:
//! - At most one home per store: a unique index on `kind`, and
//!   `workspace.ensure_home` replays the existing home.
//! - `kind` is written only in the commit that creates the workspace, and
//!   never changes after.
//! - The home workspace is never closed: every close path refuses it with
//!   `home.not_closable` before it ends a terminal, and the tombstone of
//!   the durable row refuses it too.
//! - It stays first in the top (ungrouped) section of the personal order:
//!   a placement that moves it into a group or behind another ungrouped
//!   workspace is refused with `home.pinned_first`. Grouped workspaces may
//!   take any index.
//! - The creation commit writes the workspace row, the kind row and the
//!   personal placement in one transaction.
//!
//! The store never reads conversation content.

use std::fmt;

use rusqlite::{Connection, OptionalExtension, Transaction};

use crate::workspace_registry::personal_store::read_workspaces;
use crate::workspace_registry::{PersonalWorkspaceUpdate, WorkspaceRegistry};

pub(crate) const WORKSPACE_KIND_CAPABILITY: &str = "workspace-kind-v1";
pub(crate) const HOME_KIND: &str = "home";
/// The fixed idempotency key and correlation key of the home creation.
pub(crate) const HOME_CREATION_KEY: &str = "home";

pub(crate) fn create_home_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_kind (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('home', 'app')),
           app_id TEXT,
           workspace_key TEXT,
           CHECK((kind = 'app') = (app_id IS NOT NULL))
         );",
    )?;
    rebuild_home_only_kind_table(transaction)?;
    transaction.execute_batch(
        "CREATE UNIQUE INDEX IF NOT EXISTS workspace_kind_one_home
           ON workspace_kind(kind) WHERE kind = 'home';
         CREATE UNIQUE INDEX IF NOT EXISTS workspace_kind_one_app
           ON workspace_kind(app_id) WHERE kind = 'app';",
    )?;
    Ok(())
}

/// The kind table of builds before `app-screens-v1` allows only `home`
/// (`CHECK(kind = 'home')`, a unique index on `kind`). SQLite cannot change
/// a CHECK, so the table is rebuilt once with the `app` kind and `app_id`;
/// the home row keeps its workspace id. Older builds read the new table
/// unchanged: their queries name `kind = 'home'` only.
fn rebuild_home_only_kind_table(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let sql: Option<String> = transaction
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'workspace_kind'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if sql.as_deref().is_none_or(|sql| sql.contains("app_id")) {
        return Ok(());
    }
    transaction.execute_batch(
        "DROP INDEX IF EXISTS workspace_kind_one_home;
         CREATE TABLE workspace_kind_app_screens (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('home', 'app')),
           app_id TEXT,
           workspace_key TEXT,
           CHECK((kind = 'app') = (app_id IS NOT NULL))
         );
         INSERT INTO workspace_kind_app_screens(workspace_id, kind)
           SELECT workspace_id, kind FROM workspace_kind;
         DROP TABLE workspace_kind;
         ALTER TABLE workspace_kind_app_screens RENAME TO workspace_kind;",
    )?;
    Ok(())
}

/// The state row an empty workspace creation writes in its own commit.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) enum EmptyWorkspaceMark {
    #[default]
    None,
    Ephemeral,
    Home,
    /// The app workspace of this app (`app-screens-v1`).
    App(String),
}

impl EmptyWorkspaceMark {
    pub(crate) fn ephemeral(ephemeral: bool) -> Self {
        if ephemeral { Self::Ephemeral } else { Self::None }
    }

    pub(crate) fn writes(&self) -> bool {
        *self != Self::None
    }

    /// The field the creation fingerprint carries for this mark.
    pub(crate) fn fingerprint_field(&self) -> Option<(&'static str, serde_json::Value)> {
        match self {
            Self::None => None,
            Self::Ephemeral => Some(("ephemeral", serde_json::Value::Bool(true))),
            Self::Home => Some(("kind", serde_json::Value::String(HOME_KIND.to_string()))),
            Self::App(app) => Some(("app", serde_json::Value::String(app.clone()))),
        }
    }

    /// The rows this mark writes in the transaction that creates the
    /// workspace.
    pub(crate) fn write(
        &self,
        transaction: &Transaction<'_>,
        workspace_id: &str,
        workspace_key: &str,
    ) -> anyhow::Result<()> {
        match self {
            Self::None => Ok(()),
            Self::Ephemeral => {
                crate::state::store::mark_workspace_ephemeral(transaction, workspace_id)
            }
            Self::Home => {
                mark_workspace_home(transaction, workspace_id)?;
                place_home_first(transaction, workspace_key)
            }
            Self::App(app) => mark_workspace_app(transaction, workspace_id, workspace_key, app),
        }
    }
}

/// The kind row of a new app workspace. The row of an earlier workspace of
/// the same app whose workspace closed is replaced (a reopened copy of it
/// comes back as an ordinary workspace); a live one refuses.
fn mark_workspace_app(
    transaction: &Transaction<'_>,
    workspace_id: &str,
    workspace_key: &str,
    app: &str,
) -> anyhow::Result<()> {
    anyhow::ensure!(
        live_app_workspace(transaction, app)?.is_none(),
        "bad request: app {app} already has a workspace"
    );
    transaction.execute("DELETE FROM workspace_kind WHERE kind = 'app' AND app_id = ?1", [app])?;
    transaction.execute(
        "INSERT INTO workspace_kind(workspace_id, kind, app_id, workspace_key)
         VALUES(?1, 'app', ?2, ?3)",
        [workspace_id, app, workspace_key],
    )?;
    Ok(())
}

/// The live app workspace of `app`: its public id and key.
pub(crate) fn live_app_workspace(
    connection: &Connection,
    app: &str,
) -> anyhow::Result<Option<(String, String)>> {
    Ok(connection
        .query_row(
            "SELECT k.workspace_id, rw.workspace_key
             FROM workspace_kind AS k
             JOIN resource_workspaces AS rw ON rw.public_id = k.workspace_id
             WHERE k.kind = 'app' AND k.app_id = ?1 AND rw.deleted_revision IS NULL",
            [app],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?)
}

/// The app of every live app workspace, by workspace key (the raw tree's
/// presentation snapshot). Liveness comes from the workspace registry row,
/// which the staging commit of a new app workspace writes with its kind row,
/// so the workspace's first tree delta already shows its kind (its resource
/// row comes later, with the projection).
pub(crate) fn live_app_workspaces(
    connection: &Connection,
) -> anyhow::Result<std::collections::HashMap<String, String>> {
    let mut statement = connection.prepare(
        "SELECT k.workspace_key, k.app_id
         FROM workspace_kind AS k
         JOIN workspaces AS w ON w.workspace_key = k.workspace_key
         WHERE k.kind = 'app' AND w.tombstoned = 0",
    )?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

fn mark_workspace_home(transaction: &Transaction<'_>, workspace_id: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        live_home(transaction)?.is_none(),
        "bad request: this store already has a home workspace"
    );
    transaction.execute(
        "INSERT INTO workspace_kind(workspace_id, kind) VALUES(?1, 'home')",
        [workspace_id],
    )?;
    Ok(())
}

/// The personal placement of the new home workspace: first and ungrouped,
/// with its `workspace_placement` changes queued into the creation's
/// `session.events` batch. The personal store shares the registry
/// transaction, so `personal_revision` and its journal fact move with it.
fn place_home_first(transaction: &Transaction<'_>, workspace_key: &str) -> anyhow::Result<()> {
    // The creation patch already gave home a last-place row and queued its
    // placement (personal_order::place_created_workspaces). That first
    // upsert is redundant: the upserts queued here follow it in the same
    // batch, so clients end with home at index 0.
    let local = crate::state::values::local_registry_id(transaction)?;
    let groups = crate::state::personal_state_store::workspace_group_snapshots(transaction, None)?;
    WorkspaceRegistry::set_personal_workspace_in(
        transaction,
        &local,
        workspace_key,
        PersonalWorkspaceUpdate { index: Some(0), group: Some(None), ..Default::default() },
    )?;
    // Home moves to the front, across any group with a place: publish the
    // groups whose top_index changed (personal-mixed-order-v1).
    let after = crate::state::personal_state_store::workspace_group_snapshots(transaction, None)?;
    for group in after {
        if !groups.contains(&group) {
            let id = group["id"].as_str().unwrap_or_default().to_string();
            let change = crate::state::store::state_upsert("workspace_group", &id, group);
            crate::state::closed_history_store::queue_change(transaction, &change)?;
        }
    }
    for placement in crate::state::personal_state_store::placement_snapshots(transaction)? {
        let id = crate::state::personal_state_store::placement_id(
            placement["workspace"]["session_id"].as_str().unwrap_or_default(),
            placement["workspace"]["workspace_ref"].as_str().unwrap_or_default(),
        );
        let change = crate::state::store::state_upsert("workspace_placement", &id, placement);
        crate::state::closed_history_store::queue_change(transaction, &change)?;
    }
    Ok(())
}

/// The live home workspace of this store: its public id and key.
pub(crate) fn live_home(connection: &Connection) -> anyhow::Result<Option<(String, String)>> {
    Ok(connection
        .query_row(
            "SELECT k.workspace_id, rw.workspace_key
             FROM workspace_kind AS k
             JOIN resource_workspaces AS rw ON rw.public_id = k.workspace_id
             WHERE k.kind = 'home' AND rw.deleted_revision IS NULL",
            [],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)),
        )
        .optional()?)
}

/// The kind a workspace snapshot shows in `extra.kind` and, for an app
/// workspace, its app (`extra.app`); `None` is normal.
pub(crate) fn workspace_kind(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<(String, Option<String>)>> {
    Ok(connection
        .query_row(
            "SELECT kind, app_id FROM workspace_kind WHERE workspace_id = ?1",
            [workspace_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()?)
}

/// A refused change to the home workspace.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum HomeRuleKind {
    NotClosable,
    PinnedFirst,
}

/// A refused change to the home workspace: the standard resource failure
/// (`home.not_closable`, `home.pinned_first`) and the raw `error_code`
/// (`home_not_closable`, `home_pinned_first`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct HomeRule {
    kind: HomeRuleKind,
    workspace: String,
}

impl HomeRule {
    fn new(kind: HomeRuleKind, workspace: String) -> Self {
        Self { kind, workspace }
    }

    /// The `cmux.protocol/2` catalog error code.
    pub(crate) fn code(&self) -> &'static str {
        match self.kind {
            HomeRuleKind::NotClosable => "home.not_closable",
            HomeRuleKind::PinnedFirst => "home.pinned_first",
        }
    }

    /// The raw protocol `error_code`.
    pub(crate) fn raw_code(&self) -> &'static str {
        match self.kind {
            HomeRuleKind::NotClosable => "home_not_closable",
            HomeRuleKind::PinnedFirst => "home_pinned_first",
        }
    }

    pub(crate) fn workspace(&self) -> &str {
        &self.workspace
    }
}

impl fmt::Display for HomeRule {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let (code, workspace) = (self.raw_code(), &self.workspace);
        match self.kind {
            HomeRuleKind::NotClosable => {
                write!(formatter, "{code}: the home workspace {workspace} cannot close")
            }
            HomeRuleKind::PinnedFirst => write!(
                formatter,
                "{code}: the home workspace {workspace} stays first in the top section"
            ),
        }
    }
}

impl std::error::Error for HomeRule {}

/// The standard resource failure of a refused home change.
pub(crate) fn resource_error(error: &anyhow::Error) -> Option<crate::resource::ResourceError> {
    let rule = error.downcast_ref::<HomeRule>()?;
    let details = serde_json::json!({"workspace_id": rule.workspace()});
    Some(crate::resource::ResourceError::new(rule.code(), rule.to_string(), details, false))
}

/// The raw `error_code` of a refused home change.
pub(crate) fn error_code(error: &anyhow::Error) -> Option<String> {
    error.downcast_ref::<HomeRule>().map(|rule| rule.raw_code().to_string())
}

/// Refuse to close the workspace with this key when it is the home.
pub(crate) fn refuse_close_key(connection: &Connection, workspace_key: &str) -> anyhow::Result<()> {
    match live_home(connection)? {
        Some((workspace, key)) if key == workspace_key => {
            Err(HomeRule::new(HomeRuleKind::NotClosable, workspace).into())
        }
        _ => Ok(()),
    }
}

/// Refuse to tombstone the workspace with this public id when it is the
/// home. Every durable workspace close passes here.
pub(crate) fn refuse_close_id(connection: &Connection, workspace_id: &str) -> anyhow::Result<()> {
    match live_home(connection)? {
        Some((workspace, _)) if workspace == workspace_id => {
            Err(HomeRule::new(HomeRuleKind::NotClosable, workspace).into())
        }
        _ => Ok(()),
    }
}

/// After a personal order change: the home row of the local session must be
/// ungrouped and the first ungrouped row (the top section). Grouped rows may
/// precede it. A store without a home, or a home without a row, is not
/// checked.
pub(crate) fn require_home_first(connection: &Connection) -> anyhow::Result<()> {
    let Some((workspace, key)) = live_home(connection)? else { return Ok(()) };
    let local = crate::state::values::local_registry_id(connection)?;
    let rows = read_workspaces(connection)?;
    let Some(home) =
        rows.iter().position(|row| row.session_id == local && row.workspace_key == key)
    else {
        return Ok(());
    };
    let first_ungrouped = rows.iter().position(|row| row.group.is_none());
    // Mixed order: no group slot before Home either.
    let group_before = crate::workspace_registry::personal_store::read_groups(connection)?
        .iter()
        .any(|group| group.top_index.is_some_and(|top| top <= home));
    if rows[home].group.is_none() && first_ungrouped == Some(home) && !group_before {
        Ok(())
    } else {
        Err(HomeRule::new(HomeRuleKind::PinnedFirst, workspace).into())
    }
}
