//! Split identities of the ids that only the side tables name: row 1 of a
//! column with rows, and the column of a lone column with rows.
//!
//! Every row id and column id is a split identity (plans/cmux-next/rows.md,
//! R4b: never reused). A build without `rows-v1` checks at open that the live
//! split identities are exactly the splits of each stored `layout_json` and
//! `viewport_json`, so an id that only the side tables name cannot be live.
//! It is parked: registered with kind `split`, tombstoned in
//! `resource_identities` (an older build sees a deleted split it never
//! reads), and flagged in `resource_parked_splits` with its screen. Only a
//! parked id is revived, when it enters its screen's stored projection again
//! (a lone column that gains a second column). An id that leaves its screen
//! loses the flag in the same commit: that tombstone is final.

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

/// The column and row ids the rows table holds for `screen_id`, and the ids
/// parked for it.
pub(in super::super) fn stored_side_splits(
    connection: &Connection,
    screen_id: &str,
) -> anyhow::Result<Vec<String>> {
    let mut statement = connection.prepare(
        "SELECT column_id FROM resource_screen_rows WHERE screen_id = ?1
         UNION SELECT row_id FROM resource_screen_rows WHERE screen_id = ?1
         UNION SELECT public_id FROM resource_parked_splits WHERE screen_id = ?1",
    )?;
    let splits = statement
        .query_map(params![screen_id], |row| row.get::<_, String>(0))?
        .collect::<Result<Vec<_>, _>>()?;
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

/// The screen `public_id` is parked for.
fn parked_screen(connection: &Connection, public_id: &str) -> anyhow::Result<Option<String>> {
    Ok(connection
        .query_row(
            "SELECT screen_id FROM resource_parked_splits WHERE public_id = ?1",
            [public_id],
            |row| row.get::<_, String>(0),
        )
        .optional()?)
}

fn unpark(transaction: &Transaction<'_>, public_id: &str) -> anyhow::Result<()> {
    transaction.execute("DELETE FROM resource_parked_splits WHERE public_id = ?1", [public_id])?;
    Ok(())
}

/// Parks `split` for `screen_id`: registered (or kept) as a tombstoned split
/// identity and flagged. Refuses a final tombstone or another screen's id.
fn park(
    transaction: &Transaction<'_>,
    screen_id: &str,
    split: &str,
    revision: i64,
) -> anyhow::Result<()> {
    match (identity_state(transaction, split)?, parked_screen(transaction, split)?) {
        (None, _) => {
            transaction.execute(
                "INSERT INTO resource_identities(
                   public_id, kind, created_revision, updated_revision, deleted_revision
                 ) VALUES(?1, 'split', ?2, ?2, ?2)",
                params![split, revision],
            )?;
        }
        (Some((kind, _)), _) if kind != "split" => {
            anyhow::bail!("public id {split} has resource kind {kind}, not split")
        }
        (Some(_), Some(owner)) if owner != screen_id => {
            anyhow::bail!("split {split} is parked for screen {owner}, not {screen_id}")
        }
        (Some((_, true)), _) => tombstone_resource_identity(transaction, split, revision)?,
        (Some((_, false)), Some(_)) => return Ok(()),
        (Some((_, false)), None) => {
            anyhow::bail!("tombstoned public id cannot be reused: {split}")
        }
    }
    transaction.execute(
        "INSERT OR REPLACE INTO resource_parked_splits(public_id, screen_id) VALUES(?1, ?2)",
        params![split, screen_id],
    )?;
    Ok(())
}

/// Moves the split identities of `screen_id` from `old` to `new`: every
/// projection split live (a split parked for this screen revived), every
/// side-only split parked, and every split no longer named tombstoned for
/// good.
pub(in super::super) fn register_screen_splits(
    transaction: &Transaction<'_>,
    screen_id: &str,
    old: ScreenSplits,
    new: ScreenSplits,
    revision: i64,
) -> anyhow::Result<()> {
    for split in &new.projection {
        if parked_screen(transaction, split)?.as_deref() == Some(screen_id) {
            transaction.execute(
                "UPDATE resource_identities SET updated_revision = ?1, deleted_revision = NULL
                 WHERE public_id = ?2 AND kind = 'split'",
                params![revision, split],
            )?;
            unpark(transaction, split)?;
        } else {
            upsert_resource_identity(transaction, split, "split", revision)?;
        }
    }
    let projection = new.projection.iter().collect::<HashSet<_>>();
    let parked =
        new.side.iter().filter(|split| !projection.contains(split)).collect::<HashSet<_>>();
    for split in &parked {
        park(transaction, screen_id, split, revision)?;
    }
    for split in old.projection.iter().chain(&old.side) {
        if !projection.contains(split) && !parked.contains(split) {
            tombstone_resource_identity(transaction, split, revision)?;
            if parked_screen(transaction, split)?.as_deref() == Some(screen_id) {
                unpark(transaction, split)?;
            }
        }
    }
    Ok(())
}

/// Tombstones for good every split the side tables name for a closed
/// screen, registering one that a build before row identities never
/// registered.
pub(in super::super) fn retire_side_splits(
    transaction: &Transaction<'_>,
    screen_id: &str,
    revision: i64,
) -> anyhow::Result<()> {
    for split in stored_side_splits(transaction, screen_id)? {
        match identity_state(transaction, &split)? {
            None => park(transaction, screen_id, &split, revision)?,
            Some(_) => tombstone_resource_identity(transaction, &split, revision)?,
        }
    }
    transaction.execute("DELETE FROM resource_parked_splits WHERE screen_id = ?1", [screen_id])?;
    Ok(())
}

/// One-time repair at open: parks the side-only ids of every live screen's
/// valid rows (the rows load keeps) that have no identity yet, or that a
/// build before parked identities tombstoned without the flag. Such an id is
/// still named by a live screen, so its tombstone was not a close.
pub(in super::super) fn repair_side_split_identities(
    transaction: &Transaction<'_>,
) -> anyhow::Result<()> {
    let has_rows = transaction
        .query_row("SELECT 1 FROM resource_screen_rows LIMIT 1", [], |_| Ok(()))
        .optional()?
        .is_some();
    if !has_rows {
        return Ok(());
    }
    let session = SessionPublicId::parse(required_meta(transaction, "session_public_id")?)?;
    let revision = i64::try_from(current_resource_revision(transaction)?)
        .context("resource revision exceeds SQLite integer range")?;
    let topology = load_resource_topology(transaction, session, String::new())?;
    for screen in &topology.screens {
        let mut projection = Vec::new();
        collect_screen_split_public_ids(
            &screen.layout,
            &screen.viewport.durable(),
            &mut projection,
        );
        for split in side_splits(screen) {
            if projection.contains(&split) {
                continue;
            }
            let screen_id = screen.public_id.as_str();
            let parked = parked_screen(transaction, &split)?;
            if parked.as_deref().is_some_and(|owner| owner != screen_id) {
                continue;
            }
            match identity_state(transaction, &split)? {
                None => park(transaction, screen_id, &split, revision)?,
                Some((kind, live)) if kind == "split" && (live || parked.is_none()) => {
                    if live {
                        tombstone_resource_identity(transaction, &split, revision)?;
                    }
                    transaction.execute(
                        "INSERT OR REPLACE INTO resource_parked_splits(public_id, screen_id)
                         VALUES(?1, ?2)",
                        params![split, screen_id],
                    )?;
                }
                _ => {}
            }
        }
    }
    Ok(())
}

/// The split identity rules of one live screen: every projection split is
/// live, and every side-only split is not live. A side id with no flag may be
/// a record a build without `rows-v1` left behind, which load drops.
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
