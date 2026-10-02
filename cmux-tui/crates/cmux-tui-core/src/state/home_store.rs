//! `workspace-kind-v1`: the home workspace record (plans/cmux-next/home.md
//! section 7). A workspace is `normal` unless a row here marks it `home`.
//!
//! Owner rules, all enforced in the store:
//! - At most one home per store: a unique index on `kind`, and
//!   `workspace.ensure_home` replays the existing home.
//! - `kind` is written only in the commit that creates the workspace, and
//!   never changes after.
//! - The home workspace is never closed: every close path refuses it with
//!   `home.not_closable` before it ends a terminal, and the tombstone of
//!   the durable row refuses it too.
//! - It stays first in the personal order: a placement that moves it away
//!   from index 0 or into a group, or puts another workspace before it, is
//!   refused with `home.pinned_first`.
//!
//! The store never reads conversation content.

use std::fmt;

use rusqlite::{Connection, OptionalExtension, Transaction};

use crate::workspace_registry::personal_store::read_workspaces;

pub(crate) const WORKSPACE_KIND_CAPABILITY: &str = "workspace-kind-v1";
pub(crate) const HOME_KIND: &str = "home";
/// The fixed idempotency key and correlation key of the home creation.
pub(crate) const HOME_CREATION_KEY: &str = "home";

pub(crate) fn create_home_schema(transaction: &Transaction<'_>) -> anyhow::Result<()> {
    transaction.execute_batch(
        "CREATE TABLE IF NOT EXISTS workspace_kind (
           workspace_id TEXT PRIMARY KEY NOT NULL,
           kind TEXT NOT NULL CHECK(kind = 'home')
         );
         CREATE UNIQUE INDEX IF NOT EXISTS workspace_kind_one_home ON workspace_kind(kind);",
    )?;
    Ok(())
}

/// The state row an empty workspace creation writes in its own commit.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum EmptyWorkspaceMark {
    #[default]
    None,
    Ephemeral,
    Home,
}

impl EmptyWorkspaceMark {
    pub(crate) fn ephemeral(ephemeral: bool) -> Self {
        if ephemeral { Self::Ephemeral } else { Self::None }
    }

    pub(crate) fn writes(self) -> bool {
        self != Self::None
    }

    /// The field the creation fingerprint carries for this mark.
    pub(crate) fn fingerprint_field(self) -> Option<(&'static str, serde_json::Value)> {
        match self {
            Self::None => None,
            Self::Ephemeral => Some(("ephemeral", serde_json::Value::Bool(true))),
            Self::Home => Some(("kind", serde_json::Value::String(HOME_KIND.to_string()))),
        }
    }

    pub(crate) fn write(
        self,
        transaction: &Transaction<'_>,
        workspace_id: &str,
    ) -> anyhow::Result<()> {
        match self {
            Self::None => Ok(()),
            Self::Ephemeral => {
                crate::state::store::mark_workspace_ephemeral(transaction, workspace_id)
            }
            Self::Home => mark_workspace_home(transaction, workspace_id),
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
                "{code}: the home workspace {workspace} stays first in the personal order"
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
/// the first row and ungrouped. A home without a row yet (the placement
/// commit of `workspace.ensure_home` has not run) is not checked.
pub(crate) fn require_home_first(connection: &Connection) -> anyhow::Result<()> {
    let Some((workspace, key)) = live_home(connection)? else { return Ok(()) };
    let local = crate::state::values::local_registry_id(connection)?;
    let rows = read_workspaces(connection)?;
    let Some(home) = rows.iter().find(|row| row.session_id == local && row.workspace_key == key)
    else {
        return Ok(());
    };
    if home.index == 0 && home.group.is_none() {
        Ok(())
    } else {
        Err(HomeRule::new(HomeRuleKind::PinnedFirst, workspace).into())
    }
}

/// Whether the home row of the local session is first and ungrouped.
pub(crate) fn home_is_first(connection: &Connection, workspace_key: &str) -> anyhow::Result<bool> {
    let local = crate::state::values::local_registry_id(connection)?;
    Ok(read_workspaces(connection)?
        .iter()
        .find(|row| row.session_id == local && row.workspace_key == workspace_key)
        .is_some_and(|row| row.index == 0 && row.group.is_none()))
}
