//! Writes the workspace registry rows (keys, names and their provenance,
//! groups and order) and the commit's workspace event in the caller's
//! transaction.

use super::*;

#[allow(clippy::too_many_arguments)]
pub(super) fn commit_workspace_registry_in_transaction(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
    expected_revision: Option<u64>,
    event_kind: &str,
    workspace_key: &str,
    workspaces: &[RegistryWorkspace],
    result_json: &str,
) -> anyhow::Result<(u64, TerminalBatchClose)> {
    commit_workspace_rows_in_transaction(
        transaction,
        mutation,
        fingerprint,
        expected_revision,
        event_kind,
        workspace_key,
        workspaces,
        result_json,
    )
    .map(|(revision, terminal_batch, _)| (revision, terminal_batch))
}

/// [`commit_workspace_registry_in_transaction`], also returning the keys of
/// the desired workspaces whose row it wrote (new, moved, renamed or
/// regrouped): every other desired workspace's row was already as desired.
#[allow(clippy::too_many_arguments)]
pub(super) fn commit_workspace_rows_in_transaction(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
    expected_revision: Option<u64>,
    event_kind: &str,
    workspace_key: &str,
    workspaces: &[RegistryWorkspace],
    result_json: &str,
) -> anyhow::Result<(u64, TerminalBatchClose, HashSet<String>)> {
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    validate_workspace_key(workspace_key)?;
    // `validate_registry`, `desired_rows` and `live_rows` (a row read for each live workspace).
    #[cfg(test)]
    crate::walk_counters::workspace_list_walked(workspaces.len());
    validate_registry(workspaces)?;
    let (revision, sqlite_revision) = next_registry_revision(transaction, expected_revision)?;

    // Terminals are session-owned. Their workspace_key records their latest
    // canonical placement but is intentionally allowed to outlive that
    // workspace, so closing a workspace removes views without terminating the
    // underlying terminal.
    let terminal_batch =
        TerminalBatchClose { revision: transaction_terminal_revision(transaction)?, closed: 0 };
    // Only rows that change are written.
    let desired = desired_rows(workspaces);
    let stored = live_rows(transaction)?;
    // A key with a live row is not tombstoned: only the keys new to the
    // live set need the check (one query each, not one per workspace).
    for workspace in workspaces.iter().filter(|workspace| !stored.contains_key(&workspace.key)) {
        let was_tombstoned = transaction
            .query_row(
                "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
                [&workspace.key],
                |row| row.get::<_, i64>(0),
            )
            .optional()?;
        anyhow::ensure!(
            was_tombstoned != Some(1),
            "tombstoned workspace key cannot be reused: {}",
            workspace.key
        );
    }
    let written = match one_removed_row(&stored, &desired, workspaces)? {
        Some(removed) => {
            tombstone_row(transaction, removed.key, sqlite_revision)?;
            if removed.later > 0 {
                move_later_rows_one_down(transaction, &removed, sqlite_revision)?;
            }
            let later = workspaces.iter().skip(workspaces.len() - removed.later);
            later.map(|workspace| workspace.key.clone()).collect()
        }
        None => write_changed_rows(transaction, &stored, &desired, workspaces, sqlite_revision)?,
    };
    record_workspace_event(
        transaction,
        mutation,
        fingerprint,
        event_kind,
        workspace_key,
        result_json,
        revision,
    )?;
    Ok((revision, terminal_batch, written))
}

/// The registry revision after the stored one, checked against `expected_revision`, and that
/// revision as SQLite stores it.
fn next_registry_revision(
    transaction: &Transaction<'_>,
    expected_revision: Option<u64>,
) -> anyhow::Result<(u64, i64)> {
    let current = transaction_revision(transaction)?;
    if let Some(expected) = expected_revision
        && expected != current
    {
        anyhow::bail!("workspace revision conflict: expected {expected}, current {current}");
    }
    let revision =
        current.checked_add(1).ok_or_else(|| anyhow::anyhow!("workspace revision exhausted"))?;
    let sqlite_revision =
        i64::try_from(revision).context("workspace revision exceeds SQLite integer range")?;
    Ok((revision, sqlite_revision))
}

