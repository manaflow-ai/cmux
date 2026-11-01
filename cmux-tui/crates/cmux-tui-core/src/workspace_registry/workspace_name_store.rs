//! Workspace name provenance columns (hq#1957): the additive migration of
//! `workspaces` and the trigger that keeps an older daemon's rename
//! user-owned.

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension, Transaction};
use serde_json::json;

use super::RegistryWorkspace;
use crate::resource::ResourceError;
use crate::resource_name::{NAME_PINNED, NameSource, is_default_workspace_name, name_refusal};

/// Additive migration: names written before provenance stay user-owned.
///
/// Older daemons keep opening the registry and omit both columns on their
/// writes; the trigger makes such a rename a user rename that advances the
/// name revision, so a pending automatic callback cannot overwrite it.
pub(crate) fn migrate_workspace_name_authority(connection: &Connection) -> anyhow::Result<()> {
    let columns = connection
        .prepare("PRAGMA table_info(workspaces)")?
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<Result<Vec<_>, _>>()?;
    if !columns.iter().any(|column| column == "name_source") {
        connection.execute_batch(
            "ALTER TABLE workspaces ADD COLUMN name_source TEXT NOT NULL DEFAULT 'user';",
        )?;
    }
    if !columns.iter().any(|column| column == "name_revision") {
        connection.execute_batch(
            "ALTER TABLE workspaces ADD COLUMN name_revision INTEGER NOT NULL DEFAULT 0;",
        )?;
    }
    connection.execute_batch(
        "CREATE TRIGGER IF NOT EXISTS workspace_legacy_name_owner
         AFTER UPDATE OF name ON workspaces
         WHEN NEW.name IS NOT OLD.name AND NEW.name_revision = OLD.name_revision
         BEGIN
           UPDATE workspaces
           SET name_source = 'user', name_revision = OLD.name_revision + 1
           WHERE workspace_key = NEW.workspace_key;
         END;",
    )?;
    // Cmd-N used to send the daemon's own `workspace-N` as a requested
    // name, stored as user-owned, so auto-naming never touched it. A name
    // still at revision 0 was never renamed (every rename advances it), so a
    // default-shaped one hands back to the automatic namer.
    connection.execute(
        "UPDATE workspaces SET name_source = 'auto'
         WHERE name_source = 'user' AND name_revision = 0
           AND name GLOB 'workspace-[0-9]*' AND name NOT GLOB 'workspace-*[^0-9]*'",
        [],
    )?;
    Ok(())
}

/// The provenance a `workspaces` row stores.
pub(crate) fn stored_name_provenance(
    source: &str,
    revision: i64,
) -> anyhow::Result<(NameSource, u64)> {
    let revision = u64::try_from(revision).context("negative workspace name revision")?;
    Ok((NameSource::from_stored(source), revision))
}

/// The provenance columns a `workspaces` write stores.
pub(crate) fn sql_name_provenance(
    source: NameSource,
    revision: u64,
) -> anyhow::Result<(&'static str, i64)> {
    let revision =
        i64::try_from(revision).context("workspace name revision exceeds SQLite range")?;
    Ok((source.as_str(), revision))
}

/// The name a `workspaces` row stores, as the commit's transaction reads it.
pub(crate) struct StoredName<'a> {
    pub(crate) name: &'a str,
    pub(crate) source: NameSource,
    pub(crate) revision: u64,
}

/// Refuses a workspace write whose name provenance storage has moved past.
///
/// The rename checks run against memory; this repeats them against the row
/// inside the commit's transaction, so a rename stored since memory was read
/// (another writer, or an older daemon through the trigger) wins. A write that
/// keeps the stored provenance passes; a rename must advance it by exactly one
/// revision; anything else is `revision.conflict`. An automatic rename over a
/// stored user name is refused as in memory.
pub(crate) fn fence_stored_name(
    stored: Option<StoredName<'_>>,
    desired: &RegistryWorkspace,
) -> anyhow::Result<()> {
    let Some(stored) = stored else {
        return Ok(());
    };
    let same_name = stored.name == desired.name;
    if desired.name_revision == stored.revision {
        if same_name && desired.name_source == stored.source {
            return Ok(());
        }
        // Memory renamed from the revision before; storage renamed differently.
        return Err(ResourceError::revision_conflict(
            desired.name_revision.saturating_sub(1),
            stored.revision,
        )
        .into());
    }
    // The revision the writer read: memory's own when it lags, else the one
    // its rename advanced from.
    let read = if desired.name_revision < stored.revision {
        desired.name_revision
    } else {
        desired.name_revision - 1
    };
    if read != stored.revision {
        return Err(ResourceError::revision_conflict(read, stored.revision).into());
    }
    // A never-renamed `workspace-N` is unnamed whatever source it was stored with (#26680),
    // as `NameUpdate::apply_workspace` judges it in memory.
    let unnamed = stored.name.trim().is_empty()
        || (stored.revision == 0 && is_default_workspace_name(stored.name));
    if desired.name_source == NameSource::Auto
        && !same_name
        && stored.source == NameSource::User
        && !unnamed
    {
        return Err(name_refusal(
            "workspace.rename",
            json!({"workspace":desired.public_id}),
            NAME_PINNED,
        )
        .into());
    }
    Ok(())
}

/// [`fence_stored_name`] against the live row for `desired.key`.
pub(crate) fn fence_stored_row(
    transaction: &Transaction<'_>,
    desired: &RegistryWorkspace,
) -> anyhow::Result<()> {
    let stored = transaction
        .query_row(
            "SELECT name, name_source, name_revision FROM workspaces
             WHERE workspace_key = ?1 AND tombstoned = 0",
            [&desired.key],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?)),
        )
        .optional()?;
    let Some((name, source, revision)) = stored else {
        return Ok(());
    };
    let (source, revision) = stored_name_provenance(&source, revision)?;
    fence_stored_name(Some(StoredName { name: &name, source, revision }), desired)
}
