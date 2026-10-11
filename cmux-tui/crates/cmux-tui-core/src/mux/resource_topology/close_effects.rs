//! Resource close effects: surface and terminal close effects, legacy terminal closes, terminal exit detach projection, and the close plan and commit.

use super::*;

impl Mux {
    #[allow(clippy::too_many_arguments)]
    pub(super) fn commit_resource_close_effect(
        &self,
        operation: ResourceOperation,
        intent: &Value,
        idempotency_key: &str,
        operation_name: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<CommittedResourceClose> {
        debug_assert!(is_resource_close_operation(operation));
        let path: ResolvedResourcePath = serde_json::from_value(intent["path"].clone())
            .context("stored topology close intent has an invalid path")?;
        let workspace = self
            .effect_slots(&path)?
            .workspace
            .context("topology close target has no workspace")?;
        self.commit_resource_close_with(
            operation,
            Some(workspace),
            idempotency_key,
            operation_name,
            fingerprint,
            move |state| self.effect_slots_in_state(state, &path),
        )
    }

    pub(crate) fn commit_resource_surface_close_effect(
        &self,
        surface: SurfaceId,
        idempotency_key: &str,
        operation_name: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let workspace =
            self.surface_workspace(surface).context("content close target has no workspace")?;
        let committed = self.commit_resource_close_with(
            ResourceOperation::TabClose,
            Some(workspace),
            idempotency_key,
            operation_name,
            fingerprint,
            move |state| {
                anyhow::ensure!(state.surfaces.contains_key(&surface), "content disappeared");
                let pane = state.pane_of(surface).context("content has no pane")?;
                let (workspace_index, screen_index) =
                    state.screen_of(pane).context("content pane has no screen")?;
                Ok(EffectSlots {
                    workspace: Some(state.workspaces[workspace_index].id),
                    screen: Some(state.workspaces[workspace_index].screens[screen_index].id),
                    pane: Some(pane),
                    tab: Some(surface),
                    terminal: None,
                })
            },
        )?;
        drop(_creation_fence);
        drop(_creation_handoff);
        Ok(self.finish_resource_close(committed))
    }

    pub(crate) fn commit_resource_terminal_close_effect(
        &self,
        terminal_id: &TerminalPublicId,
        idempotency_key: &str,
        operation_name: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let terminal_id = terminal_id.clone();
        let committed = self.commit_resource_close_with(
            ResourceOperation::TerminalClose,
            None,
            idempotency_key,
            operation_name,
            fingerprint,
            move |_| {
                Ok(EffectSlots {
                    workspace: None,
                    screen: None,
                    pane: None,
                    tab: None,
                    terminal: Some(terminal_id),
                })
            },
        )?;
        drop(_creation_fence);
        drop(_creation_handoff);
        Ok(self.finish_resource_close(committed))
    }

    /// Route the legacy host close through the same projected topology owner
    /// as `terminal.close`. `None` means the host has no live public resource,
    /// so the caller may use the host-only compatibility path.
    #[allow(clippy::too_many_arguments)]
    pub(in crate::mux) fn commit_legacy_terminal_close(
        &self,
        terminal_id: &str,
        expected_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_terminal_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        guard: TerminalCloseGuard,
    ) -> anyhow::Result<Option<TerminalCloseResult>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(terminal) =
            registry.replay_terminal_close(mutation, terminal_id, expected_incarnation)?
        {
            let result = TerminalCloseResult {
                surface: None,
                terminal_id: terminal_id.to_string(),
                terminal_incarnation: terminal.result["incarnation"].as_str().map(str::to_string),
                already_closed: terminal.result["already_closed"].as_bool().unwrap_or(false),
                terminal_revision: terminal.revision,
            };
            drop(registry);
            drop(_creation_fence);
            drop(_creation_handoff);
            return Ok(Some(result));
        }
        let Some(public_id) = registry.terminal_resource_id(terminal_id)? else {
            return Ok(None);
        };
        let mut state = self.lock_state_pinned(&registry).unwrap();
        if guard == TerminalCloseGuard::UnplacedAndNotKept {
            // The registry lock serializes placement commits and the creation
            // fence excludes a creation between runtime and placement, so
            // this check cannot race a new view of the terminal.
            let placed = !state
                .placements_of_content(&ContentPublicId::Terminal(public_id.clone()))
                .is_empty()
                || state.terminal_catalog.get(&public_id).is_some_and(|runtime| {
                    state.surfaces.values().any(|view| view.shares_terminal_runtime(runtime))
                });
            if placed || registry.terminal_keep(terminal_id)? {
                return Err(TerminalCloseGuardFailed.into());
            }
        }
        let durable_host = registry.terminal_host_id(&public_id)?.ok_or_else(|| {
            terminal_close_state_error(format!("terminal {public_id} has no durable host"))
        })?;
        if durable_host != terminal_id {
            return Err(terminal_close_state_error("terminal resource changed hosts"));
        }
        let content_id = ContentPublicId::Terminal(public_id.clone());
        let runtime = state.terminal_catalog.get(&public_id).cloned();
        let has_views = !state.placements_of_content(&content_id).is_empty();
        let (target, mut plan) = if runtime.is_some() || has_views {
            if let Some(runtime) = runtime {
                let host = self.resource_terminal_host_identity(&runtime).ok_or_else(|| {
                    terminal_close_state_error("terminal runtime omitted its durable host identity")
                })?;
                if host.terminal_id != terminal_id {
                    return Err(terminal_close_state_error("terminal resource changed hosts"));
                }
                if let Some(expected) = expected_incarnation {
                    anyhow::ensure!(host.incarnation == expected, "terminal_incarnation_mismatch");
                }
            } else {
                // An exited terminal keeps dead views after its runtime is
                // gone (a host loss, invariant 3, or a keep-layout tab);
                // explicit close retires them with the receipt.
                let record = registry.terminal_record(terminal_id)?.ok_or_else(|| {
                    terminal_close_state_error(format!("terminal close omitted host {terminal_id}"))
                })?;
                // A pending terminal (R41) also has views and no runtime.
                if record.lifecycle != TerminalLifecycle::Exited
                    && !self.pending_terminal_closable(terminal_id)
                {
                    return Err(terminal_close_state_error(format!(
                        "live terminal resource {public_id} has views but no runtime owner"
                    )));
                }
                if let Some(expected) = expected_incarnation {
                    anyhow::ensure!(
                        record.incarnation.as_deref() == Some(expected),
                        "terminal_incarnation_mismatch"
                    );
                }
            }
            let target = state.placements_of_content(&content_id).first().copied();
            let plan = self.resource_close_plan_locked(
                ResourceOperation::TerminalClose,
                EffectSlots {
                    workspace: None,
                    screen: None,
                    pane: None,
                    tab: None,
                    terminal: Some(public_id.clone()),
                },
                &registry,
                &state,
                &notifications,
                mutation.origin != terminal_reap::END_TERMINALS_MUTATION_ORIGIN,
            )?;
            (target, plan)
        } else {
            (
                None,
                ResourceClosePlan {
                    state: state.clone(),
                    removed: Vec::new(),
                    terminal_runtime: None,
                    closed_terminal_public_id: Some(public_id.clone()),
                    terminal_batch: Vec::new(),
                    workspace_close: None,
                    delta: None,
                    changed_screens: Vec::new(),
                    selection_resync: false,
                },
            )
        };
        let mut projection =
            self.resource_effect_projection_locked(&registry, &mut plan.state, json!({}))?;
        if !projection.patch.changes.iter().any(|change| {
            matches!(
                change,
                ResourceChange::TombstoneTerminal { public_id: closing, .. }
                    if closing == &public_id
            )
        }) {
            let incarnation = registry
                .terminal_record(terminal_id)?
                .ok_or_else(|| {
                    terminal_close_state_error(format!(
                        "terminal close projection omitted host {terminal_id}"
                    ))
                })?
                .incarnation;
            projection.patch.changes.push(ResourceChange::TombstoneTerminal {
                public_id: public_id.clone(),
                expected_incarnation: incarnation,
            });
            let changes = projection.changes.as_array_mut().ok_or_else(|| {
                terminal_close_state_error("terminal close projection changes are not an array")
            })?;
            changes.push(json!({
                "kind":"delete",
                "sequence":changes.len(),
                "resource":"terminal",
                "id":public_id,
            }));
        }
        #[cfg(test)]
        if let Some(hook) = self.resource_projection_before_commit.lock().unwrap().clone() {
            hook();
        }
        let committed = registry.close_terminal_with_resource_patch(
            mutation,
            expected_generation,
            expected_terminal_revision,
            state.resource_revision,
            terminal_id,
            expected_incarnation,
            &projection.patch,
            &projection.result,
            &projection.changes,
            plan.workspace_close.as_ref(),
        )?;
        let (terminal, resource, workspace_revision) = match committed {
            TerminalResourceCloseCommit::TerminalReplay(terminal) => {
                let result = TerminalCloseResult {
                    surface: None,
                    terminal_id: terminal_id.to_string(),
                    terminal_incarnation: terminal.result["incarnation"]
                        .as_str()
                        .map(str::to_string),
                    already_closed: terminal.result["already_closed"].as_bool().unwrap_or(false),
                    terminal_revision: terminal.revision,
                };
                drop(state);
                drop(registry);
                drop(_creation_fence);
                drop(_creation_handoff);
                return Ok(Some(result));
            }
            TerminalResourceCloseCommit::ResourceReplay { terminal, resource } => {
                state.resource_revision = state.resource_revision.max(resource.revision);
                let result = TerminalCloseResult {
                    surface: None,
                    terminal_id: terminal_id.to_string(),
                    terminal_incarnation: terminal.result["incarnation"]
                        .as_str()
                        .map(str::to_string),
                    already_closed: terminal.result["already_closed"].as_bool().unwrap_or(false),
                    terminal_revision: terminal.revision,
                };
                drop(state);
                drop(registry);
                drop(_creation_fence);
                drop(_creation_handoff);
                return Ok(Some(result));
            }
            TerminalResourceCloseCommit::Committed { terminal, resource, workspace_revision } => {
                (terminal, resource, workspace_revision)
            }
        };
        #[cfg(test)]
        if let Some(hook) = self.resource_close_after_commit.lock().unwrap().clone() {
            hook();
        }
        if !terminal.replayed && !terminal.result["already_closed"].as_bool().unwrap_or(false) {
            self.emit_terminal_registry_changed(&registry, terminal.revision);
        }
        let mut effects = plan.install(&mut state, resource.revision, workspace_revision);
        let pending = effects.terminal_runtime.is_none() && self.terminal_is_pending(terminal_id);
        drop(state);
        self.publish_revisioned_workspace_delta(&registry, &mut effects);
        drop(registry);
        drop(_creation_fence);
        drop(_creation_handoff);
        self.finish_resource_close(CommittedResourceClose { commit: resource, effects });
        self.after_terminal_close(&public_id, terminal_id, &terminal.result, pending);
        Ok(Some(TerminalCloseResult {
            surface: target,
            terminal_id: terminal_id.to_string(),
            terminal_incarnation: terminal.result["incarnation"].as_str().map(str::to_string),
            already_closed: terminal.result["already_closed"].as_bool().unwrap_or(false),
            terminal_revision: terminal.revision,
        }))
    }

