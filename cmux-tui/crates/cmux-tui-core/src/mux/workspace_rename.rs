//! Workspace rename: revision-checked, provider-managed and selector paths.

use super::*;
use cmux_json::JsonSet as _;

impl Mux {
    pub fn rename_workspace_at_revision_as(
        &self,
        actor: &Actor,
        target: WorkspaceId,
        name: String,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                actor,
                Some(target),
                None,
                name,
                expected_revision,
                WorkspaceMutationAuthority::Ordinary,
            )?
            .map(|(_, _, revision)| revision))
    }

    #[allow(clippy::too_many_arguments)]
    pub fn rename_workspace_with_mutation(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        name: String,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        self.rename_workspace_with_name_authority(
            target,
            requested_key,
            name,
            &crate::resource_name::WorkspaceNameUpdate::user(),
            expected_generation,
            expected_revision,
            mutation,
        )
    }

    /// `rename-workspace` with its name provenance: an automatic rename
    /// (`source: auto`) never replaces a user name and loses to any rename
    /// after the name revision it read.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn rename_workspace_with_name_authority(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        name: String,
        name_authority: &crate::resource_name::WorkspaceNameUpdate,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let authority = self.authorize_workspace_lifecycle_mutation(
            WorkspaceMutationAuthority::Ordinary,
            "rename",
        )?;
        let result = self.rename_workspace_with_mutation_inner(
            target,
            requested_key,
            name,
            name_authority,
            expected_generation,
            expected_revision,
            mutation,
        );
        drop(authority);
        result
    }

    pub fn rename_provider_managed_workspace_as(
        &self,
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
        name: String,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                actor,
                Some(id),
                Some(key),
                name,
                None,
                WorkspaceMutationAuthority::TrustedProvider,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn rename_provider_managed_workspace_authorized(
        &self,
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
        name: String,
        authority: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .rename_workspace_selector_with_authority(
                actor,
                Some(id),
                Some(key),
                name,
                None,
                WorkspaceMutationAuthority::ProviderCredential(authority),
            )?
            .map(|(_, _, revision)| revision))
    }

    pub(super) fn rename_workspace_selector_with_authority(
        &self,
        actor: &Actor,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        name: String,
        expected_revision: Option<u64>,
        authorization: WorkspaceMutationAuthority<'_>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let authority = self.authorize_workspace_lifecycle_mutation(authorization, "rename")?;
        let resolved = {
            let state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            Self::resolve_workspace_selector(&state, id, key)?
        };
        let Some((resolved_target, _)) = resolved else {
            return Ok(None);
        };
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        let result = self.rename_workspace_with_mutation_inner(
            id,
            key,
            name,
            &crate::resource_name::WorkspaceNameUpdate::user(),
            None,
            expected_revision,
            &mutation,
        );
        drop(authority);
        let result = result?;
        Ok(Some((result.workspace.unwrap_or(resolved_target), result.key, result.revision)))
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn rename_workspace_with_mutation_inner(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        name: String,
        name_authority: &crate::resource_name::WorkspaceNameUpdate,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        Self::validate_workspace_name(&name)?;
        let mut fingerprint = serde_json::json!({
            "op": "rename-workspace",
            "workspace": target,
            "key": requested_key,
            "name": name,
        });
        if let Some(name_fingerprint) = name_authority.fingerprint() {
            fingerprint.set("name_authority", name_fingerprint);
        }
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            return workspace_mutation_result(&commit);
        }
        let (renamed, result) = {
            let state = self.lock_state_pinned(&registry).unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            let key = state.workspaces[index].key.clone();
            let changed = state.workspaces[index].name != name;
            let mut desired = self.registry_projection(&state);
            name_authority.apply_workspace(
                &mut desired[index],
                name.clone(),
                registry.generation(),
            )?;
            let (name_source, name_revision) =
                (desired[index].name_source, desired[index].name_revision);
            let desired_active_workspace =
                state.workspaces.get(state.active_workspace).map(|workspace| &workspace.public_id);
            let intent = registry.prepare_workspace_commit(
                mutation,
                &fingerprint,
                expected_generation,
                expected_revision,
                "workspace-renamed",
                &key,
                &desired,
                desired_active_workspace,
                &serde_json::json!({
                    "workspace": workspace_id,
                    "key": key.clone(),
                    "index": index,
                    "changed": changed,
                }),
                true,
            )?;
            // The commit rides the journal writer batch. State is released
            // before the receipt wait (the registry stays held, so no other
            // topology writer interleaves) and taken again to apply the
            // committed name; readers see the old name until the commit is
            // durable. If the receipt is indeterminate, the next state holder
            // applies the rename.
            let settle: crate::workspace_registry::SettleState = {
                let (key, name) = (key.clone(), name.clone());
                Box::new(move |state: &mut State, receipt| {
                    // Only when no later commit (built on the old name)
                    // superseded it.
                    if let crate::workspace_registry::RegistryReceipt::Workspace(receipt) = receipt
                        && !receipt.commit.replayed
                        && receipt.commit.revision > state.workspace_revision
                        && let Some(workspace) =
                            state.workspaces.iter_mut().find(|workspace| workspace.key == key)
                    {
                        workspace.name = name;
                        workspace.name_source = name_source;
                        workspace.name_revision = name_revision;
                        state.workspace_revision = receipt.commit.revision;
                    }
                })
            };
            drop(state);
            let receipt = registry
                .commit_registry_intent_with(
                    crate::workspace_registry::RegistryIntent::Workspace(intent),
                    Some(settle),
                )?
                .into_workspace()?;
            let commit = receipt.commit;
            let mut state = self.lock_state_pinned(&registry).unwrap();
            // The commit is durable: its revisions hold even if the workspace
            // left state meanwhile (no path can do that while the registry
            // is held; this keeps state and the registry agreeing anyway).
            state.workspace_revision = state.workspace_revision.max(commit.revision);
            if let Some(resource_revision) = receipt.resource_revision {
                state.resource_revision = state.resource_revision.max(resource_revision);
            }
            let index = state
                .workspaces
                .iter()
                .position(|workspace| workspace.key == key)
                .context("renamed workspace left state during its commit")?;
            state.workspaces[index].name = name;
            state.workspaces[index].name_source = name_source;
            state.workspaces[index].name_revision = name_revision;
            // A replayed receipt carries the original, possibly older,
            // revision: the max above never moves the in-memory revisions back.
            let workspace_revision = commit.revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceRenamed,
                workspace_id,
            )
            .expect("renamed workspace is present in tree snapshot");
            (
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceRenamed,
                    workspace: workspace_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: None,
                    entity,
                    workspace_revision: Some(workspace_revision),
                    transaction: None,
                },
                workspace_mutation_result(&commit)?,
            )
        };
        self.emit_committed_workspace_delta(&registry, renamed, false);
        drop(registry);
        self.publish_resource_event();
        Ok(result)
    }

    /// The resource plan of one `workspace.rename`: the durable row with its
    /// name provenance, the public delta and the in-memory apply.
    pub(super) fn workspace_rename_plan(
        &self,
        state: &State,
        registry: &WorkspaceRegistry,
        target: &WorkspacePublicId,
        index: usize,
        name: String,
        name_authority: &crate::resource_name::WorkspaceNameUpdate,
    ) -> anyhow::Result<ResourceMutationPlan> {
        let workspace = &state.workspaces[index];
        let changed = workspace.name != name;
        let active_screen =
            workspace.screens.get(workspace.active_screen).map(|screen| screen.public_id.clone());
        let mut desired = self.registry_projection(state);
        name_authority.apply_workspace(&mut desired[index], name.clone(), registry.generation())?;
        let durable = desired[index].clone();
        let (name_source, name_revision) = (durable.name_source, durable.name_revision);
        let result = serde_json::json!({
            "workspace": target.as_str(),
            "name": name,
            "changed": changed,
        });
        let deltas = Value::Array(vec![workspace_resource_upsert(
            0,
            registry.session_id().as_str(),
            target,
            &name,
            (name_source, name_revision),
            index,
            index == state.active_workspace,
        )]);
        let workspace_key = durable.key.clone();
        Ok(ResourceMutationPlan::new(
            ResourcePatch {
                changes: vec![ResourceChange::UpsertWorkspace {
                    workspace: durable,
                    position: index,
                    active_screen,
                }],
            },
            result.clone(),
            deltas,
            move |state| {
                let workspace = &mut state.workspaces[index];
                workspace.name = name;
                workspace.name_source = name_source;
                workspace.name_revision = name_revision;
            },
        )
        .with_workspace_ledger(ResourceWorkspaceLedger {
            event_kind: "workspace-renamed",
            workspace_key,
            workspaces: desired,
            legacy_result: result,
            presentation: None,
        })
        .with_metrics(ResourceMutationMetrics {
            touched_resources: 1,
            order_entries: 0,
            terminal_queries: 0,
            changed_rows: 1,
        }))
    }
}

/// The public `upsert` of one workspace, with its name provenance.
pub(super) fn workspace_resource_upsert(
    sequence: usize,
    session_id: &str,
    workspace_id: &WorkspacePublicId,
    name: &str,
    name_provenance: (crate::resource_name::NameSource, u64),
    index: usize,
    focused: bool,
) -> Value {
    let (name_source, name_revision) = name_provenance;
    serde_json::json!({
        "kind":"upsert",
        "sequence":sequence,
        "resource":"workspace",
        "id":workspace_id,
        "value":{
            "id":workspace_id,
            "session_id":session_id,
            "name":name,
            "index":index,
            "focused":focused,
            "extra":crate::resource_name::workspace_name_extra(name_source, name_revision),
        },
    })
}
