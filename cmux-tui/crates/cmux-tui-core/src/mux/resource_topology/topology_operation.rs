//! Resource topology operation entry: creation resolution, interrupted creation reconcile, empty workspace creation, pane neighbors, the operation dispatcher, receipted creation, the commit path, and legacy event emission.

use super::*;

impl Mux {
    pub(crate) fn resource_creation_resolution(
        self: &Arc<Self>,
        correlation_key: &str,
    ) -> anyhow::Result<Value> {
        self.reconcile_interrupted_resource_creation(correlation_key)?;
        self.workspace_registry.lock().unwrap().resolve_resource_creation(correlation_key)
    }

    pub(in crate::mux) fn reconcile_interrupted_resource_creations(&self) -> anyhow::Result<bool> {
        let recoveries =
            self.workspace_registry.lock().unwrap().interrupted_resource_creation_recoveries()?;
        let mut pending = false;
        for recovery in recoveries {
            pending |= matches!(
                self.settle_resource_creation(recovery, None)?,
                ResourceCreationSettlement::Pending
            );
        }
        Ok(pending)
    }

    pub(super) fn reconcile_interrupted_resource_creation(
        &self,
        correlation_key: &str,
    ) -> anyhow::Result<()> {
        let recovery =
            self.workspace_registry.lock().unwrap().resource_creation_recovery(correlation_key)?;
        if let Some(recovery) = recovery.filter(|recovery| recovery.interrupted) {
            let _ = self.settle_resource_creation(recovery, None)?;
        }
        Ok(())
    }

