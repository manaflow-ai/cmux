//! The append-only path of a workspace registry commit: one new workspace at
//! its place, nothing else changed. The caller says so (`WorkspaceInsert`)
//! rather than the commit finding it out by comparing the whole list, so its
//! work follows the new workspace (and the rows after its place, none for an
//! append), not the count of workspaces: no copy of the list, no read of every
//! row, no order change naming every workspace, no digest of every workspace.
//!
//! What it writes is what the full path writes for the same commit: the new
//! row and the moved ones, the ledger and the event, the new workspace's
//! resource rows and the focus, and the journal upserts of the workspaces it
//! changes (the new one, the moved ones and the two ends of a focus move),
//! pruned against the public fold as the full path prunes them.

use super::*;
use crate::workspace_registry::workspace_rows_commit::{
    MovedWorkspace, later_workspace_rows, stored_live_workspace,
};

/// One new workspace and its place in the order (the count of workspaces for
/// an append): a commit that adds it and changes nothing else.
#[derive(Debug, Clone, Copy)]
pub(crate) struct WorkspaceInsert<'a> {
    pub(crate) workspace: &'a RegistryWorkspace,
    pub(crate) position: usize,
}

/// [`WorkspaceInsert`] as an intent holds it.
#[derive(Debug)]
pub(super) struct InsertedWorkspace {
    workspace: RegistryWorkspace,
    position: usize,
}

impl WorkspaceRegistry {
    /// [`Self::prepare_workspace_commit`] for a commit that adds one workspace and changes
    /// nothing else. It reads the frame of the focus ends only, and copies the fold's digests of
    /// the workspaces the commit changes only.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_workspace_insert(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        insert: WorkspaceInsert<'_>,
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
        project_resource: bool,
    ) -> anyhow::Result<WorkspaceCommitIntent> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        let workspace = insert.workspace;
        let (previous_topology, stated_workspaces) = if project_resource {
            let topology = self.resource_topology_for_workspace_insert(active_workspace)?;
            let position = i64::try_from(insert.position)
                .context("workspace position exceeds SQLite range")?;
            let moved = later_workspace_rows(&self.connection.get(), position)?;
            let mut ids = vec![workspace.public_id.as_str()];
            ids.extend(moved.iter().filter_map(|moved| {
                moved.workspace.as_ref().map(|workspace| workspace.public_id.as_str())
            }));
            ids.extend(
                [topology.active_workspace.as_ref(), active_workspace]
                    .into_iter()
                    .flatten()
                    .map(WorkspacePublicId::as_str),
            );
            let stated = self.stated_workspaces_of(&ids);
            (Some(topology), stated)
        } else {
            (None, None)
        };
        Ok(WorkspaceCommitIntent {
            mutation: mutation.clone(),
            fingerprint: canonical_json(fingerprint)?,
            expected_generation: expected_generation.map(str::to_string),
            generation: self.generation.clone(),
            expected_revision,
            event_kind: event_kind.to_string(),
            workspace_key: workspace.key.clone(),
            workspaces: Vec::new(),
            active_workspace: active_workspace.cloned(),
            result: result.clone(),
            result_json: canonical_json(result)?,
            project_resource,
            previous_topology,
            stated_workspaces,
            session_id: self.session_id.clone(),
            extra: None,
            insert: Some(InsertedWorkspace {
                workspace: workspace.clone(),
                position: insert.position,
            }),
        })
    }

    /// Whether the stored order holds a live row at `position` or later: one read of the live
    /// position index, not a walk. An append at the in-memory count finds none when the store
    /// and memory agree; a row there is one memory let go but the store kept (a staged create
    /// whose rollback the store refused), which only the full commit's restatement removes.
    pub(crate) fn stored_order_reaches(&self, position: usize) -> anyhow::Result<bool> {
        let position =
            i64::try_from(position).context("workspace position exceeds SQLite range")?;
        Ok(self
            .connection
            .get()
            .query_row(
                "SELECT 1 FROM workspaces WHERE tombstoned = 0 AND position >= ?1 LIMIT 1",
                [position],
                |_| Ok(()),
            )
            .optional()?
            .is_some())
    }

    /// Commit a workspace registry revision that adds `insert` and changes nothing else (see
    /// the module text): [`Self::commit_workspace_registry`] without the whole list. With
    /// `project_resource` it also writes the new workspace's resource rows and journals the
    /// change; without, it stages the row for a resource effect, as
    /// [`Self::commit_for_resource_effect_with`] does.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_workspace_insert(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        insert: WorkspaceInsert<'_>,
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
        project_resource: bool,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<RegistryCommit> {
        let intent = self.prepare_workspace_insert(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            insert,
            active_workspace,
            result,
            project_resource,
        )?;
        self.commit_workspace_intent(intent, extra)
    }
}

