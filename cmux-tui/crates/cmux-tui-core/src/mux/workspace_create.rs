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
            true,
        )
    }

    /// Stage an empty workspace for a resource effect. `mark` (ephemeral,
    /// or the kind row of an app workspace) is written in the same
    /// transaction, so no reader sees the workspace without it. The new
    /// workspace becomes the focused one.
    pub(super) fn create_empty_workspace_for_resource_effect(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        public_id: WorkspacePublicId,
        mutation: &WorkspaceMutation,
        mark: crate::state::home_store::EmptyWorkspaceMark,
    ) -> anyhow::Result<WorkspacePlacement> {
        self.create_empty_workspace_for_resource_effect_focus(
            name,
            requested_key,
            public_id,
            mutation,
            mark,
            true,
        )
    }

    /// [`Self::create_empty_workspace_for_resource_effect`]; with `focus`
    /// false the focused workspace stays the one it was (a programmatic
    /// `workspace.create` without `focus: true`). The first workspace of a
    /// session is focused either way.
    pub(super) fn create_empty_workspace_for_resource_effect_focus(
        &self,
        name: Option<String>,
        requested_key: Option<String>,
        public_id: WorkspacePublicId,
        mutation: &WorkspaceMutation,
        mark: crate::state::home_store::EmptyWorkspaceMark,
        focus: bool,
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
            focus,
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
        focus: bool,
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
        // The delta serializes the new empty workspace only: no surface of the session.
        let mut notifications = self.tree_decorations_of_new_empty_workspace();
        let reloads_presentation = mark.shows_in_tree();
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
            if state.workspace_by_key(&key).is_some() {
                anyhow::bail!("workspace key already exists: {key}");
            }
            let name_source =
                crate::resource_name::NameSource::for_requested_workspace_name(name.as_deref());
            let name = name.unwrap_or_else(|| self.default_workspace_name(&state));
            let index = state.workspaces.len();
            let selection_resync = !state.workspaces.is_empty();
            // Without focus, the workspace that was focused stays focused.
            let kept_focus = (!focus)
                .then(|| state.workspaces.get(state.active_workspace))
                .flatten()
                .map(|workspace| (state.active_workspace, workspace.public_id.clone()));
            let active_public_id = kept_focus
                .as_ref()
                .map_or(&workspace_public_id, |(_, public_id)| public_id)
                .clone();
            // An append: the commit is told so, and its work follows this one workspace, not
            // the count of workspaces (no copy of the list, no order change naming each one).
            let created = RegistryWorkspace {
                id: ws_id,
                public_id: workspace_public_id.clone(),
                key: key.clone(),
                name: name.clone(),
                name_source,
                name_revision: 0,
                group_key: self.session.clone(),
            };
            let insert =
                crate::workspace_registry::WorkspaceInsert { workspace: &created, position: index };
            let result = serde_json::json!({
                "workspace": ws_id,
                "workspace_id": workspace_public_id.as_str(),
                "key": key,
                "index": index,
            });
            // A row the store kept past the in-memory end (a staged create whose rollback the
            // store refused) makes the lists differ: the full commit restates the order and
            // drops it. Otherwise the append's work follows this one workspace.
            let stale_rows = registry.stored_order_reaches(index)?;
            let desired = stale_rows.then(|| {
                let mut desired = self.registry_projection(&state);
                desired.push(created.clone());
                desired
            });
            let commit = match (project_resource, desired.as_deref()) {
                (true, None) => registry.commit_workspace_insert(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    insert,
                    Some(&active_public_id),
                    &result,
                    true,
                    None,
                )?,
                (true, Some(desired)) => registry.commit_with_active_workspace(
                    mutation,
                    &fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-added",
                    &key,
                    desired,
                    Some(&active_public_id),
                    &result,
                )?,
                (false, desired) => {
                    let marked = workspace_public_id.as_str().to_string();
                    let marked_key = key.clone();
                    let writes = mark.writes();
                    let write_mark =
                        move |tx: &rusqlite::Transaction<'_>| mark.write(tx, &marked, &marked_key);
                    let extra = writes.then_some(
                        &write_mark as crate::workspace_registry::RegistryTransactionWrite<'_>,
                    );
                    match desired {
                        // Staged for the resource effect, as `commit_for_resource_effect_with`.
                        None => registry.commit_workspace_insert(
                            mutation,
                            &fingerprint,
                            expected_generation,
                            expected_revision,
                            "workspace-added",
                            insert,
                            Some(&active_public_id),
                            &result,
                            false,
                            extra,
                        )?,
                        Some(desired) => registry.commit_for_resource_effect_with(
                            mutation,
                            &fingerprint,
                            expected_generation,
                            expected_revision,
                            "workspace-added",
                            &key,
                            desired,
                            Some(&active_public_id),
                            &result,
                            extra,
                        )?,
                    }
                }
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
            let resource_revision =
                project_resource.then(|| registry.resource_revision()).transpose()?;
            if reloads_presentation {
                self.reload_presentation(&registry)?;
                notifications.presentation = self.presentation_snapshot();
            }
            state.push_workspace(Workspace {
                id: ws_id,
                public_id: workspace_public_id,
                key: key.clone(),
                name,
                name_source,
                name_revision: 0,
                screens: Vec::new(),
                active_screen: 0,
            });
            state.active_workspace = match kept_focus {
                Some((active, _)) => active,
                None => state.workspaces.len() - 1,
            };
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
                    mutation: None,
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
