//! Closing tree targets: surface, pane, screen and workspace closes, including provider-managed and resource-effect paths.

use super::*;

impl Mux {
    pub(crate) fn close_surface_for_resource_effect(
        &self,
        target: SurfaceId,
    ) -> anyhow::Result<bool> {
        Ok(self.remove_surface_after_registry(target))
    }

    pub(super) fn remove_surface_after_registry(&self, target: SurfaceId) -> bool {
        let notifications = self.tree_decorations();
        let remove = || {
            let mut state = self.state.lock().unwrap();
            let selection_before = active_tree_selection(&state);
            let changed_screen = surface_screen_id(&state, target);
            let delta = close_surface_delta(&state, &notifications, target);
            let (removed, split_index_dirty) = remove_surface(self, &mut state, target);
            if split_index_dirty {
                Self::rebuild_split_screen_index(&mut state);
            }
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync =
                empty_revision.is_none() && selection_before != active_tree_selection(&state);
            let changed = removed.is_some() || delta.is_some();
            (
                removed,
                changed_screen.into_iter().collect::<Vec<_>>(),
                empty_revision,
                delta,
                selection_resync,
                changed,
            )
        };
        let (removed, changed_screens, empty_revision, delta, selection_resync, changed) = loop {
            let Some(workspace) = self.surface_workspace(target) else {
                break remove();
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.surface_workspace(target) != Some(workspace) {
                drop(workspace_lifecycle);
                continue;
            }
            let result = remove();
            drop(workspace_lifecycle);
            break result;
        };
        if let Some(surface) = &removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        if let Some(delta) = delta {
            self.emit_tree_delta(delta, selection_resync);
        } else if removed.is_some() {
            self.emit(MuxEvent::TreeChanged);
        }
        if removed.is_some() || !changed_screens.is_empty() {
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
        changed
    }

    /// Close a pane or screen while holding the target workspace's lifecycle
    /// lock. Tabs are detached view items; terminal content remains in the
    /// catalog until an explicit terminal close.
    pub(super) fn close_tree_target(&self, target: TreeCloseTarget) -> anyhow::Result<bool> {
        let notifications = self.tree_decorations();
        let result = loop {
            let Some(workspace) =
                self.with_state(|state| Self::workspace_for_tree_target_in_state(state, target))
            else {
                return Ok(false);
            };
            let lifecycle = self.workspace_lifecycle(workspace);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            if self.with_state(|state| Self::workspace_for_tree_target_in_state(state, target))
                != Some(workspace)
            {
                drop(workspace_lifecycle);
                continue;
            }
            let result = (|| -> anyhow::Result<Option<_>> {
                let mut state = self.state.lock().unwrap();
                let selection_before = active_tree_selection(&state);
                let (tabs, delta) = match target {
                    TreeCloseTarget::Pane(target) => {
                        let Some(pane) = state.panes.get(&target) else { return Ok(None) };
                        (
                            pane.tabs.clone(),
                            close_pane_delta(&state, &notifications, target)
                                .expect("live pane has a close delta"),
                        )
                    }
                    TreeCloseTarget::Screen(target) => {
                        let Some(screen) = state
                            .workspaces
                            .iter()
                            .flat_map(|workspace| &workspace.screens)
                            .find(|screen| screen.id == target)
                        else {
                            return Ok(None);
                        };
                        (
                            screen_tabs(&state, screen),
                            close_screen_delta(&state, &notifications, target)
                                .expect("live screen has a close delta"),
                        )
                    }
                };
                let changed_screens = unique_screen_ids(
                    tabs.iter().filter_map(|surface| surface_screen_id(&state, *surface)),
                );
                let mut removed = Vec::new();
                let mut split_index_dirty = false;
                for surface in tabs {
                    let (surface, topology_changed) = remove_surface(self, &mut state, surface);
                    split_index_dirty |= topology_changed;
                    if let Some(surface) = surface {
                        removed.push(surface);
                    }
                }
                if split_index_dirty {
                    Self::rebuild_split_screen_index(&mut state);
                }
                let tree_removed = match target {
                    TreeCloseTarget::Pane(target) => !state.panes.contains_key(&target),
                    TreeCloseTarget::Screen(target) => !state
                        .workspaces
                        .iter()
                        .flat_map(|workspace| &workspace.screens)
                        .any(|screen| screen.id == target),
                };
                let empty_revision =
                    state.workspaces.is_empty().then_some(state.workspace_revision);
                let selection_resync =
                    empty_revision.is_none() && selection_before != active_tree_selection(&state);
                Ok(Some((
                    removed,
                    changed_screens,
                    empty_revision,
                    delta,
                    tree_removed,
                    selection_resync,
                )))
            })();
            let result = result?;
            drop(workspace_lifecycle);
            break result;
        };
        let Some((removed, changed_screens, empty_revision, delta, tree_removed, selection_resync)) =
            result
        else {
            return Ok(false);
        };
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        if tree_removed {
            self.emit_tree_delta(delta, selection_resync);
            for screen in changed_screens {
                self.emit(MuxEvent::LayoutChanged(screen));
            }
        }
        self.emit_empty_if_current(empty_revision);
        Ok(true)
    }

    pub(crate) fn close_pane_for_resource_effect(&self, target: PaneId) -> anyhow::Result<bool> {
        self.close_tree_target(TreeCloseTarget::Pane(target))
            .with_context(|| format!("close pane {target}"))
    }

    pub(crate) fn close_screen_for_resource_effect(
        &self,
        target: ScreenId,
    ) -> anyhow::Result<bool> {
        self.close_tree_target(TreeCloseTarget::Screen(target))
            .with_context(|| format!("close screen {target}"))
    }

    /// Close a workspace and every screen/pane/tab in it, as `actor`.
    pub fn close_workspace_as(&self, actor: &Actor, target: WorkspaceId) -> bool {
        self.close_workspace_at_revision_as(actor, target, None)
            .map(|revision| revision.is_some())
            .unwrap_or(false)
    }

    /// Atomically close one workspace if the caller's registry snapshot is
    /// still current. Returns the resulting revision when the workspace was
    /// present and closed.
    pub fn close_workspace_at_revision_as(
        &self,
        actor: &Actor,
        target: WorkspaceId,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_at_revision(actor, Some(target), None, expected_revision)?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn close_workspace_selector_at_revision(
        &self,
        actor: &Actor,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        expected_revision: Option<u64>,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let authority = WorkspaceMutationAuthority::Ordinary;
        self.close_workspace_selector_with_authority(
            actor,
            id,
            key,
            expected_revision,
            authority,
            true,
        )
    }

    pub(crate) fn close_workspace_at_revision_for_resource_effect(
        &self,
        actor: &Actor,
        target: WorkspaceId,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                actor,
                Some(target),
                None,
                None,
                WorkspaceMutationAuthority::Ordinary,
                false,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub fn close_workspace_with_mutation(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let authority = self.authorize_workspace_lifecycle_mutation(
            WorkspaceMutationAuthority::Ordinary,
            "close",
        )?;
        let result = self.close_workspace_with_mutation_inner(
            target,
            requested_key,
            expected_generation,
            expected_revision,
            mutation,
            true,
        );
        drop(authority);
        result
    }

    pub fn close_provider_managed_workspace_as(
        &self,
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                actor,
                Some(id),
                Some(key),
                None,
                WorkspaceMutationAuthority::TrustedProvider,
                true,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub(crate) fn close_provider_managed_workspace_authorized(
        &self,
        actor: &Actor,
        id: WorkspaceId,
        key: &str,
        authority: &str,
    ) -> anyhow::Result<Option<u64>> {
        Ok(self
            .close_workspace_selector_with_authority(
                actor,
                Some(id),
                Some(key),
                None,
                WorkspaceMutationAuthority::ProviderCredential(authority),
                true,
            )?
            .map(|(_, _, revision)| revision))
    }

    pub(super) fn close_workspace_selector_with_authority(
        &self,
        actor: &Actor,
        id: Option<WorkspaceId>,
        key: Option<&str>,
        expected_revision: Option<u64>,
        authorization: WorkspaceMutationAuthority<'_>,
        project_resource: bool,
    ) -> anyhow::Result<Option<(WorkspaceId, String, u64)>> {
        let _creation_handoff =
            project_resource.then(|| self.resource_creation_handoff.lock().unwrap());
        let _creation_fence =
            project_resource.then(|| self.resource_creation_execution.lock().unwrap());
        let authority = self.authorize_workspace_lifecycle_mutation(authorization, "close")?;
        let resolved = {
            let state = self.state.lock().unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            Self::resolve_workspace_selector(&state, id, key)?
        };
        let Some((resolved_target, _)) = resolved else {
            return Ok(None);
        };
        let mutation = WorkspaceMutation::local("cmux-tui", actor.clone());
        let result = self.close_workspace_with_mutation_inner(
            id,
            key,
            None,
            expected_revision,
            &mutation,
            project_resource,
        );
        drop(authority);
        let result = result?;
        Ok(Some((result.workspace.unwrap_or(resolved_target), result.key, result.revision)))
    }

    pub(super) fn close_workspace_with_mutation_inner(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        project_resource: bool,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let fingerprint = serde_json::json!({
            "op": "close-workspace",
            "workspace": target,
            "key": requested_key,
        });
        {
            let registry = self.workspace_registry.lock().unwrap();
            if let Some(commit) = registry.replay(mutation, &fingerprint)? {
                let result = workspace_mutation_result(&commit)?;
                return Ok(result);
            }
        }
        loop {
            let resolved_target = {
                let state = self.state.lock().unwrap();
                Self::require_workspace_revision(&state, expected_revision)?;
                let index = resolve_workspace_index(&state, target, requested_key)?;
                state.workspaces[index].id
            };
            #[cfg(test)]
            if let Some(hook) =
                self.workspace_close_after_selector_resolution.lock().unwrap().clone()
            {
                hook();
            }
            let lifecycle = self.workspace_lifecycle(resolved_target);
            let workspace_lifecycle = lifecycle.lock().unwrap();
            let current_target = {
                let state = self.state.lock().unwrap();
                Self::require_workspace_revision(&state, expected_revision)?;
                let index = resolve_workspace_index(&state, target, requested_key)?;
                state.workspaces[index].id
            };
            if current_target != resolved_target {
                drop(workspace_lifecycle);
                continue;
            }
            let result = self.close_workspace_with_mutation_locked(
                target,
                requested_key,
                expected_generation,
                expected_revision,
                mutation,
                &fingerprint,
                resolved_target,
                project_resource,
            );
            drop(workspace_lifecycle);
            return result;
        }
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn close_workspace_with_mutation_locked(
        &self,
        target: Option<WorkspaceId>,
        requested_key: Option<&str>,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
        resolved_target: WorkspaceId,
        project_resource: bool,
    ) -> anyhow::Result<WorkspaceMutationResult> {
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(commit) = registry.replay(mutation, fingerprint)? {
            let result = workspace_mutation_result(&commit)?;
            return Ok(result);
        }
        let (removed, delta, empty_revision, selection_resync, result) = {
            let mut state = self.lock_state_pinned(&registry).unwrap();
            Self::require_workspace_revision(&state, expected_revision)?;
            let index = resolve_workspace_index(&state, target, requested_key)?;
            let workspace_id = state.workspaces[index].id;
            if workspace_id != resolved_target {
                anyhow::bail!("workspace selector changed while closing");
            }
            let previous_active = state.active_pane();
            let key = state.workspaces[index].key.clone();
            registry.read_state(|db| crate::state::home_store::refuse_close_key(db, &key))?;
            let mut desired = self.registry_projection(&state);
            desired.remove(index);
            let desired_active_workspace = if state.active_workspace == index {
                desired.last().map(|workspace| &workspace.public_id)
            } else {
                state.workspaces.get(state.active_workspace).map(|workspace| &workspace.public_id)
            };
            let committed_result = serde_json::json!({
                "workspace": workspace_id,
                "key": key,
                "index": index,
                "changed": true,
            });
            let commit = if project_resource {
                registry.commit_with_active_workspace(
                    mutation,
                    fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-closed",
                    &key,
                    &desired,
                    desired_active_workspace,
                    &committed_result,
                )?
            } else {
                registry.commit_for_resource_effect(
                    mutation,
                    fingerprint,
                    expected_generation,
                    expected_revision,
                    "workspace-closed",
                    &key,
                    &desired,
                    desired_active_workspace,
                    &committed_result,
                )?
            };
            let resource_revision = project_resource
                .then(|| registry.snapshot().map(|snapshot| snapshot.resource_revision))
                .transpose()?;
            let mut delta = close_workspace_delta(&state, &notifications, workspace_id)
                .expect("live workspace has a close delta");
            let was_active = state.active_workspace == index;
            let active_id =
                state.workspaces.get(state.active_workspace).map(|workspace| workspace.id);
            let workspace = state.remove_workspace(index);
            let mut pane_ids = Vec::new();
            for screen in &workspace.screens {
                screen.root.pane_ids(&mut pane_ids);
            }
            let mut removed = Vec::new();
            for pane_id in pane_ids {
                if let Some(pane) = state.remove_pane(pane_id) {
                    for surface in pane.tabs {
                        if let Some(surface) = state.surfaces.remove(&surface) {
                            removed.push(surface);
                        }
                    }
                }
            }
            state.active_workspace = active_id
                .and_then(|id| state.workspace_index(id))
                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
            stamp_changed_active_pane(self, &mut state, previous_active);
            Self::rebuild_split_screen_index(&mut state);
            state.workspace_revision = commit.revision;
            if let Some(resource_revision) = resource_revision {
                state.resource_revision = resource_revision;
            }
            delta.workspace_revision = Some(commit.revision);
            let empty_revision = state.workspaces.is_empty().then_some(state.workspace_revision);
            let selection_resync = was_active && empty_revision.is_none();
            let result = workspace_mutation_result(&commit)?;
            (removed, delta, empty_revision, selection_resync, result)
        };
        self.emit_committed_workspace_delta(&registry, delta, selection_resync);
        drop(registry);
        if project_resource {
            self.publish_resource_event();
        }
        for surface in removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        self.emit_empty_if_current(empty_revision);
        Ok(result)
    }
}