/// Stores `revision` as the registry's, the mutation in the ledger and the commit's workspace
/// event.
fn record_workspace_event(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
    event_kind: &str,
    workspace_key: &str,
    result_json: &str,
    revision: u64,
) -> anyhow::Result<()> {
    let sqlite_revision =
        i64::try_from(revision).context("workspace revision exceeds SQLite integer range")?;
    transaction
        .execute("UPDATE meta SET value = ?1 WHERE key = 'revision'", [revision.to_string()])?;
    let ledger = mutation_ledger::KeyedLedger::Workspace;
    let row = (fingerprint, result_json, sqlite_revision);
    mutation_ledger::insert_keyed_mutation(transaction, ledger, mutation, row.0, row.1, row.2)?;
    transaction.execute(
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
    Ok(())
}

/// A live workspace that an insert moves one place later: its row as stored, with the public id
/// of its live resource row (`None` without one: the journal cannot state it), and its new
/// position.
#[derive(Debug, Clone)]
pub(super) struct MovedWorkspace {
    pub(super) workspace: Option<RegistryWorkspace>,
    pub(super) position: usize,
}

/// [`commit_workspace_rows_in_transaction`] for a commit that adds exactly one workspace,
/// `workspace`, at `position` and changes no other workspace: it writes the new row, moves each
/// live row at or after `position` one place later (none for an append), and records the
/// event. Its work follows the rows after `position`, not the count of workspaces: no other
/// row is read. Returns the new revision and the moved workspaces, in their new order.
///
/// The positions stay contiguous: a live row must hold `position - 1` (the new row then goes
/// right after the last row before it), and the rows at or after it take one more each.
#[allow(clippy::too_many_arguments)]
pub(super) fn insert_workspace_row_in_transaction(
    transaction: &Transaction<'_>,
    mutation: &WorkspaceMutation,
    fingerprint: &str,
    expected_revision: Option<u64>,
    event_kind: &str,
    workspace: &RegistryWorkspace,
    position: usize,
    result_json: &str,
) -> anyhow::Result<(u64, Vec<MovedWorkspace>)> {
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    validate_registry(std::slice::from_ref(workspace))?;
    let (revision, sqlite_revision) = next_registry_revision(transaction, expected_revision)?;
    let stored = transaction
        .query_row(
            "SELECT tombstoned FROM workspaces WHERE workspace_key = ?1",
            [&workspace.key],
            |row| row.get::<_, i64>(0),
        )
        .optional()?;
    match stored {
        Some(1) => anyhow::bail!("tombstoned workspace key cannot be reused: {}", workspace.key),
        Some(_) => anyhow::bail!("workspace key already exists: {}", workspace.key),
        None => {}
    }
    let live_public_id = transaction
        .query_row(
            "SELECT 1 FROM resource_workspaces
             WHERE public_id = ?1 AND deleted_revision IS NULL",
            [workspace.public_id.as_str()],
            |_| Ok(()),
        )
        .optional()?;
    anyhow::ensure!(
        live_public_id.is_none(),
        "workspace public id already exists: {}",
        workspace.public_id
    );
    let sqlite_position =
        i64::try_from(position).context("workspace position exceeds SQLite range")?;
    if position > 0 {
        let before = transaction
            .query_row(
                "SELECT 1 FROM workspaces WHERE tombstoned = 0 AND position = ?1",
                [sqlite_position - 1],
                |_| Ok(()),
            )
            .optional()?;
        anyhow::ensure!(
            before.is_some(),
            "workspace position {position} is past the end of the workspace order"
        );
    }
    let moved = later_workspace_rows(transaction, sqlite_position)?;
    if !moved.is_empty() {
        // Two statements whatever the number of rows, as `move_later_rows_one_down`: each
        // later row parks at the negative of its position minus one (below zero, distinct,
        // and no live row is below zero), then takes its old position plus one.
        let parked = transaction.execute(
            "UPDATE workspaces SET position = -position - 1, updated_revision = ?1
             WHERE tombstoned = 0 AND position >= ?2",
            params![sqlite_revision, sqlite_position],
        )?;
        let placed = transaction.execute(
            "UPDATE workspaces SET position = -position
             WHERE tombstoned = 0 AND position < 0",
            [],
        )?;
        anyhow::ensure!(
            parked == moved.len() && placed == moved.len(),
            "the insert of {} moved {parked} then {placed} workspace rows, not the {} after it",
            workspace.key,
            moved.len()
        );
    }
    let (name_source, name_revision) =
        workspace_name_store::sql_name_provenance(workspace.name_source, workspace.name_revision)?;
    transaction.execute(
        "INSERT INTO workspaces(
           workspace_key, numeric_id, name, group_key, position, tombstoned,
           created_revision, updated_revision, deleted_revision,
           name_source, name_revision
         ) VALUES(?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, NULL, ?7, ?8)",
        params![
            workspace.key,
            i64::try_from(workspace.id).context("workspace id exceeds SQLite range")?,
            workspace.name,
            workspace.group_key,
            sqlite_position,
            sqlite_revision,
            name_source,
            name_revision
        ],
    )?;
    record_workspace_event(
        transaction,
        mutation,
        fingerprint,
        event_kind,
        &workspace.key,
        result_json,
        revision,
    )?;
    Ok((revision, moved))
}

