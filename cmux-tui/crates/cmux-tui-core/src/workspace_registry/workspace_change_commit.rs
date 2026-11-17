//! The body of a workspace registry commit that changes a few workspaces
//! ([`ChangedWorkspaces`]): what [`WorkspaceCommitIntent::apply`] does for the
//! whole desired registry, restricted to the rows the commit changes.
//!
//! The whole-registry commit reads every stored workspace row to find the
//! ones that differ, upserts the resource row of each written workspace,
//! orders every workspace again and builds one public upsert per workspace,
//! then drops the ones the journal states already. With the preconditions
//! `prepare_workspace_change` checks, the rows outside the change are the
//! ones that commit finds equal and drops, so this commit writes and
//! journals the same rows and changes, reading only the changed ones.

use super::*;

impl WorkspaceCommitIntent {
    pub(super) fn apply_changed(
        &self,
        tx: &Transaction<'_>,
        extra: Option<RegistryTransactionWrite<'_>>,
        changed: &ChangedWorkspaces,
    ) -> anyhow::Result<WorkspaceCommitReceipt> {
        let workspace_key: &str = &self.workspace_key;
        let active_workspace = self.active_workspace.as_ref();
        let previous_topology =
            self.previous_topology.as_ref().context("a workspace change has no topology")?;
        let (fold_revision, stated) =
            self.stated_workspaces.as_ref().context("a workspace change has no journal fold")?;
        if let Some(active_workspace) = active_workspace {
            anyhow::ensure!(
                changed.rows.iter().any(|(_, workspace)| &workspace.public_id == active_workspace),
                "active workspace is absent from the changed workspaces: {active_workspace}"
            );
        }
        let whole_rows = self
            .whole_check
            .as_ref()
            .map(|check| rows_a_whole_commit_writes(tx, &check.workspaces))
            .transpose()?;
        let (revision, written) = commit_changed_workspace_rows_in_transaction(
            tx,
            &self.mutation,
            &self.fingerprint,
            self.expected_revision,
            &self.event_kind,
            workspace_key,
            changed,
            &self.result_json,
        )?;
        // As in the whole-registry commit: presentation rows before the resource batch.
        let mut extra_ran = false;
        if let Some(extra) = extra {
            extra(tx)?;
            extra_ran = true;
        } else if let Some(ExtraRows(extra)) = &self.extra {
            extra(tx)?;
            extra_ran = true;
        }
        let previous_resource_revision = transaction_resource_revision(tx)?;
        // The fold was read at the prepare, at the resource revision then; the registry is held
        // until the receipt, so no other topology commit runs in between.
        anyhow::ensure!(
            *fold_revision == previous_resource_revision,
            "the journal fold of a workspace change is at resource revision {fold_revision}, \
             the store at {previous_resource_revision}"
        );
        let resource_revision = previous_resource_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_resource_revision = i64::try_from(resource_revision)
            .context("resource revision exceeds SQLite integer range")?;
        let active_screens =
            previous_topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
        // The whole-registry commit upserts the same workspaces (each other one has its resource
        // row, as many live resource rows as live workspace rows, and an unchanged row) and
        // orders every workspace, which writes no position here: the ledger rows above hold
        // the order already, and they are checked to be contiguous there.
        let mut resource_changes = changed
            .rows
            .iter()
            .filter(|(_, workspace)| {
                written.contains(&workspace.key)
                    || !active_screens.contains_key(&workspace.public_id)
            })
            .map(|(position, workspace)| ResourceChange::UpsertWorkspace {
                workspace: workspace.clone(),
                position: *position,
                active_screen: active_screens.get(&workspace.public_id).cloned().flatten(),
            })
            .collect::<Vec<_>>();
        resource_changes
            .push(ResourceChange::SetActiveWorkspace { workspace_id: active_workspace.cloned() });
        apply_resource_patch(
            tx,
            &ResourcePatch { changes: resource_changes },
            sqlite_resource_revision,
        )?;
        if let Some(active_workspace) = active_workspace {
            tx.execute(
                "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)
                 ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                [active_workspace.as_str()],
            )?;
        } else {
            tx.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
        }
        tx.execute(
            "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
            [resource_revision.to_string()],
        )?;
        insert_resource_mutation(
            tx,
            &self.mutation,
            &self.event_kind,
            &self.fingerprint,
            &self.result_json,
            sqlite_resource_revision,
        )?;
        let resource_deltas = changed_workspace_resource_deltas(
            &self.session_id,
            changed,
            active_workspace.map(WorkspacePublicId::as_str),
            previous_topology,
        )?;
        let mut owed = changed
            .rows
            .iter()
            .filter(|(_, workspace)| {
                workspace.key == workspace_key
                    || written.contains(&workspace.key)
                    || !active_screens.contains_key(&workspace.public_id)
            })
            .map(|(_, workspace)| workspace.public_id.as_str())
            .collect::<HashSet<_>>();
        let was_active = previous_topology.active_workspace.as_ref();
        if was_active != active_workspace {
            owed.extend(
                [was_active, active_workspace].into_iter().flatten().map(WorkspacePublicId::as_str),
            );
        }
        let keep = extra_ran.then_some(workspace_key);
        let resource_deltas =
            prune_stated_workspace_upserts(tx, &resource_deltas, stated, &owed, keep)?;
        if let (Some(check), Some((whole_written, whole_tombstoned))) =
            (self.whole_check.as_deref(), whole_rows)
        {
            anyhow::ensure!(
                whole_written == written && whole_tombstoned.is_empty(),
                "cross-check: a workspace change wrote rows {written:?}, the whole-registry \
                 commit writes {whole_written:?} and tombstones {whole_tombstoned:?}"
            );
            let whole = whole_registry_journal_changes(
                tx,
                &self.session_id,
                check,
                active_workspace,
                workspace_key,
                &whole_written,
                keep,
            )?;
            anyhow::ensure!(
                whole == resource_deltas,
                "cross-check: a workspace change journals {resource_deltas}, the whole-registry \
                 commit {whole}"
            );
        }
        append_resource_journal_record(
            tx,
            resource_revision,
            previous_resource_revision,
            &self.mutation.origin,
            &self.mutation.id,
            &self.event_kind,
            None,
            &self.result,
            &resource_deltas,
        )?;
        resource_store::prune_resource_mutations(tx)?;
        Ok(WorkspaceCommitReceipt {
            commit: RegistryCommit { revision, result: self.result.clone(), replayed: false },
            resource_revision: Some(resource_revision),
            #[cfg(test)]
            registry_rows: 0,
        })
    }
}

