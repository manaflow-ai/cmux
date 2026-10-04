//! Split identities of the ids that only the side tables name: row 1 of a
//! column with rows, and the column of a lone column with rows.
//!
//! Every row id and column id is a split identity (plans/cmux-next/rows.md,
//! R4b: never reused). A build without `rows-v1` checks at open that the live
//! split identities are exactly the splits of each stored `layout_json` and
//! `viewport_json`, so an id that only the side tables name cannot be live.
//! It is "parked": registered with kind `split` and tombstoned in
//! `resource_identities`, and named by `resource_screen_rows`. An older build
//! sees a deleted split it never reads. This build revives a parked id when it
//! enters the stored projection again (a lone column that gains a second
//! column); a tombstoned id that no side table of the screen named before is
//! never revived.

use super::*;

/// The split ids one screen record names: in its stored projection
/// (`layout_json` and `viewport_json`), and in its side tables.
pub(in super::super) struct ScreenSplits {
    pub(in super::super) projection: Vec<String>,
    pub(in super::super) side: Vec<String>,
}

/// The column and row ids of every column with rows of `screen`.
pub(in super::super) fn side_splits(screen: &RegistryScreen) -> Vec<String> {
    let mut splits = Vec::new();
    for column in screen.viewport.columns.iter().filter(|column| column.rows.len() >= 2) {
        splits.push(column.id.to_string());
        splits.extend(column.rows.iter().map(|row| row.id.to_string()));
    }
    splits
}

/// The column and row ids the side tables hold for `screen_id`.
pub(in super::super) fn stored_side_splits(
    connection: &Connection,
    screen_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT column_id, row_id FROM resource_screen_rows WHERE screen_id = ?1
         UNION SELECT column_id, column_id FROM resource_lone_columns WHERE screen_id = ?1",
    )?;
    let mut splits = Vec::new();
    for pair in statement.query_map(params![screen_id], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    })? {
        let (column, row) = pair?;
        splits.extend([column, row]);
    }
    splits.sort();
    splits.dedup();
    Ok(splits)
}

/// `(kind, live)` of `public_id` in the identity ledger.
fn identity_state(
    connection: &Connection,
    public_id: &str,
) -> anyhow::Result<Option<(String, bool)>> {
    Ok(connection
        .query_row(
            "SELECT kind, deleted_revision FROM resource_identities WHERE public_id = ?1",
            [public_id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<i64>>(1)?.is_none())),
        )
        .optional()?)
}

/// Moves the split identities of one screen from `old` to `new`: every
/// projection split live (a parked one revived), every side-only split
/// parked, every split no longer named tombstoned.
pub(in super::super) fn register_screen_splits(
    transaction: &Transaction<'_>,
    old: ScreenSplits,
    new: ScreenSplits,
    revision: i64,
) -> anyhow::Result<()> {
    let old_side = old.side.iter().collect::<HashSet<_>>();
    for split in &new.projection {
        if old_side.contains(split)
            && identity_state(transaction, split)? == Some(("split".into(), false))
        {
            transaction.execute(
                "UPDATE resource_identities SET updated_revision = ?1, deleted_revision = NULL
                 WHERE public_id = ?2",
                params![revision, split],
            )?;
        } else {
            upsert_resource_identity(transaction, split, "split", revision)?;
        }
    }
    let projection = new.projection.iter().collect::<HashSet<_>>();
    let parked =
        new.side.iter().filter(|split| !projection.contains(split)).collect::<HashSet<_>>();
    for split in &parked {
        match identity_state(transaction, split)? {
            None => park(transaction, split, revision)?,
            Some((kind, _)) if kind != "split" => {
                anyhow::bail!("public id {split} has resource kind {kind}, not split")
            }
            Some((_, true)) => tombstone_resource_identity(transaction, split, revision)?,
            Some((_, false)) if old_side.contains(split) || old.projection.contains(split) => {}
            Some((_, false)) => anyhow::bail!("tombstoned public id cannot be reused: {split}"),
        }
    }
    for split in old.projection.iter().chain(&old.side) {
        if !projection.contains(split) && !parked.contains(split) {
            tombstone_resource_identity(transaction, split, revision)?;
        }
    }
    Ok(())
}

/// Registers `split` tombstoned: a split identity outside the projection.
fn park(transaction: &Transaction<'_>, split: &str, revision: i64) -> anyhow::Result<()> {
    transaction.execute(
        "INSERT INTO resource_identities(
           public_id, kind, created_revision, updated_revision, deleted_revision
         ) VALUES(?1, 'split', ?2, ?2, ?2)",
        params![split, revision],
    )?;
    Ok(())
}

/// Tombstones every split the side tables name for a closed screen,
/// registering one that a build before row identities never registered.
pub(in super::super) fn retire_side_splits(
    transaction: &Transaction<'_>,
    screen_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    for split in stored_side_splits(transaction, screen_id)? {
        match identity_state(transaction, &split)? {
            None => park(transaction, &split, revision)?,
            Some(_) => tombstone_resource_identity(transaction, &split, revision)?,
        }
    }
    Ok(())
}

/// The split identity rules of one live screen: every projection split is
/// live, and every side-only split is a tombstoned split identity. A side id
/// with no ledger row was written before row identities and is registered on
/// the screen's next write.
pub(in super::super) fn validate_screen_splits(
    transaction: &Transaction<'_>,
    screen_id: &str,
    layout: &RegistryLayoutNode,
    viewport: &RegistryViewport,
) -> anyhow::Result<()> {
    let mut projection = Vec::new();
    collect_screen_split_public_ids(layout, viewport, &mut projection);
    for split in &projection {
        validate_identity_state(transaction, split, "split", true)?;
    }
    for split in stored_side_splits(transaction, screen_id)? {
        if projection.contains(&split) {
            continue;
        }
        if let Some((kind, live)) = identity_state(transaction, &split)?
            && (kind != "split" || live)
        {
            anyhow::bail!("side split {split} of screen {screen_id} has kind {kind}, live={live}");
        }
    }
    Ok(())
}

#[cfg(test)]
impl WorkspaceRegistry {
    /// `(kind, live)` of `public_id` in the identity ledger, if registered.
    pub(crate) fn split_identity(&self, public_id: &str) -> anyhow::Result<Option<(String, bool)>> {
        identity_state(&self.connection, public_id)
    }

    /// Runs `sql` on the registry, to stage records that another build wrote.
    pub(crate) fn execute_sql_for_test(&self, sql: &str) -> anyhow::Result<()> {
        Ok(self.connection.execute_batch(sql)?)
    }
}
