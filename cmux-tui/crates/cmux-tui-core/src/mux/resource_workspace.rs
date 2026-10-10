//! Ordinary resource workspace mutations: selector projection helpers,
//! `commit_resource_mutation_plan`, and resource create, rename and move of
//! workspaces.

use super::*;

impl Mux {
    pub(crate) fn registry_projection(&self, state: &State) -> Vec<RegistryWorkspace> {
        state
            .workspaces
            .iter()
            .map(|workspace| RegistryWorkspace {
                id: workspace.id,
                public_id: workspace.public_id.clone(),
                key: workspace.key.clone(),
                name: workspace.name.clone(),
                group_key: self.session.clone(),
            })
            .collect()
    }

    pub(crate) fn ordinary_resource_selectors() -> crate::ResourceSelectors {
        crate::ResourceSelectors {
            machine: Some("current".into()),
            session: Some("current".into()),
            ..crate::ResourceSelectors::default()
        }
    }

    pub(crate) fn ordinary_workspace_selectors(
        &self,
        workspace: WorkspaceId,
    ) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.workspace_ids.get(&workspace).cloned())?;
        Some(crate::ResourceSelectors {
            workspace: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    pub(super) fn ordinary_screen_selectors(
        &self,
        screen: ScreenId,
    ) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.screen_ids.get(&screen).cloned())?;
        Some(crate::ResourceSelectors {
            screen: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    pub(super) fn ordinary_pane_selectors(&self, pane: PaneId) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.pane_ids.get(&pane).cloned())?;
        Some(crate::ResourceSelectors {
            pane: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    pub(super) fn ordinary_tab_selectors(
        &self,
        surface: SurfaceId,
    ) -> Option<crate::ResourceSelectors> {
        let public_id =
            self.with_state(|state| state.resource_indexes.tab_ids.get(&surface).cloned())?;
        Some(crate::ResourceSelectors {
            tab: Some(public_id.to_string()),
            ..Self::ordinary_resource_selectors()
        })
    }

    pub(super) fn nullable_name_fields(name: String) -> Map<String, Value> {
        Map::from_iter([(
            "name".into(),
            if name.is_empty() { Value::Null } else { Value::String(name) },
        )])
    }

    pub(super) fn insert_terminal_env(fields: &mut Map<String, Value>, env: Vec<(String, String)>) {
        if !env.is_empty() {
            fields.insert(
                "env".into(),
                Value::Object(
                    env.into_iter().map(|(key, value)| (key, Value::String(value))).collect(),
                ),
            );
        }
    }

    pub(super) fn insert_spawn_options(
        fields: &mut Map<String, Value>,
        spawn: TerminalSpawnOptions,
    ) {
        Self::insert_optional_string(fields, "cwd", spawn.cwd);
        Self::insert_terminal_env(fields, spawn.env);
        Self::insert_optional_string(fields, RESERVED_TERMINAL_ID_FIELD, spawn.terminal_id);
        Self::insert_optional_string(fields, CLIENT_PANE_ID_FIELD, spawn.pane_id);
        Self::insert_optional_string(fields, CLIENT_TAB_ID_FIELD, spawn.tab_id);
        if let Some(argv) = spawn.argv {
            fields
                .insert("argv".into(), Value::Array(argv.into_iter().map(Value::String).collect()));
        }
    }

    pub(super) fn insert_cell_size(fields: &mut Map<String, Value>, size: Option<(u16, u16)>) {
        if let Some((cols, rows)) = size {
            fields.insert("cols".into(), Value::from(cols));
            fields.insert("rows".into(), Value::from(rows));
        }
    }

    pub(super) fn insert_optional_string(
        fields: &mut Map<String, Value>,
        name: &'static str,
        value: Option<String>,
    ) {
        if let Some(value) = value {
            fields.insert(name.into(), Value::String(value));
        }
    }

    pub(crate) fn ordinary_created_surface(
        &self,
        commit: &ResourcePatchCommit,
    ) -> anyhow::Result<Arc<Surface>> {
        let tab_id = TabPublicId::parse(
            commit.result["tab_id"]
                .as_str()
                .context("created resource result omitted its tab id")?
                .to_string(),
        )?;
        let surface = self
            .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
            .context("created tab disappeared")?;
        self.surface(surface).context("created surface disappeared")
    }

    /// Report an agent state for a selected terminal resource and reconcile
    /// any durable hook projections waiting for that terminal.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn commit_resource_mutation_plan(
        &self,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        prepare: impl FnOnce(&mut State, &WorkspaceRegistry) -> anyhow::Result<ResourceMutationPlan>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut registry = self.workspace_registry.lock().unwrap();
        if let Some(replay) = registry.replay_resource_patch(mutation, operation, fingerprint)? {
            return Ok(replay);
        }

        let mut state = self.lock_state_pinned(&registry).unwrap();
        // Prepare and stage run before the durable commit, so subscribers
        // see a tab's new session path only once that commit succeeds.
        let (prepared, session_paths) = crate::event_bus::defer_session_paths(|| {
            let mut plan = prepare(&mut state, &registry)?;
            let tabs = resource_tab_deltas::TabMembership::capture(&state, &plan.patch);
            let before = plan.stage_checked(&mut state, operation)?;
            anyhow::Ok((plan, before, tabs))
        });
        let (mut plan, before, tabs) = prepared?;
        let committed = persist_public_topology_result(operation, &mut plan.result, &plan.deltas)
            .and_then(|()| {
                #[cfg(test)]
                {
                    *self.resource_mutation_metrics.lock().unwrap() = Some(plan.metrics);
                }
                registry.commit_resource_patch_with_workspace_ledger(
                    mutation,
                    operation,
                    fingerprint,
                    expected_generation,
                    expected_revision,
                    &plan.patch,
                    &plan.result,
                    &plan.deltas,
                    plan.workspace_ledger.as_ref(),
                    plan.state_write.take(),
                )
            });
        let (commit, workspace_revision) = match committed {
            Ok(committed) => committed,
            Err(error) => {
                if let Some(before) = before {
                    *state = before;
                }
                return Err(error);
            }
        };
        if commit.replayed {
            if let Some(before) = before {
                *state = before;
            }
        } else {
            self.subscribers.publish_deferred_session_paths(session_paths);
        }
        plan.apply(&mut state, &commit, workspace_revision);
        let tab_deltas = tabs.and_then(|tabs| tabs.deltas(self, &state, &commit));
        drop(state);
        drop(registry);
        if !commit.replayed {
            self.publish_resource_event();
            // A commit can create the resource row that a shell's first
            // directory report was waiting for.
            self.publish_pending_terminal_directories();
        }
        self.emit_resource_tab_deltas(tab_deltas);
        Ok(commit)
    }

    pub(crate) fn resource_rename_workspace_selected(
        &self,
        selectors: crate::ResourceSelectors,
        name: String,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        Self::validate_workspace_name(&name)?;
        let fingerprint = serde_json::json!({
            "operation": "workspace.rename",
            "selectors": selectors,
            "name": name,
        });
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.rename",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        crate::ResourceTarget::Workspace,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target = resolved
                    .path
                    .workspace
                    .expect("workspace target resolution returns a workspace");
                let slot =
                    resolved.workspace.expect("workspace target resolution returns a live slot");
                let index = state
                    .workspace_index(slot)
                    .with_context(|| format!("workspace {target} has no live slot"))?;
                #[cfg(test)]
                if let Some(hook) =
                    self.resource_rename_after_selector_resolution.lock().unwrap().clone()
                {
                    hook(&target);
                }
                let workspace = &state.workspaces[index];
                let changed = workspace.name != name;
                let active_screen = workspace
                    .screens
                    .get(workspace.active_screen)
                    .map(|screen| screen.public_id.clone());
                let durable = RegistryWorkspace {
                    id: workspace.id,
                    public_id: workspace.public_id.clone(),
                    key: workspace.key.clone(),
                    name: name.clone(),
                    group_key: self.session.clone(),
                };
                let result = serde_json::json!({
                    "workspace": target.as_str(),
                    "name": name,
                    "changed": changed,
                });
                let deltas = Value::Array(vec![workspace_resource_upsert(
                    0,
                    registry.session_id().as_str(),
                    &target,
                    &name,
                    index,
                    index == state.active_workspace,
                )]);
                let mut desired = self.registry_projection(state);
                desired[index] = durable.clone();
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
                        state.workspaces[index].name = name;
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
            },
        )
    }

    pub(crate) fn resource_move_workspace_selected(
        &self,
        selectors: crate::ResourceSelectors,
        index: usize,
        expected_generation: Option<&str>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = serde_json::json!({
            "operation": "workspace.move",
            "selectors": selectors,
            "index": index,
        });
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.move",
            &fingerprint,
            expected_generation,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        crate::ResourceTarget::Workspace,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target = resolved
                    .path
                    .workspace
                    .expect("workspace target resolution returns a workspace");
                let slot =
                    resolved.workspace.expect("workspace target resolution returns a live slot");
                let old_index = state
                    .workspace_index(slot)
                    .with_context(|| format!("workspace {target} has no live slot"))?;
                let new_index = index.min(state.workspaces.len().saturating_sub(1));
                let changed = new_index != old_index;
                let active_slot =
                    state.workspaces.get(state.active_workspace).map(|workspace| workspace.id);
                let mut order = state
                    .workspaces
                    .iter()
                    .map(|workspace| workspace.public_id.clone())
                    .collect::<Vec<_>>();
                if changed {
                    let moved = order.remove(old_index);
                    order.insert(new_index, moved);
                }
                let changes = if changed {
                    vec![ResourceChange::SetWorkspaceOrder { workspace_ids: order.clone() }]
                } else {
                    let workspace = &state.workspaces[old_index];
                    vec![ResourceChange::UpsertWorkspace {
                        workspace: RegistryWorkspace {
                            id: workspace.id,
                            public_id: workspace.public_id.clone(),
                            key: workspace.key.clone(),
                            name: workspace.name.clone(),
                            group_key: self.session.clone(),
                        },
                        position: old_index,
                        active_screen: workspace
                            .screens
                            .get(workspace.active_screen)
                            .map(|screen| screen.public_id.clone()),
                    }]
                };
                let result = serde_json::json!({
                    "workspace": target.as_str(),
                    "index": new_index,
                    "changed": changed,
                });
                let deltas = Value::Array(
                    order
                        .iter()
                        .enumerate()
                        .map(|(position, workspace_id)| {
                            let workspace = state
                                .workspaces
                                .iter()
                                .find(|workspace| &workspace.public_id == workspace_id)
                                .expect("workspace order was built from live workspaces");
                            workspace_resource_upsert(
                                position,
                                registry.session_id().as_str(),
                                workspace_id,
                                &workspace.name,
                                position,
                                active_slot == Some(workspace.id),
                            )
                        })
                        .collect(),
                );
                let order_entries = usize::from(changed) * order.len();
                let projection = self.registry_projection(state);
                let desired = order
                    .iter()
                    .map(|workspace_id| {
                        projection
                            .iter()
                            .find(|workspace| &workspace.public_id == workspace_id)
                            .expect("workspace order was built from live workspaces")
                            .clone()
                    })
                    .collect::<Vec<_>>();
                let workspace_key = state.workspaces[old_index].key.clone();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result.clone(),
                    deltas,
                    move |state| {
                        if changed {
                            state.move_workspace(old_index, new_index);
                            for (workspace_index, _, _) in state.split_screens.values_mut() {
                                *workspace_index = if *workspace_index == old_index {
                                    new_index
                                } else if old_index < new_index
                                    && (old_index + 1..=new_index).contains(workspace_index)
                                {
                                    workspace_index.saturating_sub(1)
                                } else if new_index < old_index
                                    && (new_index..old_index).contains(workspace_index)
                                {
                                    workspace_index.saturating_add(1)
                                } else {
                                    *workspace_index
                                };
                            }
                            state.active_workspace = active_slot
                                .and_then(|slot| state.workspace_index(slot))
                                .unwrap_or_else(|| state.workspaces.len().saturating_sub(1));
                        }
                    },
                )
                .with_workspace_ledger(ResourceWorkspaceLedger {
                    event_kind: "workspace-moved",
                    workspace_key,
                    workspaces: desired,
                    legacy_result: result,
                    presentation: None,
                })
                .with_metrics(ResourceMutationMetrics {
                    touched_resources: 1,
                    order_entries,
                    terminal_queries: 0,
                    changed_rows: if changed { order.len() } else { 1 },
                }))
            },
        )
    }
}
