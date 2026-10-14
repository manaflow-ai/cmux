//! Workspace name provenance columns (hq#1957): the additive migration of
//! `workspaces` and the trigger that keeps an older daemon's rename
//! user-owned.

use anyhow::Context;
use rusqlite::Connection;

use crate::resource_name::NameSource;

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
