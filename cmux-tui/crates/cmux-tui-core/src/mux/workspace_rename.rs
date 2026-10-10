//! Workspace rename: revision-checked, provider-managed and selector paths.

use super::*;

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
        let authority = self.authorize_workspace_lifecycle_mutation(
            WorkspaceMutationAuthority::Ordinary,
            "rename",
        )?;
        let result = self.rename_workspace_with_mutation_inner(
            target,
            requested_key,
            name,
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
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        Self::validate_workspace_name(&name)?;
        let fingerprint = serde_json::json!({
            "op": "rename-workspace",
            "workspace": target,
            "key": requested_key,
            "name": name,
        });
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            return workspace_mutation_result(&commit);
        }
        let (renamed, result) = {
            let mut state = self.lock_state_pinned(&registry).unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            let key = state.workspaces[index].key.clone();
            let changed = state.workspaces[index].name != name;
            let mut desired = self.registry_projection(&state);
            desired[index].name = name.clone();
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
            // The commit rides the journal writer batch: state stays held
            // across the receipt (as across a local commit's fsync), the
            // connection pin is released for the writer. If the receipt is
            // indeterminate, the next state holder applies the rename.
            let settle: crate::workspace_registry::SettleState = {
                let (key, name) = (key.clone(), name.clone());
                Box::new(move |state: &mut State, receipt| {
                    if let crate::workspace_registry::RegistryReceipt::Workspace(receipt) = receipt
                        && !receipt.commit.replayed
                        && let Some(workspace) =
                            state.workspaces.iter_mut().find(|workspace| workspace.key == key)
                    {
                        workspace.name = name;
                        state.workspace_revision = receipt.commit.revision;
                    }
                })
            };
            let receipt = registry
                .commit_registry_intent_with(
                    crate::workspace_registry::RegistryIntent::Workspace(intent),
                    || state.unpin(),
                    Some(settle),
                )?
                .into_workspace()?;
            let commit = receipt.commit;
            state.workspaces[index].name = name;
            state.workspace_revision = commit.revision;
            if let Some(resource_revision) = receipt.resource_revision {
                state.resource_revision = resource_revision;
            }
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
}
