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
    validate_identifier("mutation id", &mutation.id)?;
    validate_identifier("mutation origin", &mutation.origin)?;
    validate_workspace_key(workspace_key)?;
    validate_registry(workspaces)?;
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

    // Terminals are session-owned. Their workspace_key records their latest
    // canonical placement but is intentionally allowed to outlive that
    // workspace, so closing a workspace removes views without terminating the
    // underlying terminal.
    let terminal_batch =
        TerminalBatchClose { revision: transaction_terminal_revision(transaction)?, closed: 0 };
    // Only rows that change are written. Removed rows are tombstoned and
    // moved rows first park at a unique negative slot, which releases the
    // partial unique position index for the desired order below.
    let desired = workspaces
        .iter()
        .enumerate()
        .map(|(position, workspace)| (workspace.key.as_str(), (position, workspace)))
        .collect::<HashMap<_, _>>();
    let stored = {
        let mut statement = transaction.prepare(
            "SELECT workspace_key, numeric_id, name, group_key, position,
                    name_source, name_revision
             FROM workspaces WHERE tombstoned = 0",
        )?;
        statement
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
            .collect::<Result<HashMap<_, _>, _>>()?
    };
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
    for (workspace_key, (_, _, _, stored_position, _)) in &stored {
        match desired.get(workspace_key.as_str()) {
            None => {
                transaction.execute(
                    "UPDATE workspaces SET tombstoned = 1, position = NULL,
                     updated_revision = ?1, deleted_revision = ?1
                     WHERE workspace_key = ?2 AND tombstoned = 0",
                    params![sqlite_revision, workspace_key],
                )?;
            }
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
    Ok((revision, terminal_batch))
}