/// The live rows at or after `position`, in order, each with the position it takes when a
/// workspace is inserted at `position`.
pub(super) fn later_workspace_rows(
    connection: &Connection,
    position: i64,
) -> anyhow::Result<Vec<MovedWorkspace>> {
    let mut statement = connection.prepare(&format!(
        "{STORED_WORKSPACE_SELECT} WHERE w.tombstoned = 0 AND w.position >= ?1
         ORDER BY w.position ASC"
    ))?;
    let rows = statement.query_map([position], stored_workspace_columns)?;
    let mut moved = Vec::new();
    for row in rows {
        let (stored_position, workspace) = stored_workspace(row?)?;
        moved.push(MovedWorkspace {
            workspace,
            position: stored_position.checked_add(1).context("workspace position exhausted")?,
        });
    }
    Ok(moved)
}

/// The live workspace whose live resource row has `public_id`, with its stored position, or
/// `None` when there is none: one indexed read, not a walk of the list.
pub(super) fn stored_live_workspace(
    connection: &Connection,
    public_id: &WorkspacePublicId,
) -> anyhow::Result<Option<(usize, RegistryWorkspace)>> {
    let row = connection
        .query_row(
            &format!("{STORED_WORKSPACE_SELECT} WHERE w.tombstoned = 0 AND rw.public_id = ?1"),
            [public_id.as_str()],
            stored_workspace_columns,
        )
        .optional()?;
    let Some(row) = row else { return Ok(None) };
    let (position, workspace) = stored_workspace(row)?;
    Ok(workspace.map(|workspace| (position, workspace)))
}

/// A live `workspaces` row with the public id of its live resource row, if any.
const STORED_WORKSPACE_SELECT: &str = "SELECT w.workspace_key, w.numeric_id, w.name, w.group_key,
        w.position, w.name_source, w.name_revision, rw.public_id
     FROM workspaces w
     LEFT JOIN resource_workspaces rw
       ON rw.workspace_key = w.workspace_key AND rw.deleted_revision IS NULL";

/// The columns of [`STORED_WORKSPACE_SELECT`].
type StoredWorkspaceColumns = (String, i64, String, String, i64, (String, i64), Option<String>);

fn stored_workspace_columns(row: &rusqlite::Row<'_>) -> rusqlite::Result<StoredWorkspaceColumns> {
    Ok((
        row.get(0)?,
        row.get(1)?,
        row.get(2)?,
        row.get(3)?,
        row.get(4)?,
        (row.get(5)?, row.get(6)?),
        row.get(7)?,
    ))
}

/// A row of [`STORED_WORKSPACE_SELECT`] as its position and workspace (`None` without a live
/// resource row: it has no public id).
fn stored_workspace(
    (key, numeric_id, name, group_key, position, (source, revision), public_id): StoredWorkspaceColumns,
) -> anyhow::Result<(usize, Option<RegistryWorkspace>)> {
    let (name_source, name_revision) =
        workspace_name_store::stored_name_provenance(&source, revision)?;
    let id = u64::try_from(numeric_id).context("stored workspace id is negative")?;
    let workspace = public_id
        .map(|public_id| -> anyhow::Result<RegistryWorkspace> {
            Ok(RegistryWorkspace {
                id,
                public_id: WorkspacePublicId::parse(public_id)?,
                key,
                name,
                name_source,
                name_revision,
                group_key,
            })
        })
        .transpose()?;
    let position = usize::try_from(position).context("stored workspace position is negative")?;
    Ok((position, workspace))
}

/// A live `workspaces` row as stored: numeric id, name, group key, position, name provenance
/// (source, revision).
type StoredRow = (i64, String, String, Option<i64>, (String, i64));

/// The desired workspaces by key: each one's position in the desired order and itself.
type DesiredRows<'a> = HashMap<&'a str, (usize, &'a RegistryWorkspace)>;

fn desired_rows(workspaces: &[RegistryWorkspace]) -> DesiredRows<'_> {
    workspaces
        .iter()
        .enumerate()
        .map(|(position, workspace)| (workspace.key.as_str(), (position, workspace)))
        .collect()
}