/// The journal changes of the whole-registry commit `check` stands for, as
/// [`WorkspaceCommitIntent::apply`] prunes them with its fold, given the rows it writes.
fn whole_registry_journal_changes(
    tx: &Transaction<'_>,
    session_id: &SessionPublicId,
    check: &WholeRegistryCheck,
    active_workspace: Option<&WorkspacePublicId>,
    workspace_key: &str,
    written: &HashSet<String>,
    keep: Option<&str>,
) -> anyhow::Result<Value> {
    let deltas = normalized_workspace_resource_deltas(
        session_id,
        &check.workspaces,
        active_workspace.map(WorkspacePublicId::as_str),
        &check.topology,
    )?;
    let resourced = check
        .topology
        .active_screens
        .iter()
        .map(|(workspace, _)| workspace)
        .collect::<HashSet<_>>();
    let mut owed = check
        .workspaces
        .iter()
        .filter(|workspace| {
            workspace.key == workspace_key
                || written.contains(&workspace.key)
                || !resourced.contains(&workspace.public_id)
        })
        .map(|workspace| workspace.public_id.as_str())
        .collect::<HashSet<_>>();
    let was_active = check.topology.active_workspace.as_ref();
    if was_active != active_workspace {
        owed.extend(
            [was_active, active_workspace].into_iter().flatten().map(WorkspacePublicId::as_str),
        );
    }
    prune_stated_workspace_upserts(tx, &deltas, &check.stated, &owed, keep)
}

/// `normalized_workspace_resource_deltas` of the changed rows: one upsert of each of them, at
/// its desired index, in position order, then the focus move of the screens and panes at both
/// ends. A change closes no workspace, so it deletes nothing.
fn changed_workspace_resource_deltas(
    session_id: &SessionPublicId,
    changed: &ChangedWorkspaces,
    active_workspace: Option<&str>,
    before: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let mut deltas = changed
        .rows
        .iter()
        .map(|(index, workspace)| {
            schema::workspace_upsert_delta(*index, session_id, *index, workspace, active_workspace)
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let live = changed
        .rows
        .iter()
        .map(|(_, workspace)| workspace.public_id.clone())
        .collect::<HashSet<_>>();
    push_focus_move_upserts(&mut deltas, before, &live, active_workspace)?;
    Ok(Value::Array(deltas))
}
