//! Workspace registry commits (the legacy workspace ledger plus, with
//! `project_resource`, its resource projection) as journal writer intents
//! (PR5 of plans/cmux-tui-journal-write-path.md).
//!
//! The request thread validates the input, renders canonical JSON and reads
//! the previous resource topology while it holds the registry (topology
//! writers stay serialized until the receipt, so that read cannot go stale).
//! The replay check, the revision CAS and every write run inside the commit
//! transaction: the writer's SAVEPOINT, or a request-side transaction when
//! the writer does not run or the caller still holds the connection.

use super::*;

/// One prepared workspace registry commit.
#[derive(Debug)]
pub(crate) struct WorkspaceCommitIntent {
    mutation: WorkspaceMutation,
    /// Canonical fingerprint.
    fingerprint: String,
    expected_generation: Option<String>,
    /// The registry generation at prepare.
    generation: String,
    expected_revision: Option<u64>,
    event_kind: String,
    workspace_key: String,
    workspaces: Vec<RegistryWorkspace>,
    active_workspace: Option<WorkspacePublicId>,
    result: Value,
    result_json: String,
    project_resource: bool,
    /// The resource topology before this commit (with `project_resource`).
    previous_topology: Option<ResourceTopologySnapshot>,
    session_id: SessionPublicId,
    /// Rows written after the ledger, before the resource batch.
    extra: Option<ExtraRows>,
}

/// [`OwnedTransactionWrite`] with a `Debug` for the intent.
struct ExtraRows(OwnedTransactionWrite);

impl std::fmt::Debug for ExtraRows {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("ExtraRows")
    }
}

/// A committed (or replayed) workspace registry revision.
#[derive(Debug)]
pub(crate) struct WorkspaceCommitReceipt {
    pub(crate) commit: RegistryCommit,
    /// The resource revision the commit installed (`project_resource`, not
    /// replayed).
    pub(crate) resource_revision: Option<u64>,
}

impl WorkspaceRegistry {
    /// Validate a workspace registry commit and read what it needs.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn prepare_workspace_commit(
        &self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
        project_resource: bool,
    ) -> anyhow::Result<WorkspaceCommitIntent> {
        validate_identifier("mutation id", &mutation.id)?;
        validate_identifier("mutation origin", &mutation.origin)?;
        Ok(WorkspaceCommitIntent {
            mutation: mutation.clone(),
            fingerprint: canonical_json(fingerprint)?,
            expected_generation: expected_generation.map(str::to_string),
            generation: self.generation.clone(),
            expected_revision,
            event_kind: event_kind.to_string(),
            workspace_key: workspace_key.to_string(),
            workspaces: workspaces.to_vec(),
            active_workspace: active_workspace.cloned(),
            result: result.clone(),
            result_json: canonical_json(result)?,
            project_resource,
            previous_topology: project_resource
                .then(|| self.resource_topology_snapshot())
                .transpose()?,
            session_id: self.session_id.clone(),
            extra: None,
        })
    }

    /// Commit a workspace registry revision: through the journal writer when
    /// it runs and the caller does not hold the connection, else locally. A
    /// borrowed `extra` cannot leave this thread, so it commits locally.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn commit_workspace_registry(
        &mut self,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        event_kind: &str,
        workspace_key: &str,
        workspaces: &[RegistryWorkspace],
        active_workspace: Option<&WorkspacePublicId>,
        result: &Value,
        project_resource: bool,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<RegistryCommit> {
        let intent = self.prepare_workspace_commit(
            mutation,
            fingerprint,
            expected_generation,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            active_workspace,
            result,
            project_resource,
        )?;
        let Some(extra) = extra else {
            return Ok(self
                .commit_registry_intent(RegistryIntent::Workspace(intent))?
                .into_workspace()?
                .commit);
        };
        let db = self.connection.get();
        let tx = db.unchecked_transaction()?;
        let receipt = intent.apply(&tx, Some(extra))?;
        tx.commit()?;
        Ok(receipt.commit)
    }
}

impl WorkspaceCommitIntent {
    /// Write `extra` after the ledger, before the resource batch.
    #[allow(dead_code)]
    pub(crate) fn with_extra_rows(mut self, extra: OwnedTransactionWrite) -> Self {
        self.extra = Some(ExtraRows(extra));
        self
    }

    /// Resident size for the writer's durable batch byte cap.
    pub(crate) fn estimated_bytes(&self) -> usize {
        self.fingerprint
            .len()
            .saturating_add(self.result_json.len().saturating_mul(2))
            .saturating_add(self.workspaces.len().saturating_mul(512))
            .saturating_add(
                self.previous_topology
                    .as_ref()
                    .map_or(0, |topology| topology.active_screens.len().saturating_mul(128)),
            )
            .saturating_add(1024)
    }