    /// Views of an exited terminal to remove in the exit's commit. Requires
    /// a [`DetachProof`]: only a process end may detach (invariant 3).
    pub(in crate::mux) fn terminal_exit_detach_projection_locked(
        &self,
        _proof: DetachProof,
        registry: &WorkspaceRegistry,
        state: &State,
        terminal_id: &str,
        terminal_public_id: &TerminalPublicId,
    ) -> anyhow::Result<Option<TerminalExitDetachProjection>> {
        let content_id = ContentPublicId::Terminal(terminal_public_id.clone());
        let mut targets = state.placements_of_content(&content_id).to_vec();
        targets.sort_unstable();
        targets.dedup();
        let has_runtime = state.terminal_catalog.contains_key(terminal_public_id);
        if targets.is_empty() && !has_runtime {
            return Ok(None);
        }
        let durable_host = registry
            .terminal_host_id(terminal_public_id)?
            .with_context(|| format!("terminal {terminal_public_id} has no durable host"))?;
        anyhow::ensure!(
            durable_host == terminal_id,
            "terminal exit identity changed before detach"
        );
        let tab_ids =
            targets
                .iter()
                .map(|target| {
                    state.resource_indexes.tab_ids.get(target).cloned().with_context(|| {
                        format!("terminal view {target} has no durable tab identity")
                    })
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
        let changed_screens = unique_screen_ids(
            targets.iter().filter_map(|target| surface_screen_id(state, *target)),
        );
        let selection_before = active_tree_selection(state);
        let mut projected = state.clone();
        let (runtime, removed, _) =
            remove_terminal_content_from_state(self, &mut projected, terminal_public_id);
        if let Some(runtime) = runtime.as_ref() {
            let host = self
                .resource_terminal_host_identity(runtime)
                .context("terminal runtime omitted its durable host identity")?;
            anyhow::ensure!(host.terminal_id == terminal_id, "terminal exit runtime changed hosts");
        }
        anyhow::ensure!(
            projected.placements_of_content(&content_id).is_empty(),
            "terminal exit retained a projected view"
        );
        anyhow::ensure!(
            !projected.terminal_catalog.contains_key(terminal_public_id),
            "terminal exit retained its catalog runtime"
        );
        // A process end detaches the last view: the tab closes, and so does
        // the workspace it emptied (LAST-TAB-CLOSES-WORKSPACE).
        let workspace_close =
            self.close_emptied_workspaces_locked(registry, state, &mut projected, None)?;
        let selection_resync = match &workspace_close {
            Some(emptied) => emptied.was_active && !projected.workspaces.is_empty(),
            None => selection_before != active_tree_selection(&projected),
        };
        let mut projection =
            self.resource_effect_projection_locked(registry, &mut projected, json!({}))?;

        let mut preserved_terminal = false;
        projection.patch.changes.retain(|change| match change {
            ResourceChange::TombstoneTerminal { public_id, .. }
                if public_id == terminal_public_id =>
            {
                preserved_terminal = true;
                false
            }
            _ => true,
        });
        if !tab_ids.is_empty() {
            anyhow::ensure!(
                preserved_terminal,
                "terminal exit projection did not preserve its durable receipt"
            );
        }
        let detached_tabs = projection
            .patch
            .changes
            .iter()
            .filter_map(|change| match change {
                ResourceChange::TombstoneTab { tab_id, .. } => Some(tab_id),
                _ => None,
            })
            .collect::<HashSet<_>>();
        anyhow::ensure!(
            tab_ids.iter().all(|tab_id| detached_tabs.contains(tab_id)),
            "terminal exit projection omitted a durable view"
        );

        let public_changes = projection
            .changes
            .as_array_mut()
            .context("terminal exit topology changes are not an array")?;
        public_changes.retain(|change| {
            !(change["kind"] == "delete"
                && change["resource"] == "terminal"
                && change["id"].as_str() == Some(terminal_public_id.as_str()))
        });
        for (sequence, change) in public_changes.iter_mut().enumerate() {
            change["sequence"] = json!(sequence);
        }

        Ok(Some(TerminalExitDetachProjection {
            state: projected,
            runtime,
            removed,
            targets,
            tab_ids,
            patch: projection.patch,
            changes: projection.changes,
            changed_screens,
            selection_resync,
            workspace_close: workspace_close.map(|emptied| emptied.close),
        }))
    }

    pub(in crate::mux) fn finish_terminal_exit_detach(&self, effects: TerminalExitDetachEffects) {
        for target in &effects.targets {
            self.purge_surface_side_tables(*target);
        }
        if let Some(runtime) = effects.runtime.as_ref() {
            self.purge_terminal_runtime_side_tables(runtime);
            runtime.kill();
        }
        drop(effects.removed);
        for target in effects.targets {
            self.emit(MuxEvent::SurfaceExited(target));
        }
        self.emit(MuxEvent::TreeChanged);
        if effects.selection_resync {
            self.emit(MuxEvent::TreeSelectionChanged);
        }
        for screen in effects.changed_screens {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        self.emit_empty_if_current(effects.empty_revision);
    }

    #[allow(clippy::too_many_arguments)]
    pub(super) fn commit_resource_close_with(
        &self,
        operation: ResourceOperation,
        workspace: Option<WorkspaceId>,
        idempotency_key: &str,
        operation_name: &str,
        fingerprint: &Value,
        resolve_slots: impl FnOnce(&State) -> anyhow::Result<EffectSlots>,
    ) -> anyhow::Result<CommittedResourceClose> {
        let lifecycle = workspace.map(|workspace| self.workspace_lifecycle(workspace));
        let workspace_lifecycle = lifecycle.as_ref().map(|lifecycle| lifecycle.lock().unwrap());
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.lock_state_pinned(&registry).unwrap();
        let slots = resolve_slots(&state)?;
        if let Some(workspace) = workspace {
            anyhow::ensure!(
                slots.workspace == Some(workspace),
                "topology close target changed workspaces before commit"
            );
        }
        let mut plan = self.resource_close_plan_locked(
            operation,
            slots,
            &registry,
            &state,
            &notifications,
            true,
        )?;
        let mut projection =
            self.resource_effect_projection_locked(&registry, &mut plan.state, json!({}))?;
        // Full projection derives terminal tombstones from detached tabs, but
        // an exited terminal receipt has zero tabs. Explicit close must still
        // retire that receipt.
        if let Some(terminal_id) = plan.closed_terminal_public_id.as_ref() {
            let expected_incarnation =
                plan.terminal_batch.first().and_then(|(_, incarnation)| incarnation.as_deref());
            projection.ensure_terminal_close(terminal_id, expected_incarnation)?;
        }
        #[cfg(test)]
        if let Some(hook) = self.resource_projection_before_commit.lock().unwrap().clone() {
            hook();
        }
        let close = registry.commit_resource_close_patch(
            idempotency_key,
            operation_name,
            fingerprint,
            &projection.patch,
            &projection.result,
            &projection.changes,
            &plan.terminal_batch,
            plan.workspace_close.as_ref(),
        )?;
        #[cfg(test)]
        if let Some(hook) = self.resource_close_after_commit.lock().unwrap().clone() {
            hook();
        }
        let mut effects =
            plan.install(&mut state, close.resource.revision, close.workspace_revision);
        drop(state);
        if close.terminal_batch.closed != 0 {
            self.emit_terminal_registry_changed(&registry, close.terminal_batch.revision);
        }
        self.publish_revisioned_workspace_delta(&registry, &mut effects);
        drop(registry);
        drop(workspace_lifecycle);
        Ok(CommittedResourceClose { commit: close.resource, effects })
    }

    pub(super) fn finish_resource_close(
        &self,
        committed: CommittedResourceClose,
    ) -> ResourcePatchCommit {
        let effects = committed.effects;
        if let Some(terminal_id) = effects.closed_terminal_public_id {
            self.notify_terminal_exit_waiters(Some(terminal_id));
        }

        #[cfg(test)]
        if let Some(hook) = self.resource_close_cleanup.lock().unwrap().clone() {
            hook();
        }
        self.publish_resource_event();
        for surface in effects.removed {
            self.purge_surface_side_tables(surface.id);
            if surface.kind() == SurfaceKind::Browser {
                surface.kill();
            }
        }
        if let Some(runtime) = effects.terminal_runtime {
            self.purge_terminal_runtime_side_tables(&runtime);
            self.terminate_terminal_runtime(&runtime);
        }
        match effects.tree_publication {
            ResourceCloseTreePublication::PendingDelta(delta) => {
                self.emit_tree_delta(delta, effects.selection_resync);
            }
            ResourceCloseTreePublication::PendingSnapshot => {
                self.emit(MuxEvent::TreeChanged);
                if effects.selection_resync {
                    self.emit(MuxEvent::TreeSelectionChanged);
                }
            }
            ResourceCloseTreePublication::Published => {}
        }
        for screen in effects.changed_screens {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
        self.emit_empty_if_current(effects.empty_revision);
        committed.commit
    }

    pub(super) fn resource_close_plan_locked(
        &self,
        operation: ResourceOperation,
        slots: EffectSlots,
        registry: &WorkspaceRegistry,
        state: &State,
        notifications: &TreeDecorations,
        close_emptied_workspaces: bool,
    ) -> anyhow::Result<ResourceClosePlan> {
        let selection_before = active_tree_selection(state);
        let mut projected = state.clone();
        let ResourceCloseInputs {
            surface_ids,
            mut delta,
            mut changed_screens,
            workspace_metadata,
            terminal_runtime,
            terminal_batch,
            terminal_public_id,
        } = match operation {
            ResourceOperation::WorkspaceClose => {
                let workspace = slots.workspace.context("workspace disappeared")?;
                let index = state.workspace_index(workspace).context("workspace disappeared")?;
                let item = &state.workspaces[index];
                let surfaces = item
                    .screens
                    .iter()
                    .flat_map(|screen| screen_tabs(state, screen))
                    .collect::<Vec<_>>();
                let screens = item.screens.iter().map(|screen| screen.id).collect::<Vec<_>>();
                let delta = close_workspace_delta(state, notifications, workspace)
                    .context("workspace close target has no tree delta")?;
                ResourceCloseInputs {
                    surface_ids: surfaces,
                    delta: Some(delta),
                    changed_screens: screens,
                    workspace_metadata: Some((workspace, index, item.key.clone())),
                    ..Default::default()
                }
            }
            ResourceOperation::ScreenClose => {
                let screen = slots.screen.context("screen disappeared")?;
                let (workspace_index, screen_index) = state
                    .workspaces
                    .iter()
                    .enumerate()
                    .find_map(|(workspace_index, workspace)| {
                        workspace
                            .screens
                            .iter()
                            .position(|candidate| candidate.id == screen)
                            .map(|screen_index| (workspace_index, screen_index))
                    })
                    .context("screen disappeared")?;
                let surfaces =
                    screen_tabs(state, &state.workspaces[workspace_index].screens[screen_index]);
                let delta = close_screen_delta(state, notifications, screen)
                    .context("screen close target has no tree delta")?;
                ResourceCloseInputs {
                    surface_ids: surfaces,
                    delta: Some(delta),
                    changed_screens: vec![screen],
                    ..Default::default()
                }
            }
            ResourceOperation::PaneClose => {
                let pane = slots.pane.context("pane disappeared")?;
                let surfaces = state.panes.get(&pane).context("pane disappeared")?.tabs.clone();
                let screen =
                    surface_screen_id(state, *surfaces.first().context("pane has no tabs")?)
                        .context("pane has no screen")?;
                let delta = close_pane_delta(state, notifications, pane)
                    .context("pane close target has no tree delta")?;
                ResourceCloseInputs {
                    surface_ids: surfaces,
                    delta: Some(delta),
                    changed_screens: vec![screen],
                    ..Default::default()
                }
            }
            ResourceOperation::TabClose => {
                let surface = slots.tab.context("tab disappeared")?;
                let screen = surface_screen_id(state, surface).context("tab has no screen")?;
                let delta = close_surface_delta(state, notifications, surface)
                    .context("tab close target has no tree delta")?;
                ResourceCloseInputs {
                    surface_ids: vec![surface],
                    delta: Some(delta),
                    changed_screens: vec![screen],
                    ..Default::default()
                }
            }
            ResourceOperation::TerminalClose => {
                let public_id = slots.terminal.context("terminal disappeared")?;
                let host_id = registry
                    .terminal_host_id(&public_id)?
                    .with_context(|| format!("terminal {public_id} has no durable host"))?;
                let terminal = registry
                    .terminal_record(&host_id)?
                    .with_context(|| format!("terminal {public_id} has no durable receipt"))?;
                // An exited terminal is a durable receipt with no runtime and
                // no views; explicit close is the one operation that retires
                // it. A live terminal still requires its catalog runtime.
                let runtime = state.terminal_catalog.get(&public_id).cloned();
                if let Some(runtime) = runtime.as_ref() {
                    let host = self
                        .resource_terminal_host_identity(runtime)
                        .context("terminal omitted its durable host identity")?;
                    anyhow::ensure!(host.terminal_id == host_id, "terminal changed durable hosts");
                }
                let placements = state
                    .placements_of_content(&ContentPublicId::Terminal(public_id.clone()))
                    .to_vec();
                // An exited terminal may keep dead views without a runtime
                // (a host loss, or a keep-layout tab); a live one may not.
                if runtime.is_none() {
                    anyhow::ensure!(
                        placements.is_empty()
                            || terminal.lifecycle == TerminalLifecycle::Exited
                            || self.pending_terminal_closable(&host_id),
                        "live terminal resource {public_id} has views but no runtime owner"
                    );
                }
                let screens = unique_screen_ids(
                    placements.iter().filter_map(|surface| surface_screen_id(state, *surface)),
                );
                ResourceCloseInputs {
                    surface_ids: placements,
                    changed_screens: screens,
                    terminal_runtime: runtime,
                    terminal_batch: vec![(host_id, terminal.incarnation)],
                    terminal_public_id: Some(public_id),
                    ..Default::default()
                }
            }
            _ => anyhow::bail!("operation is not a topology close"),
        };

        let mut removed = Vec::new();
        let mut split_index_changed = false;
        if let Some(public_id) = &terminal_public_id {
            let (removed_runtime, terminal_views, changed) =
                remove_terminal_content_from_state(self, &mut projected, public_id);
            match (removed_runtime.as_ref(), terminal_runtime.as_ref()) {
                (Some(removed), Some(planned)) => anyhow::ensure!(
                    removed.shares_terminal_runtime(planned),
                    "terminal close changed its catalog runtime"
                ),
                (None, None) => {}
                _ => anyhow::bail!("terminal close lost its catalog runtime"),
            }
            removed = terminal_views;
            split_index_changed = changed;
            for surface in surface_ids {
                anyhow::ensure!(
                    projected.pane_of(surface).is_none(),
                    "close target surface {surface} remained attached"
                );
            }
        } else {
            for surface_id in &surface_ids {
                if let Some(surface) = state.surfaces.get(surface_id).cloned() {
                    removed.push(surface);
                }
            }
            for surface in surface_ids {
                let (_, changed) = remove_surface(self, &mut projected, surface);
                anyhow::ensure!(
                    projected.pane_of(surface).is_none(),
                    "close target surface {surface} remained attached"
                );
                split_index_changed |= changed;
            }
        }

        let mut workspace_close = None;
        let mut workspace_was_active = false;
        if let Some((workspace, index, workspace_key)) = workspace_metadata {
            workspace_was_active = self.remove_workspace_for_close(
                registry,
                &mut projected,
                workspace,
                &workspace_key,
            )?;
            workspace_close =
                Some(self.workspace_close_record(&projected, workspace, &workspace_key, index));
            split_index_changed = true;
        } else if let Some(emptied) = self.close_emptied_workspaces_for_resource_close_locked(
            registry,
            state,
            &mut projected,
            notifications,
            close_emptied_workspaces,
        )? {
            (delta, changed_screens, workspace_was_active) =
                (emptied.delta, emptied.changed_screens, emptied.was_active);
            workspace_close = Some(emptied.close);
        }
        if split_index_changed {
            Self::rebuild_split_screen_index(&mut projected);
        }
        let selection_resync = if workspace_close.is_some() {
            workspace_was_active && !projected.workspaces.is_empty()
        } else {
            selection_before != active_tree_selection(&projected)
        };
        // The workspace revision is filled from the atomic registry commit.
        if let Some(delta) = &mut delta {
            delta.workspace_revision = None;
        }
        Ok(ResourceClosePlan {
            state: dock_columns::close_keeping_permanent(operation, state, projected)?,
            removed,
            terminal_runtime,
            closed_terminal_public_id: terminal_public_id,
            terminal_batch,
            workspace_close,
            delta,
            changed_screens,
            selection_resync,
        })
    }
}
