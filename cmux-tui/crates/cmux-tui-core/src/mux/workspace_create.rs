//! Empty workspace creation through the registry, ordinary and resource-effect paths.

use super::*;

impl Mux {
    /// Add an ordered workspace-registry entry without creating a PTY,
    /// screen, or pane. Detached GUI frontends use this when a user creates
    /// an empty workspace in Chrome.
    pub fn create_empty_workspace(
        &self,
        name: Option<String>,
        key: Option<String>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<WorkspacePlacement> {
        let mutation = WorkspaceMutation::daemon_local("cmux-tui");
        self.create_empty_workspace_with_mutation(name, key, None, expected_revision, &mutation)
    }

    pub fn create_empty_workspace_with_mutation(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspacePlacement> {
        self.create_empty_workspace_with_mutation_inner(
            name,
            requested_key,
            None,
            expected_generation,
            expected_revision,
            mutation,
            true,
            crate::state::home_store::EmptyWorkspaceMark::None,
        )
    }

    /// Stage an empty workspace for a resource effect. `mark` (ephemeral,
    /// or the kind row of an app workspace) is written in the same
    /// transaction, so no reader sees the workspace without it.
    pub(super) fn create_empty_workspace_for_resource_effect(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        public_id: WorkspacePublicId,
        mutation: &WorkspaceMutation,
        mark: crate::state::home_store::EmptyWorkspaceMark,
    ) -> anyhow::Result<WorkspacePlacement> {
        self.create_empty_workspace_with_mutation_inner(
            name,
            requested_key,
            Some(public_id),
            None,
            None,
            mutation,
            false,
            mark,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn create_empty_workspace_with_mutation_inner(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        requested_public_id: Option<WorkspacePublicId>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        project_resource: bool,
        mark: crate::state::home_store::EmptyWorkspaceMark,
    ) -> anyhow::Result<WorkspacePlacement> {
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name)?;
        }
        let key = match requested_key.as_ref() {
            Some(key) if key.trim().is_empty() => anyhow::bail!("workspace key cannot be empty"),
            Some(key) if !crate::workspace_registry::is_canonical_workspace_key(key) => {
                anyhow::bail!("workspace key must be a lowercase UUID")
            }
            Some(key) => key.clone(),
            None => Self::new_workspace_key()?,
        };
        Self::validate_workspace_key(&key)?;
        let requested_name = name.clone();
        let ws_id = self.next_id();
        let mut notifications = self.tree_decorations();
        // The raw tree reads an app workspace's kind from presentation; the
        // creation's delta must show it (`app-screens-v1`).
        let reloads_presentation =
            matches!(mark, crate::state::home_store::EmptyWorkspaceMark::App(_));
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut fingerprint = serde_json::json!({
            "op": "create-workspace",
            "name": requested_name,
            "requested_key": requested_key,
        });
        if let Some((field, value)) = mark.fingerprint_field() {
            fingerprint[field] = value;
        }
        if let Some(commit) = registry.replay(mutation, &fingerprint)? {
            let workspace = commit.result["workspace"]
                .as_u64()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing workspace"))?;
            let key = commit.result["key"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing key"))?
                .to_string();
            let index = commit.result["index"]
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing index"))?;
            return Ok(WorkspacePlacement {
                workspace,
                key,
                index,
                revision: commit.revision,
                replayed: true,
            });
        }
        let workspace_public_id =
            requested_public_id.map(Ok).unwrap_or_else(WorkspacePublicId::random)?;
        let (placement, delta, selection_resync) = {
            let mut state = self.lock_state_pinned(&registry).unwrap();
            if state.workspaces.len() >= WORKSPACE_REGISTRY_LIMIT {
                anyhow::bail!("workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})");
            }
            if state.workspace_by_key(&key).is_some() {
                anyhow::bail!("workspace key already exists: {key}");
            }
            let name = name.unwrap_or_else(|| Self::default_workspace_name(&state));
            let index = state.workspaces.len();
            let selection_resync = !state.workspaces.is_empty();
            let mut desired = self.registry_projection(&state);
            desired.push(RegistryWorkspace {
                id: ws_id,
                public_id: workspace_public_id.clone(),
                key: key.clone(),
                name: name.clone(),
                group_key: self.session.clone(),
            });
            let result = serde_json::json!({
                "workspace": ws_id,
                "workspace_id": workspace_public_id.as_str(),
                "key": key,
                "index": index,
            });
            let commit = if project_resource {
                registry.commit_with_active_workspace(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    &key,
                    &desired,
                    Some(&workspace_public_id),
                    &result,
                )?
            } else {
                let marked = workspace_public_id.as_str().to_string();
                let marked_key = key.clone();
                let writes = mark.writes();
                let write_mark =
                    move |tx: &rusqlite::Transaction<'_>| mark.write(tx, &marked, &marked_key);
                registry.commit_for_resource_effect_with(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    &key,
                    &desired,
                    Some(&workspace_public_id),
                    &result,
                    writes.then_some(
                        &write_mark as crate::workspace_registry::RegistryTransactionWrite<'_>,
                    ),
                )?
            };
            let committed_workspace = commit.result["workspace"]
                .as_u64()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing workspace"))?;
            let committed_key = commit.result["key"]
                .as_str()
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing key"))?
                .to_string();
            let committed_index = commit.result["index"]
                .as_u64()
                .and_then(|value| usize::try_from(value).ok())
                .ok_or_else(|| anyhow::anyhow!("stored create result is missing index"))?;
            if commit.replayed {
                return Ok(WorkspacePlacement {
                    workspace: committed_workspace,
                    key: committed_key,
                    index: committed_index,
                    revision: commit.revision,
                    replayed: true,
                });
            }
            let resource_revision = project_resource
                .then(|| registry.snapshot())
                .transpose()?
                .map(|snapshot| snapshot.resource_revision);
            if reloads_presentation {
                self.reload_presentation(&registry)?;
                notifications.presentation = self.presentation_snapshot();
            }
            state.push_workspace(Workspace {
                id: ws_id,
                public_id: workspace_public_id,
                key: key.clone(),
                name,
                screens: Vec::new(),
                active_screen: 0,
            });
            state.active_workspace = state.workspaces.len() - 1;
            state.workspace_revision = commit.revision;
            if let Some(resource_revision) = resource_revision {
                state.resource_revision = resource_revision;
            }
            let revision = commit.revision;
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::WorkspaceAdded,
                ws_id,
            )
            .expect("new empty workspace is present in tree snapshot");
            (
                WorkspacePlacement { workspace: ws_id, key, index, revision, replayed: false },
                TreeDelta {
                    kind: TreeDeltaKind::WorkspaceAdded,
                    workspace: ws_id,
                    screen: None,
                    pane: None,
                    surface: None,
                    index: Some(index),
                    entity,
                    workspace_revision: Some(revision),
                    transaction: None,
                },
                selection_resync,
            )
        };
        self.emit_committed_workspace_delta(&registry, delta, selection_resync);
        drop(registry);
        if project_resource {
            self.publish_resource_event();
        }
        Ok(placement)
    }
}