/// Every live `workspaces` row by its key, with one statement.
fn live_rows(transaction: &Transaction<'_>) -> anyhow::Result<HashMap<String, StoredRow>> {
    let mut statement = transaction.prepare(
        "SELECT workspace_key, numeric_id, name, group_key, position,
                name_source, name_revision
         FROM workspaces WHERE tombstoned = 0",
    )?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                (
                    row.get::<_, i64>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Option<i64>>(4)?,
                    (row.get::<_, String>(5)?, row.get::<_, i64>(6)?),
                ),
            ))
        })?
        .collect::<Result<HashMap<String, StoredRow>, _>>()?;
    Ok(rows)
}

/// The one row that a commit removes when it changes no other row but for its position.
struct RemovedRow<'a> {
    key: &'a str,
    /// Its stored position.
    position: i64,
    /// The desired workspaces after it: each one's row moves one position down.
    later: usize,
}

/// The row that this commit removes, when the commit is a plain removal of one workspace (a
/// close): `None` unless ALL of this holds, and the caller then writes each changed row by
/// itself ([`write_changed_rows`]).
/// - The stored live rows are the desired workspaces and exactly one more, the removed row,
///   which has a position `p` that is not negative.
/// - Each desired workspace equals its stored row in numeric id, name, group and name
///   provenance.
/// - Its stored position is its desired position `i` when `i < p`, and `i + 1` when `i >= p`.
///
/// So the live rows with a stored position above `p` are exactly the desired workspaces from `p`
/// on, each one position above its desired one, and no live row has a negative position.
fn one_removed_row<'a>(
    stored: &'a HashMap<String, StoredRow>,
    desired: &DesiredRows<'_>,
    workspaces: &[RegistryWorkspace],
) -> anyhow::Result<Option<RemovedRow<'a>>> {
    if stored.len() != workspaces.len() + 1 {
        return Ok(None);
    }
    // The desired keys are unique (`validate_registry`), so one absent stored key means that
    // every desired workspace has a stored row.
    let mut absent = stored.iter().filter(|(key, _)| !desired.contains_key(key.as_str()));
    let (Some((key, (_, _, _, Some(removed), _))), None) = (absent.next(), absent.next()) else {
        return Ok(None);
    };
    let Ok(first_later) = usize::try_from(*removed) else {
        return Ok(None);
    };
    for (position, workspace) in workspaces.iter().enumerate() {
        let Some((numeric_id, name, group_key, stored_position, (source, revision))) =
            stored.get(&workspace.key)
        else {
            return Ok(None);
        };
        let (name_source, name_revision) = workspace_name_store::sql_name_provenance(
            workspace.name_source,
            workspace.name_revision,
        )?;
        let stored_at = if position < first_later { position } else { position + 1 };
        let as_stored = i64::try_from(workspace.id).ok() == Some(*numeric_id)
            && name == &workspace.name
            && group_key == &workspace.group_key
            && *stored_position == i64::try_from(stored_at).ok()
            && source == name_source
            && *revision == name_revision;
        if !as_stored {
            return Ok(None);
        }
    }
    Ok(Some(RemovedRow {
        key,
        position: *removed,
        later: workspaces.len().saturating_sub(first_later),
    }))
}

fn tombstone_row(
    transaction: &Transaction<'_>,
    workspace_key: &str,
    sqlite_revision: i64,
) -> anyhow::Result<()> {
    transaction.execute(
        "UPDATE workspaces SET tombstoned = 1, position = NULL,
         updated_revision = ?1, deleted_revision = ?1
         WHERE workspace_key = ?2 AND tombstoned = 0",
        params![sqlite_revision, workspace_key],
    )?;
    Ok(())
}