    pub(crate) fn resource_create_empty_workspace_selected(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        correlation_key: &str,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        mark: crate::state::home_store::EmptyWorkspaceMark,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mut fingerprint = json!({
            "operation":"workspace.create",
            "selectors":&selectors,
            "fields":{
                "initial_content":"empty",
                "name":&name,
            },
        });
        if let Some((field, value)) = mark.fingerprint_field() {
            fingerprint["fields"][field] = value;
        }
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name)?;
        }
        // Read before the state lock: `surface_notifications` locks state.
        let notifications = self.tree_decorations();
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        self.resolve_resource_path_in_state(&state, &registry, ResourceTarget::Session, &selectors)
            .map_err(anyhow::Error::new)?;
        let reserved_name = name.unwrap_or_else(|| Self::default_workspace_name(&state));
        let proposed_intent = json!({
            "workspace_public_id":WorkspacePublicId::random()?,
            "workspace_key":Self::new_workspace_key()?,
            "name":reserved_name,
        });
        let preparation = registry.prepare_resource_creation_for(
            correlation_key,
            mutation,
            "workspace.create",
            &fingerprint,
            &proposed_intent,
            false,
            None,
            expected_revision,
        )?;
        let intent = match preparation {
            ResourceCreationPreparation::Created { created_path, revision, .. } => {
                let workspace = created_path["workspace_id"]
                    .as_str()
                    .context("stored workspace creation omitted its workspace id")?;
                return Ok(ResourcePatchCommit {
                    revision,
                    result: json!({"workspace":workspace}),
                    replayed: true,
                });
            }
            ResourceCreationPreparation::Blocked { idempotency_key, operation } => {
                return Err(anyhow::Error::new(resource_effect_indeterminate(
                    &idempotency_key,
                    &operation,
                )));
            }
            ResourceCreationPreparation::Failed { error, .. } => {
                return Err(anyhow::Error::new(error));
            }
            ResourceCreationPreparation::Execute { intent, .. } => intent,
        };
        anyhow::ensure!(
            state.workspaces.len() < WORKSPACE_REGISTRY_LIMIT,
            "workspace limit reached ({WORKSPACE_REGISTRY_LIMIT})"
        );
        let workspace_slot = self.next_id();
        let public_id = WorkspacePublicId::parse(
            intent["workspace_public_id"]
                .as_str()
                .context("stored workspace creation omitted its public id")?
                .to_string(),
        )?;
        let key = intent["workspace_key"]
            .as_str()
            .context("stored workspace creation omitted its key")?
            .to_string();
        let marked_key = key.clone();
        let name = intent["name"]
            .as_str()
            .context("stored workspace creation omitted its name")?
            .to_string();
        let index = state.workspaces.len();
        let workspace = Workspace {
            id: workspace_slot,
            public_id: public_id.clone(),
            key: key.clone(),
            name: name.clone(),
            screens: Vec::new(),
            active_screen: 0,
        };
        let mut order = Vec::with_capacity(index + 1);
        order.extend(state.workspaces.iter().map(|workspace| workspace.public_id.clone()));
        order.push(public_id.clone());
        state.workspaces.reserve(1);
        state.workspace_index_by_id.reserve(1);
        state.workspace_id_by_key.reserve(1);
        state.resource_indexes.workspaces.reserve(1);
        state.resource_indexes.workspace_ids.reserve(1);
        let mut deltas = Vec::with_capacity(2);
        if let Some(previous) = state.workspaces.get(state.active_workspace) {
            deltas.push(workspace_resource_upsert(
                0,
                registry.session_id().as_str(),
                &previous.public_id,
                &previous.name,
                state.active_workspace,
                false,
            ));
        }
        deltas.push(workspace_resource_upsert(
            deltas.len(),
            registry.session_id().as_str(),
            &public_id,
            &name,
            index,
            true,
        ));
        let created_path = json!({"kind":"workspace","workspace_id":public_id});
        let durable = RegistryWorkspace {
            id: workspace.id,
            public_id: public_id.clone(),
            key: key.clone(),
            name: name.clone(),
            group_key: self.session.clone(),
        };
        let mut desired = self.registry_projection(&state);
        desired.push(durable.clone());
        let plan = ResourceMutationPlan::new(
            ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: durable,
                        position: index,
                        active_screen: None,
                    },
                    ResourceChange::SetWorkspaceOrder { workspace_ids: order },
                    ResourceChange::SetActiveWorkspace { workspace_id: Some(public_id.clone()) },
                ],
            },
            json!({
                "workspace":public_id,
                "name":name,
                "index":index,
            }),
            Value::Array(deltas),
            move |state| {
                state.push_workspace(workspace);
                state.active_workspace = index;
            },
        )
        .with_workspace_ledger(ResourceWorkspaceLedger {
            event_kind: "workspace-added",
            workspace_key: key,
            workspaces: desired,
            legacy_result: json!({
                "workspace":public_id,
                "name":name,
                "index":index,
            }),
            presentation: None,
        })
        .with_metrics(ResourceMutationMetrics {
            touched_resources: 1,
            order_entries: index + 1,
            terminal_queries: 0,
            changed_rows: index + 3,
        });
        #[cfg(test)]
        {
            *self.resource_mutation_metrics.lock().unwrap() = Some(plan.metrics);
        }
        let marked = public_id.as_str().to_string();
        let write_mark = move |tx: &rusqlite::Transaction<'_>| mark.write(tx, &marked, &marked_key);
        let (commit, workspace_revision) = registry.commit_resource_creation_patch(
            correlation_key,
            mutation,
            "workspace.create",
            &fingerprint,
            &plan.patch,
            &plan.result,
            &created_path,
            &plan.deltas,
            plan.workspace_ledger.as_ref(),
            mark.writes()
                .then_some(&write_mark as crate::workspace_registry::RegistryTransactionWrite<'_>),
        )?;
        plan.apply(&mut state, &commit, workspace_revision);
        // Push the same coarse tree event a terminal-bearing create emits
        // (`emit_committed_workspace_delta` in the legacy create path), so
        // `subscribe` clients see the empty workspace now instead of when
        // the next real change flushes an event.
        let entity = crate::server::tree_entity_json(
            &state,
            &notifications,
            TreeDeltaKind::WorkspaceAdded,
            workspace_slot,
        )
        .expect("new empty workspace is present in tree snapshot");
        drop(state);
        self.emit_committed_workspace_delta(
            &registry,
            TreeDelta {
                kind: TreeDeltaKind::WorkspaceAdded,
                workspace: workspace_slot,
                screen: None,
                pane: None,
                surface: None,
                index: Some(index),
                entity,
                workspace_revision,
                transaction: None,
            },
            index > 0,
        );
        drop(registry);
        self.publish_resource_event();
        Ok(commit)
    }

    pub(crate) fn resource_pane_neighbor_selected(
        &self,
        selectors: &ResourceSelectors,
        direction: &str,
    ) -> anyhow::Result<Option<PanePublicId>> {
        let direction = parse_direction(direction)?;
        let registry = self.workspace_registry.lock().unwrap();
        let state = self.state.lock().unwrap();
        let resolved = self
            .resolve_resource_path_in_state(&state, &registry, ResourceTarget::Pane, selectors)
            .map_err(anyhow::Error::new)?;
        let pane = resolved.pane.context("pane selector resolved without a live pane")?;
        let (workspace, screen) = state.screen_of(pane).context("resolved pane has no screen")?;
        let screen = &state.workspaces[workspace].screens[screen];
        let (dx, dy) = direction.delta();
        let layout = Self::pane_navigation_layout(screen, pane, direction);
        let neighbor = layout.neighbor(pane, dx, dy);
        neighbor
            .map(|pane| {
                state
                    .resource_indexes
                    .pane_ids
                    .get(&pane)
                    .cloned()
                    .context("neighbor pane has no public identity")
            })
            .transpose()
    }

    #[allow(clippy::too_many_arguments)]
    pub(crate) fn resource_topology_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let commit = self.commit_resource_topology_operation(
            operation,
            selectors,
            fields,
            expected_revision,
            mutation,
        )?;
        if !commit.replayed {
            self.emit_resource_topology_legacy_events(operation, &commit);
        }
        Ok(commit)
    }

    /// Execute a destination-creating frontend action through the durable
    /// correlation engine. Selector candidates are ordered by the frontend's
    /// local focus projection; the first still-live path is captured in the
    /// durable intent while holding the creation lifecycle fence.
    pub fn receipted_surface_creation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selector_candidates: Vec<ResourceSelectors>,
        fields: Map<String, Value>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<(SurfaceId, bool)> {
        anyhow::ensure!(
            is_created_path_operation(operation),
            "{} is not a destination-creating operation",
            operation_name(operation)
        );
        anyhow::ensure!(!selector_candidates.is_empty(), "creation requires one primary selector");
        anyhow::ensure!(
            selector_candidates.len() <= MAX_CREATION_SELECTOR_FALLBACKS + 1,
            "creation accepts one primary selector and at most \
             {MAX_CREATION_SELECTOR_FALLBACKS} fallbacks"
        );
        if selector_candidates.len() > 1 {
            anyhow::ensure!(
                selector_candidates
                    .iter()
                    .all(|selectors| effect_target(operation, selectors) == ResourceTarget::Pane),
                "creation selector fallbacks require pane selectors"
            );
        }
        let fingerprint_fields = semantic_creation_fields(&fields);
        let mut fingerprint = json!({
            "operation": operation_name(operation),
            "selectors": &selector_candidates[0],
            "fields": fingerprint_fields,
        });
        if selector_candidates.len() > 1 {
            fingerprint["selector_fallbacks"] = json!(&selector_candidates[1..]);
        }
        let commit = self.resource_correlated_creation_operation(
            operation,
            selector_candidates,
            fields,
            None,
            mutation,
            &fingerprint,
        )?;
        if !commit.replayed {
            self.emit_resource_topology_legacy_events(operation, &commit);
        }
        let surface = self.resource_surface_for_created_path(&commit.result)?;
        Ok((surface, commit.replayed))
    }

    #[allow(clippy::too_many_arguments)]
    pub(in crate::mux) fn commit_resource_topology_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint_fields = if is_created_path_operation(operation) {
            semantic_creation_fields(&fields)
        } else {
            fields.clone()
        };
        let fingerprint = json!({
            "operation": operation_name(operation),
            "selectors": selectors,
            "fields": fingerprint_fields,
        });
        let commit = match operation {
            ResourceOperation::WorkspaceFocus => {
                self.resource_focus_workspace(selectors, expected_revision, mutation, &fingerprint)?
            }
            ResourceOperation::ScreenRename => self.resource_rename_screen(
                selectors,
                nullable_name(&fields)?,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::ScreenFocus => {
                self.resource_focus_screen(selectors, expected_revision, mutation, &fingerprint)?
            }
            ResourceOperation::PaneRename => self.resource_rename_pane(
                selectors,
                nullable_name(&fields)?,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::PaneFocus => {
                self.resource_focus_pane(selectors, expected_revision, mutation, &fingerprint)?
            }
            ResourceOperation::PaneFocusDirection => self.resource_focus_pane_direction(
                selectors,
                required_str(&fields, "direction")?,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::PaneSwap => self.resource_swap_panes(
                selectors,
                &fields,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::PaneZoom => self.resource_zoom_pane(
                selectors,
                fields.get("enabled").and_then(Value::as_bool),
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::PaneSplitRatioSet => self.resource_set_split_ratio(
                selectors,
                required_str(&fields, "split_id")?,
                required_f64(&fields, "ratio")?,
                LayoutMutationContext {
                    coalesce: layout_resize_coalesce(&fields)?,
                    expected_revision,
                    mutation,
                    fingerprint: &fingerprint,
                },
            )?,
            ResourceOperation::PaneViewportWidthSet => self.resource_set_viewport_width(
                selectors,
                fields.get("columns").and_then(Value::as_u64),
                fields.get("width").and_then(Value::as_f64),
                LayoutMutationContext {
                    coalesce: layout_resize_coalesce(&fields)?,
                    expected_revision,
                    mutation,
                    fingerprint: &fingerprint,
                },
            )?,
            ResourceOperation::ColumnUpdate => self.resource_update_column(
                selectors,
                &fields,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::TabRename => self.resource_rename_tab(
                selectors,
                nullable_name(&fields)?,
                crate::resource_name::TabNameUpdate::parse(&fields)?,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            ResourceOperation::TabFocus => {
                self.resource_focus_tab(selectors, expected_revision, mutation, &fingerprint)?
            }
            ResourceOperation::TabMove => self.resource_move_tab_selected(
                selectors,
                &fields,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            operation if is_effectful(operation) => self.resource_effectful_topology_operation(
                operation,
                selectors,
                fields,
                expected_revision,
                mutation,
                &fingerprint,
            )?,
            _ => anyhow::bail!("unsupported topology operation {}", operation_name(operation)),
        };
        Ok(commit)
    }

    pub(crate) fn emit_resource_topology_legacy_events(
        &self,
        operation: ResourceOperation,
        commit: &ResourcePatchCommit,
    ) {
        if matches!(operation, ResourceOperation::PaneCreate | ResourceOperation::PaneSplit) {
            return;
        }
        self.emit(MuxEvent::TreeChanged);
        if matches!(
            operation,
            ResourceOperation::PaneSwap
                | ResourceOperation::PaneZoom
                | ResourceOperation::PaneSplitRatioSet
                | ResourceOperation::PaneViewportWidthSet
                | ResourceOperation::ColumnUpdate
                | ResourceOperation::WorkspaceLayoutApply
                | ResourceOperation::ScreenLayoutUndo
                | ResourceOperation::PaneCreate
                | ResourceOperation::PaneSplit
                | ResourceOperation::PaneClose
        ) && let Some(screen) = commit
            .result
            .get("screen")
            .or_else(|| commit.result.get("screen_id"))
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())
            .and_then(|id| {
                self.with_state(|state| state.resource_indexes.screens.get(&id).copied())
            })
        {
            self.emit(MuxEvent::LayoutChanged(screen));
        }
    }
}