    /// The body of a workspace registry commit inside the caller's
    /// transaction. `extra` (borrowed, local commits only) replaces the
    /// intent's own extra rows.
    pub(super) fn apply(
        &self,
        tx: &Transaction<'_>,
        extra: Option<RegistryTransactionWrite<'_>>,
    ) -> anyhow::Result<WorkspaceCommitReceipt> {
        let mutation = &self.mutation;
        let fingerprint: &str = &self.fingerprint;
        let expected_generation = self.expected_generation.as_deref();
        let expected_revision = self.expected_revision;
        let event_kind: &str = &self.event_kind;
        let workspace_key: &str = &self.workspace_key;
        let workspaces: &[RegistryWorkspace] = &self.workspaces;
        let active_workspace = self.active_workspace.as_ref();
        let result = &self.result;
        let result_json: &str = &self.result_json;
        let project_resource = self.project_resource;
        let previous_topology = &self.previous_topology;

        if let Some((stored_fingerprint, stored_result, revision)) = tx
            .query_row(
                "SELECT fingerprint, result_json, committed_revision
                 FROM mutations WHERE origin = ?1 AND mutation_id = ?2",
                params![mutation.origin, mutation.id],
                |row| {
                    Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?))
                },
            )
            .optional()?
        {
            if stored_fingerprint != fingerprint {
                anyhow::bail!(
                    "mutation {} from {} was retried with a different payload",
                    mutation.id,
                    mutation.origin
                );
            }
            return Ok(WorkspaceCommitReceipt {
                commit: RegistryCommit {
                    revision: u64::try_from(revision)
                        .context("stored mutation revision is negative")?,
                    result: serde_json::from_str(&stored_result)?,
                    replayed: true,
                },
                resource_revision: None,
            });
        }

        validate_workspace_key(workspace_key)?;
        validate_registry(workspaces)?;
        if let Some(expected) = expected_generation
            && expected != self.generation
        {
            anyhow::bail!(
                "workspace generation conflict: expected {expected}, current {}",
                self.generation
            );
        }
        if let Some(active_workspace) = active_workspace {
            anyhow::ensure!(
                workspaces.iter().any(|workspace| &workspace.public_id == active_workspace),
                "active workspace is absent from the desired registry: {active_workspace}"
            );
        }
        let (revision, _) = commit_workspace_registry_in_transaction(
            tx,
            mutation,
            &fingerprint,
            expected_revision,
            event_kind,
            workspace_key,
            workspaces,
            &result_json,
        )?;
        // Presentation rows land before the resource batch, so its restated
        // workspaces carry the new identity fields.
        if let Some(extra) = extra {
            extra(tx)?;
        } else if let Some(ExtraRows(extra)) = &self.extra {
            extra(tx)?;
        }
        let previous_resource_revision =
            project_resource.then(|| transaction_resource_revision(tx)).transpose()?;
        let resource_revision = previous_resource_revision
            .map(|revision| {
                revision
                    .checked_add(1)
                    .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))
            })
            .transpose()?;
        let sqlite_resource_revision = resource_revision
            .map(|revision| {
                i64::try_from(revision).context("resource revision exceeds SQLite integer range")
            })
            .transpose()?;
        if let (Some(previous_topology), Some(sqlite_resource_revision)) =
            (previous_topology.as_ref(), sqlite_resource_revision)
        {
            let active_screens =
                previous_topology.active_screens.iter().cloned().collect::<HashMap<_, _>>();
            let live_workspace_ids = workspaces
                .iter()
                .map(|workspace| workspace.public_id.clone())
                .collect::<HashSet<_>>();
            let mut resource_changes = workspaces
                .iter()
                .enumerate()
                .map(|(position, workspace)| ResourceChange::UpsertWorkspace {
                    workspace: workspace.clone(),
                    position,
                    active_screen: active_screens.get(&workspace.public_id).cloned().flatten(),
                })
                .collect::<Vec<_>>();
            resource_changes.extend(
                previous_topology
                    .active_screens
                    .iter()
                    .filter(|(workspace_id, _)| !live_workspace_ids.contains(workspace_id))
                    .map(|(workspace_id, _)| ResourceChange::TombstoneWorkspace {
                        workspace_id: workspace_id.clone(),
                    }),
            );
            resource_changes.push(ResourceChange::SetWorkspaceOrder {
                workspace_ids: workspaces
                    .iter()
                    .map(|workspace| workspace.public_id.clone())
                    .collect(),
            });
            resource_changes.push(ResourceChange::SetActiveWorkspace {
                workspace_id: active_workspace.cloned(),
            });
            apply_resource_patch(
                tx,
                &ResourcePatch { changes: resource_changes },
                sqlite_resource_revision,
            )?;
        }
        if project_resource {
            if let Some(active_workspace) = active_workspace {
                tx.execute(
                    "INSERT INTO meta(key, value) VALUES('active_workspace_id', ?1)
                     ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                    [active_workspace.as_str()],
                )?;
            } else {
                tx.execute("DELETE FROM meta WHERE key = 'active_workspace_id'", [])?;
            }
        }
        if let Some(resource_revision) = resource_revision {
            tx.execute(
                "UPDATE meta SET value = ?1 WHERE key = 'resource_revision'",
                [resource_revision.to_string()],
            )?;
        }
        if let (
            Some(previous_topology),
            Some(previous_resource_revision),
            Some(sqlite_resource_revision),
            Some(resource_revision),
        ) = (
            previous_topology.as_ref(),
            previous_resource_revision,
            sqlite_resource_revision,
            resource_revision,
        ) {
            insert_resource_mutation(
                tx,
                mutation,
                event_kind,
                &fingerprint,
                &result_json,
                sqlite_resource_revision,
            )?;
            let resource_deltas = normalized_workspace_resource_deltas(
                &self.session_id,
                workspaces,
                active_workspace.map(WorkspacePublicId::as_str),
                previous_topology,
            )?;
            append_resource_journal_record(
                tx,
                resource_revision,
                previous_resource_revision,
                &mutation.origin,
                &mutation.id,
                event_kind,
                None,
                result,
                &resource_deltas,
            )?;
            resource_store::prune_resource_mutations(tx)?;
        }
        Ok(WorkspaceCommitReceipt {
            commit: RegistryCommit { revision, result: result.clone(), replayed: false },
            resource_revision,
        })
    }
}