/// Moves each live row after `removed` (already tombstoned) one position down, with two
/// statements whatever the number of rows: [`write_changed_rows`] runs two for each row, which
/// was most of the ledger part of a close that has many workspaces after the closed one.
///
/// The rows end as [`write_changed_rows`] leaves them: the new position and this commit's
/// revision; every other column of such a row is equal already ([`one_removed_row`]), and the
/// stored name needs no fence, because the desired name and its provenance are the stored ones.
///
/// The partial unique index `live_workspace_position` holds for each row that each statement
/// changes, in any order of the rows:
/// 1. Each later row takes the negative of its position. Those are below zero and differ from
///    each other, and no live row had a negative position.
/// 2. Each of them (now the only live rows below zero) takes its old position minus one. Those
///    differ from each other and are at or above the removed position, which is free: the
///    removed row has no position, and the rows before it keep theirs, below it.
///
/// Both statements are in the caller's transaction, so no negative position is committed.
fn move_later_rows_one_down(
    transaction: &Transaction<'_>,
    removed: &RemovedRow<'_>,
    sqlite_revision: i64,
) -> anyhow::Result<()> {
    let parked = transaction.execute(
        "UPDATE workspaces SET position = -position, updated_revision = ?1
         WHERE tombstoned = 0 AND position > ?2",
        params![sqlite_revision, removed.position],
    )?;
    let placed = transaction.execute(
        "UPDATE workspaces SET position = -position - 1
         WHERE tombstoned = 0 AND position < 0",
        [],
    )?;
    anyhow::ensure!(
        parked == removed.later && placed == removed.later,
        "the close of {} moved {parked} then {placed} workspace rows, not the {} after it",
        removed.key,
        removed.later
    );
    Ok(())
}

/// Writes each row that changes, by itself, and returns the keys of the desired workspaces
/// whose row it wrote. Removed rows are tombstoned and moved rows first park at a unique
/// negative slot, which releases the partial unique position index for the desired order.
fn write_changed_rows(
    transaction: &Transaction<'_>,
    stored: &HashMap<String, StoredRow>,
    desired: &DesiredRows<'_>,
    workspaces: &[RegistryWorkspace],
    sqlite_revision: i64,
) -> anyhow::Result<HashSet<String>> {
    for (workspace_key, (_, _, _, stored_position, _)) in stored {
        match desired.get(workspace_key.as_str()) {
            None => tombstone_row(transaction, workspace_key, sqlite_revision)?,
            Some((position, _)) if *stored_position != i64::try_from(*position).ok() => {
                transaction.execute(
                    "UPDATE workspaces SET position = -rowid
                     WHERE workspace_key = ?1 AND tombstoned = 0",
                    [workspace_key],
                )?;
            }
            Some(_) => {}
        }
    }
    let mut written = HashSet::new();
    for (position, workspace) in workspaces.iter().enumerate() {
        // Only a rename of the same workspace is fenced by its stored name:
        // another workspace at this key is refused by the identity checks.
        if let Some((numeric_id, name, _, _, (source, revision))) = stored.get(&workspace.key)
            && i64::try_from(workspace.id).ok() == Some(*numeric_id)
        {
            let (source, revision) =
                workspace_name_store::stored_name_provenance(source, *revision)?;
            workspace_name_store::fence_stored_name(
                Some(workspace_name_store::StoredName { name, source, revision }),
                workspace,
            )?;
        }
        let (name_source, name_revision) = workspace_name_store::sql_name_provenance(
            workspace.name_source,
            workspace.name_revision,
        )?;
        let unchanged = stored.get(&workspace.key).is_some_and(
            |(numeric_id, name, group_key, stored_position, (source, revision))| {
                i64::try_from(workspace.id).ok() == Some(*numeric_id)
                    && name == &workspace.name
                    && group_key == &workspace.group_key
                    && *stored_position == i64::try_from(position).ok()
                    && source == name_source
                    && *revision == name_revision
            },
        );
        if unchanged {
            continue;
        }
        written.insert(workspace.key.clone());
        transaction.execute(
            "INSERT INTO workspaces(
               workspace_key, numeric_id, name, group_key, position, tombstoned,
               created_revision, updated_revision, deleted_revision,
               name_source, name_revision
             ) VALUES(?1, ?2, ?3, ?4, ?5, 0, ?6, ?6, NULL, ?7, ?8)
             ON CONFLICT(workspace_key) DO UPDATE SET
               numeric_id=excluded.numeric_id,
               name=excluded.name,
               group_key=excluded.group_key,
               position=excluded.position,
               tombstoned=0,
               updated_revision=excluded.updated_revision,
               deleted_revision=NULL,
               name_source=excluded.name_source,
               name_revision=excluded.name_revision",
            params![
                workspace.key,
                i64::try_from(workspace.id).context("workspace id exceeds SQLite range")?,
                workspace.name,
                workspace.group_key,
                i64::try_from(position).context("workspace position exceeds SQLite range")?,
                sqlite_revision,
                name_source,
                name_revision
            ],
        )?;
    }
    Ok(written)
}

#[cfg(test)]
#[path = "workspace_rows_commit_tests.rs"]
mod tests;