impl WorkspaceCommitIntent {
    /// The body of an insert commit (after the replay and generation checks of
    /// [`Self::apply`]).
    pub(super) fn apply_insert(
        &self,
        tx: &Transaction<'_>,
        extra: Option<RegistryTransactionWrite<'_>>,
        insert: &InsertedWorkspace,
    ) -> anyhow::Result<WorkspaceCommitReceipt> {
        let workspace = &insert.workspace;
        let active_workspace = self.active_workspace.as_ref();
        validate_workspace_key(&workspace.key)?;
        if self.project_resource
            && let Some(active) = active_workspace
            && active != &workspace.public_id
        {
            anyhow::ensure!(
                stored_live_workspace(tx, active)?.is_some(),
                "active workspace is absent from the desired registry: {active}"
            );
        }
        let (revision, moved) = insert_workspace_row_in_transaction(
            tx,
            &self.mutation,
            &self.fingerprint,
            self.expected_revision,
            &self.event_kind,
            workspace,
            insert.position,
            &self.result_json,
        )?;
        let mut extra_ran = false;
        if let Some(extra) = extra {
            extra(tx)?;
            extra_ran = true;
        } else if let Some(ExtraRows(extra)) = &self.extra {
            extra(tx)?;
            extra_ran = true;
        }
        let commit = RegistryCommit { revision, result: self.result.clone(), replayed: false };
        let Some(previous_topology) =
            self.previous_topology.as_ref().filter(|_| self.project_resource)
        else {
            return Ok(WorkspaceCommitReceipt { commit, resource_revision: None });
        };
        let previous_resource_revision = transaction_resource_revision(tx)?;
        let resource_revision = previous_resource_revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let sqlite_resource_revision = i64::try_from(resource_revision)
            .context("resource revision exceeds SQLite integer range")?;
        // The new row is at its place already, and each moved row at its new one (their
        // resource rows hold no position), so the order needs no change: the patch is the new
        // workspace and the focus.
        apply_resource_patch(
            tx,
            &ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: workspace.clone(),
                        position: insert.position,
                        active_screen: None,
                    },
                    ResourceChange::SetActiveWorkspace { workspace_id: active_workspace.cloned() },
                ],
            },
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
        let deltas = self.insert_deltas(tx, insert, &moved, previous_topology)?;
        let stated = self
            .stated_workspaces
            .as_ref()
            .filter(|(fold_revision, _)| *fold_revision == previous_resource_revision)
            .map(|(_, workspaces)| workspaces);
        let deltas = match stated {
            Some(stated) => {
                let changed = deltas
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|change| is_workspace_upsert(change))
                    .filter_map(|change| change.get_str("id"))
                    .collect::<HashSet<_>>();
                let keep = extra_ran.then_some(workspace.key.as_str());
                prune_stated_workspace_upserts(tx, &deltas, stated, &changed, keep)?
            }
            None => deltas,
        };
        append_resource_journal_record(
            tx,
            resource_revision,
            previous_resource_revision,
            &self.mutation.origin,
            &self.mutation.id,
            &self.event_kind,
            None,
            &self.result,
            &deltas,
        )?;
        resource_store::prune_resource_mutations(tx)?;
        Ok(WorkspaceCommitReceipt { commit, resource_revision: Some(resource_revision) })
    }

    /// The public changes of an insert, as `normalized_workspace_resource_deltas` builds them
    /// for the workspaces the full path owes: the upsert of the new workspace, of each moved
    /// one, and of the two ends of a focus move, in the order of the workspaces, then the focus
    /// move's screen and pane upserts.
    fn insert_deltas(
        &self,
        tx: &Transaction<'_>,
        insert: &InsertedWorkspace,
        moved: &[MovedWorkspace],
        before: &ResourceTopologySnapshot,
    ) -> anyhow::Result<Value> {
        let active = self.active_workspace.as_ref();
        let mut owed = vec![(insert.position, insert.workspace.clone())];
        owed.extend(moved.iter().filter_map(|moved| {
            moved.workspace.as_ref().map(|workspace| (moved.position, workspace.clone()))
        }));
        let mut focus_ends = HashSet::new();
        if before.active_workspace.as_ref() != active {
            for end in [before.active_workspace.as_ref(), active].into_iter().flatten() {
                if owed.iter().any(|(_, workspace)| &workspace.public_id == end) {
                    focus_ends.insert(end.clone());
                } else if let Some(stored) = stored_live_workspace(tx, end)? {
                    focus_ends.insert(end.clone());
                    owed.push(stored);
                }
            }
        }
        owed.sort_by_key(|(position, _)| *position);
        let active = active.map(WorkspacePublicId::as_str);
        let mut deltas = Vec::with_capacity(owed.len() + 4);
        for (position, workspace) in &owed {
            let sequence = deltas.len();
            deltas.push(workspace_upsert_delta(
                &self.session_id,
                workspace,
                *position,
                sequence,
                active,
            )?);
        }
        push_focus_move_upserts(&mut deltas, before, &focus_ends, active)?;
        Ok(Value::Array(deltas))
    }
}
