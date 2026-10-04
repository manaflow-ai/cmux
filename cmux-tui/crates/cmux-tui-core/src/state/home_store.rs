//! `workspace-kind-v1`: the home workspace record (plans/cmux-next/home.md
//! section 7). A workspace is `normal` unless a row here marks it `home`,
//! or `app_tabs`, the companion of an app workspace (`app-screens-v1`,
//! state/app_screens_store.rs).
//!
//! Owner rules, all enforced in the store:
//! - At most one home per store: a partial unique index on `kind`, and
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

/// The one kind table: `home` (at most one) and `app_tabs`, the companion
/// workspace of an app workspace (`app-screens-v1`: one per app, with its
/// default name and whether a rename replaced it).
const WORKSPACE_KIND_TABLE: &str = "(
           workspace_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL CHECK(kind IN ('home', 'app_tabs')),
           app_id TEXT,
           default_name TEXT,
           renamed INTEGER NOT NULL DEFAULT 0 CHECK(renamed IN (0, 1)),
           CHECK((kind = 'home' AND app_id IS NULL AND default_name IS NULL)
              OR (kind = 'app_tabs' AND app_id IS NOT NULL AND default_name IS NOT NULL))
         )";

pub(crate) fn create_home_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    let columns = transaction
        .prepare("SELECT name FROM pragma_table_info('workspace_kind')")?
        .query_map([], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
    if columns.is_empty() {
        transaction
            .execute_batch(&format!("CREATE TABLE workspace_kind {WORKSPACE_KIND_TABLE};"))?;
    } else if !columns.iter().any(|column| column == "app_id") {
        // The table of builds before `app_tabs` (kind CHECK = 'home', a
        // unique index on `kind`): rebuilt in this transaction, rows kept.
        transaction.execute_batch(&format!(
            "CREATE TABLE workspace_kind_next {WORKSPACE_KIND_TABLE};
             INSERT INTO workspace_kind_next(workspace_id, kind)
               SELECT workspace_id, kind FROM workspace_kind;
             DROP TABLE workspace_kind;
             ALTER TABLE workspace_kind_next RENAME TO workspace_kind;"
        ))?;
    }
    transaction.execute_batch(
        "CREATE UNIQUE INDEX IF NOT EXISTS workspace_kind_one_home
           ON workspace_kind(kind) WHERE kind = 'home';
         CREATE UNIQUE INDEX IF NOT EXISTS workspace_kind_one_app_tabs
           ON workspace_kind(app_id) WHERE kind = 'app_tabs';",
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
    /// `app-screens-v1`: an empty workspace of kind `app` for this app, as
    /// builds before the one-commit app workspace creation left it (tests
    /// of the resume path).
    #[cfg(test)]
    App(String),
    /// `app-screens-v1`: the companion of the app workspace `app_workspace`
    /// (public id) for `app`, named `default_name` by the daemon and placed
    /// directly after it (state/app_home.rs).
    Companion {
        app: String,
        app_workspace: String,
        default_name: String,
    },
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
            #[cfg(test)]
            Self::App(app) => Some(("app", serde_json::Value::String(app.clone()))),
            Self::Companion { app, .. } => {
                Some(("companion_of", serde_json::Value::String(app.clone())))
            }
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
            #[cfg(test)]
            Self::App(app) => {
                crate::state::app_screens_store::write_app_workspace(transaction, workspace_id, app)
            }
            Self::Companion { app, app_workspace, default_name } => {
                let changes = crate::state::app_screens::home::write_companion_mark(
                    transaction,
                    app,
                    app_workspace,
                    workspace_id,
                    workspace_key,
                    default_name,
                )?;
                for change in &changes {
                    crate::state::closed_history_store::queue_change(transaction, change)?;
                }
                Ok(())
            }
        }
    }
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
    let local = crate::state::values::local_registry_id(transaction)?;
    WorkspaceRegistry::set_personal_workspace_in(
        transaction,
        &local,
        workspace_key,
        PersonalWorkspaceUpdate { index: Some(0), group: Some(None), ..Default::default() },
    )?;
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

/// The kind a workspace snapshot shows in `extra.kind`; `None` is normal.
pub(crate) fn workspace_kind(
    connection: &Connection,
    workspace_id: &str,
) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT kind FROM workspace_kind WHERE workspace_id = ?1",
            [workspace_id],
            |row| row.get::<_, String>(0),
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
    if rows[home].group.is_none() && first_ungrouped == Some(home) {
        Ok(())
    } else {
        Err(HomeRule::new(HomeRuleKind::PinnedFirst, workspace).into())
    }
}
