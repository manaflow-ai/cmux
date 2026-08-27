use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use anyhow::Context;
use serde_json::{Map, Value, json};

use super::*;
use crate::model::{LayoutColumn, ScreenLayoutSnapshot};
use crate::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, ResourceError, ResourceOperation,
    ScreenPublicId, SplitPublicId, TabPublicId, TabResourceIdentity, WorkspacePublicId,
};
use crate::resource_mutation::ResourceMutationPlan;
use crate::server::MAX_CREATION_SELECTOR_FALLBACKS;
use crate::workspace_registry::{
    RegistryPane, RegistryScreen, RegistryViewportColumn, ResourceCreationPreparation,
    ResourceCreationRecovery, ResourcePatchCommit, ResourceWorkspaceClose, TerminalLifecycle,
    TerminalOnExit, TerminalResourceCloseCommit,
};
use crate::{ResolvedResourcePath, ResourceSelectors, ResourceTarget, SurfaceKind};

#[derive(Clone, Copy)]
struct LayoutMutationContext<'a> {
    coalesce: Option<LayoutMutationKey>,
    expected_revision: Option<u64>,
    mutation: &'a WorkspaceMutation,
    fingerprint: &'a Value,
}

#[derive(Clone, Copy)]
struct ResourceEffectIntentContext<'a> {
    expected_revision: Option<u64>,
    mutation_origin: &'a str,
}

struct PaneAddOptions<'a> {
    direction: Option<&'a str>,
    cwd: Option<String>,
    size: Option<(u16, u16)>,
    ratio: Option<f32>,
    viewport_width: Option<f32>,
}

struct TerminalEffectOptions {
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    name: Option<String>,
    created_screen_name: Option<String>,
    size: Option<(u16, u16)>,
    on_exit: Option<TerminalOnExit>,
}

struct CreatedTerminalEffect {
    path: Value,
}

#[derive(Default)]
struct ResourceCloseInputs {
    surface_ids: Vec<SurfaceId>,
    delta: Option<TreeDelta>,
    changed_screens: Vec<ScreenId>,
    workspace_metadata: Option<(WorkspaceId, usize, String)>,
    terminal_runtime: Option<Arc<Surface>>,
    terminal_batch: Vec<(String, Option<String>)>,
    terminal_public_id: Option<TerminalPublicId>,
}

struct ResourceClosePlan {
    state: State,
    removed: Vec<Arc<Surface>>,
    terminal_runtime: Option<Arc<Surface>>,
    closed_terminal_public_id: Option<TerminalPublicId>,
    terminal_batch: Vec<(String, Option<String>)>,
    workspace_close: Option<ResourceWorkspaceClose>,
    delta: Option<TreeDelta>,
    changed_screens: Vec<ScreenId>,
    selection_resync: bool,
}

struct ResourceCloseEffects {
    removed: Vec<Arc<Surface>>,
    terminal_runtime: Option<Arc<Surface>>,
    closed_terminal_public_id: Option<TerminalPublicId>,
    tree_publication: ResourceCloseTreePublication,
    changed_screens: Vec<ScreenId>,
    selection_resync: bool,
    empty_revision: Option<u64>,
}

fn terminal_close_state_error(detail: impl Into<String>) -> anyhow::Error {
    anyhow::Error::msg(detail.into()).context("terminal close state is unavailable")
}

enum ResourceCloseTreePublication {
    PendingDelta(TreeDelta),
    PendingSnapshot,
    // Revisioned workspace deltas publish before the registry guard is released.
    Published,
}

struct CommittedResourceClose {
    commit: ResourcePatchCommit,
    effects: ResourceCloseEffects,
}

impl ResourceClosePlan {
    fn install(
        mut self,
        state: &mut State,
        resource_revision: u64,
        workspace_revision: Option<u64>,
    ) -> ResourceCloseEffects {
        self.state.resource_revision = resource_revision;
        if let Some(revision) = workspace_revision {
            self.state.workspace_revision = revision;
            if let Some(delta) = &mut self.delta {
                delta.workspace_revision = Some(revision);
            }
        }
        let empty_revision =
            self.state.workspaces.is_empty().then_some(self.state.workspace_revision);
        *state = self.state;
        ResourceCloseEffects {
            removed: self.removed,
            terminal_runtime: self.terminal_runtime,
            closed_terminal_public_id: self.closed_terminal_public_id,
            tree_publication: self.delta.map_or(
                ResourceCloseTreePublication::PendingSnapshot,
                ResourceCloseTreePublication::PendingDelta,
            ),
            changed_screens: self.changed_screens,
            selection_resync: self.selection_resync,
            empty_revision,
        }
    }
}

pub(super) struct TerminalExitDetachProjection {
    state: State,
    runtime: Option<Arc<Surface>>,
    removed: Vec<Arc<Surface>>,
    targets: Vec<SurfaceId>,
    pub(super) tab_ids: Vec<TabPublicId>,
    pub(super) patch: ResourcePatch,
    pub(super) changes: Value,
    changed_screens: Vec<ScreenId>,
    selection_resync: bool,
}

pub(super) struct TerminalExitDetachEffects {
    runtime: Option<Arc<Surface>>,
    removed: Vec<Arc<Surface>>,
    targets: Vec<SurfaceId>,
    changed_screens: Vec<ScreenId>,
    selection_resync: bool,
    empty_revision: Option<u64>,
}

impl TerminalExitDetachProjection {
    pub(super) fn install(
        mut self,
        state: &mut State,
        resource_revision: u64,
    ) -> TerminalExitDetachEffects {
        self.state.resource_revision = resource_revision;
        let empty_revision =
            self.state.workspaces.is_empty().then_some(self.state.workspace_revision);
        *state = self.state;
        TerminalExitDetachEffects {
            runtime: self.runtime,
            removed: self.removed,
            targets: self.targets,
            changed_screens: self.changed_screens,
            selection_resync: self.selection_resync,
            empty_revision,
        }
    }
}

struct ResourceCreationActivity<'a> {
    active: &'a AtomicBool,
}

impl<'a> ResourceCreationActivity<'a> {
    fn begin(active: &'a AtomicBool) -> Self {
        debug_assert!(!active.swap(true, Ordering::AcqRel));
        Self { active }
    }
}

impl Drop for ResourceCreationActivity<'_> {
    fn drop(&mut self) {
        self.active.store(false, Ordering::Release);
    }
}

impl Mux {
    #[cfg(test)]
    pub(crate) fn set_resource_terminal_reservation_hook_for_test(
        &self,
        hook: Option<TerminalReservationHook>,
    ) {
        *self.terminal_create_after_terminal_reservation.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failure_for_test(&self, enabled: bool) {
        self.workspace_registry.lock().unwrap().set_resource_patch_failure(enabled).unwrap();
    }

    #[cfg(test)]
    pub(crate) fn set_resource_patch_failures_remaining_for_test(&self, failures: u64) {
        self.workspace_registry.lock().unwrap().set_resource_patch_failures_remaining(failures);
    }

    #[cfg(test)]
    pub(crate) fn set_resource_close_after_commit_hook_for_test(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.resource_close_after_commit.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(crate) fn set_resource_close_cleanup_hook_for_test(
        &self,
        hook: Option<Arc<dyn Fn() + Send + Sync>>,
    ) {
        *self.resource_close_cleanup.lock().unwrap() = hook;
    }

    #[cfg(test)]
    pub(crate) fn resource_terminal_lifecycle_for_test(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<Option<(String, Option<String>)>> {
        Ok(self.workspace_registry.lock().unwrap().terminal_record(terminal_id)?.map(|terminal| {
            (terminal_lifecycle_name(terminal.lifecycle).to_string(), terminal.incarnation)
        }))
    }

    pub(crate) fn resource_creation_resolution(
        self: &Arc<Self>,
        correlation_key: &str,
    ) -> anyhow::Result<Value> {
        self.reconcile_interrupted_resource_creation(correlation_key)?;
        self.workspace_registry.lock().unwrap().resolve_resource_creation(correlation_key)
    }

    pub(super) fn reconcile_interrupted_resource_creations(&self) -> anyhow::Result<bool> {
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

    fn reconcile_interrupted_resource_creation(&self, correlation_key: &str) -> anyhow::Result<()> {
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
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = json!({
            "operation":"workspace.create",
            "selectors":&selectors,
            "fields":{
                "initial_content":"empty",
                "name":&name,
            },
        });
        if let Some(name) = name.as_deref() {
            Self::validate_workspace_name(name)?;
        }
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
        let preparation = registry.prepare_resource_creation(
            correlation_key,
            &mutation.id,
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
        let plan = ResourceMutationPlan::new(
            ResourcePatch {
                changes: vec![
                    ResourceChange::UpsertWorkspace {
                        workspace: RegistryWorkspace {
                            id: workspace.id,
                            public_id: public_id.clone(),
                            key,
                            name: name.clone(),
                            group_key: self.session.clone(),
                        },
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
                state.workspace_revision = state.workspace_revision.saturating_add(1);
            },
        )
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
        let commit = registry.commit_resource_creation_patch(
            correlation_key,
            mutation,
            "workspace.create",
            &fingerprint,
            &plan.patch,
            &plan.result,
            &created_path,
            &plan.deltas,
        )?;
        plan.apply(&mut state, &commit);
        drop(state);
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
    pub(super) fn commit_resource_topology_operation(
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
            ResourceOperation::TabRename => self.resource_rename_tab(
                selectors,
                nullable_name(&fields)?,
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

    pub(super) fn emit_resource_topology_legacy_events(
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

    fn resource_focus_workspace(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            "workspace.focus",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Workspace,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let workspace = resolved
                    .workspace
                    .context("workspace selector resolved without a live workspace")?;
                let index =
                    state.workspace_index(workspace).context("resolved workspace has no index")?;
                let target = state.workspaces[index].public_id.clone();
                let topology = registry.resource_topology_snapshot()?;
                let previous = topology.active_workspace.clone();
                let mut after = topology.clone();
                after.active_workspace = Some(target.clone());
                let deltas =
                    focus_deltas(state, &topology, &after, previous, Some(target.clone()))?;
                let active_pane =
                    state.workspaces[index].active_screen_ref().map(|screen| screen.active_pane);
                let result = json!({"workspace":target});
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![ResourceChange::SetActiveWorkspace {
                            workspace_id: Some(target),
                        }],
                    },
                    result,
                    deltas,
                    move |state| {
                        state.active_workspace = index;
                        if let Some(pane) = active_pane {
                            stamp_pane_focus(&mux, state, pane);
                        }
                    },
                ))
            },
        )
    }

    fn resource_rename_screen(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "screen.rename",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Screen,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let screen = resolved.screen.context("screen selector has no live screen")?;
                let screen_id = resolved.path.screen.context("screen selector has no public id")?;
                let (workspace_index, screen_index) =
                    find_screen(state, screen).context("resolved screen disappeared")?;
                let topology = registry.resource_topology_snapshot()?;
                let mut durable = topology_screen(&topology, &screen_id)?.clone();
                durable.name = name.clone();
                let value = screen_value(
                    &durable,
                    &topology,
                    topology.active_workspace.as_ref(),
                    active_screen(&topology, &durable.workspace_id),
                )?;
                let result = json!({"screen":screen_id});
                let deltas = upserts([("screen", screen_id.as_str(), value)]);
                let apply_name = name;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        state.workspaces[workspace_index].screens[screen_index].name = apply_name;
                    },
                ))
            },
        )
    }

    fn resource_rename_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "pane.rename",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let topology = registry.resource_topology_snapshot()?;
                let mut durable = topology_pane(&topology, &pane_id)?.clone();
                durable.name = name.clone();
                let value = pane_value(state, &durable, &topology)?;
                let result = json!({"pane":pane_id});
                let deltas = upserts([("pane", pane_id.as_str(), value)]);
                let apply_name = name;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertPane(durable)] },
                    result,
                    deltas,
                    move |state| {
                        state.panes.get_mut(&pane).expect("planned pane remains live").name =
                            apply_name;
                    },
                ))
            },
        )
    }

    fn resource_rename_tab(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        name: Option<String>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "tab.rename",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Tab,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let surface = resolved.tab.context("tab selector has no live surface")?;
                let tab_id = resolved.path.tab.context("tab selector has no public id")?;
                let topology = registry.resource_topology_snapshot()?;
                let mut durable = topology_tab(&topology, &tab_id)?.clone();
                durable.name = name.clone();
                let value = tab_value(&durable, &topology)?;
                let result = json!({"tab":tab_id});
                let deltas = upserts([("tab", tab_id.as_str(), value)]);
                let apply_name = name;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertTab(durable)] },
                    result,
                    deltas,
                    move |state| {
                        state
                            .surfaces
                            .get(&surface)
                            .expect("planned tab remains live")
                            .set_name(apply_name);
                    },
                ))
            },
        )
    }

    fn resource_focus_screen(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            "screen.focus",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Screen,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let screen = resolved.screen.context("screen selector has no live screen")?;
                let screen_id = resolved.path.screen.context("screen selector has no public id")?;
                let workspace_id =
                    resolved.path.workspace.context("screen selector has no workspace id")?;
                let workspace =
                    resolved.workspace.context("screen selector has no live workspace")?;
                let (workspace_index, screen_index) =
                    find_screen(state, screen).context("resolved screen disappeared")?;
                let topology = registry.resource_topology_snapshot()?;
                let previous = topology.active_workspace.clone();
                let mut after = topology.clone();
                after.active_workspace = Some(workspace_id.clone());
                set_active_screen(&mut after, &workspace_id, Some(screen_id.clone()));
                let deltas =
                    focus_deltas(state, &topology, &after, previous, Some(workspace_id.clone()))?;
                let workspace_record =
                    registry_workspace(state, workspace_index, registry.session_id().as_str());
                let result = json!({"screen":screen_id});
                let active_pane =
                    state.workspaces[workspace_index].screens[screen_index].active_pane;
                Ok(ResourceMutationPlan::new(
                    ResourcePatch {
                        changes: vec![
                            ResourceChange::UpsertWorkspace {
                                workspace: workspace_record,
                                position: workspace_index,
                                active_screen: Some(screen_id),
                            },
                            ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace_id) },
                        ],
                    },
                    result,
                    deltas,
                    move |state| {
                        state.active_workspace = workspace_index;
                        state.workspaces[workspace_index].active_screen = screen_index;
                        debug_assert_eq!(state.workspaces[workspace_index].id, workspace);
                        stamp_pane_focus(&mux, state, active_pane);
                    },
                ))
            },
        )
    }

    fn resource_focus_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.resource_focus_pane_impl(
            "pane.focus",
            selectors,
            None,
            expected_revision,
            mutation,
            fingerprint,
        )
    }

    fn resource_focus_pane_direction(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        direction: &str,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.resource_focus_pane_impl(
            "pane.focus_direction",
            selectors,
            Some(parse_direction(direction)?),
            expected_revision,
            mutation,
            fingerprint,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn resource_focus_pane_impl(
        self: &Arc<Self>,
        operation: &'static str,
        selectors: ResourceSelectors,
        direction: Option<Direction>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let selected = resolved.pane.context("pane selector has no live pane")?;
                let pane = if let Some(direction) = direction {
                    let (workspace, screen) =
                        state.screen_of(selected).context("resolved pane has no screen")?;
                    let screen = &state.workspaces[workspace].screens[screen];
                    let (dx, dy) = direction.delta();
                    Self::pane_navigation_layout(screen, selected, direction)
                        .neighbor_by_recency(selected, dx, dy, |candidate| {
                            state
                                .panes
                                .get(&candidate)
                                .map(|pane| pane.focused_at)
                                .unwrap_or_default()
                        })
                        .context("pane has no neighbor in that direction")?
                } else {
                    selected
                };
                focus_pane_plan(&mux, state, registry, pane)
            },
        )
    }

    fn resource_focus_tab(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.resource_select_tab_impl(
            "tab.focus",
            selectors,
            true,
            expected_revision,
            mutation,
            fingerprint,
        )
    }

    pub(super) fn commit_ordinary_tab_selection(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let fingerprint = json!({
            "operation":"tab.select",
            "selectors":&selectors,
            "fields":{},
        });
        self.resource_select_tab_impl(
            "tab.select",
            selectors,
            false,
            None,
            &WorkspaceMutation::local("cmux-tui"),
            &fingerprint,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn resource_select_tab_impl(
        self: &Arc<Self>,
        operation: &'static str,
        selectors: ResourceSelectors,
        focus_target_pane: bool,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Tab,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let surface = resolved.tab.context("tab selector has no live surface")?;
                let tab_id = resolved.path.tab.context("tab selector has no public id")?;
                let pane = state.pane_of(surface).context("resolved tab has no pane")?;
                let focus_path = focus_target_pane || state.active_pane() == Some(pane);
                let mut plan = if focus_path {
                    focus_pane_plan(&mux, state, registry, pane)?
                } else {
                    ResourceMutationPlan::new(
                        ResourcePatch { changes: Vec::new() },
                        json!({}),
                        json!([]),
                        |_| {},
                    )
                };
                let topology = registry.resource_topology_snapshot()?;
                let pane_id = state.resource_indexes.pane_ids[&pane].clone();
                let mut durable = topology_pane(&topology, &pane_id)?.clone();
                let previous_active = durable.active_tab.clone();
                durable.active_tab = Some(tab_id.clone());
                plan.patch.changes.push(ResourceChange::UpsertPane(durable.clone()));
                let index = state.panes[&pane]
                    .tabs
                    .iter()
                    .position(|candidate| *candidate == surface)
                    .context("resolved tab disappeared")?;
                let mut deltas = plan.deltas.as_array().cloned().unwrap_or_default();
                let mut after = topology;
                *topology_pane_mut(&mut after, &pane_id)? = durable;
                let mut changed_tabs = [previous_active, Some(tab_id.clone())]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>();
                changed_tabs.sort();
                changed_tabs.dedup();
                for changed in changed_tabs {
                    deltas.push(upsert(
                        deltas.len(),
                        "tab",
                        changed.as_str(),
                        tab_value(topology_tab(&after, &changed)?, &after)?,
                    ));
                }
                plan.deltas = Value::Array(deltas);
                plan.result = json!({"tab":tab_id});
                let prior_apply = std::mem::replace(
                    &mut plan,
                    ResourceMutationPlan::new(
                        ResourcePatch { changes: Vec::new() },
                        json!({}),
                        json!([]),
                        |_| {},
                    ),
                );
                let ResourceMutationPlan { patch, result, deltas, metrics, .. } = prior_apply;
                let apply_mux = Arc::clone(&mux);
                Ok(ResourceMutationPlan::new(patch, result, deltas, move |state| {
                    if focus_path {
                        apply_focus_path(&apply_mux, state, pane);
                    } else {
                        state.panes.get_mut(&pane).expect("planned pane remains live").active_at =
                            apply_mux.next_active_at();
                    }
                    state.panes.get_mut(&pane).expect("planned pane remains live").active_tab =
                        index;
                })
                .with_metrics(metrics))
            },
        )
    }

    fn resource_swap_panes(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let other_workspace = required_str(fields, "other_workspace")?.to_string();
        let other_screen = required_str(fields, "other_screen")?.to_string();
        let other_pane = required_str(fields, "other_pane")?.to_string();
        self.commit_resource_mutation_plan(
            mutation,
            "pane.swap",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let first = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let other_selectors = ResourceSelectors {
                    machine: selectors.machine.clone(),
                    session: selectors.session.clone(),
                    workspace: Some(other_workspace),
                    screen: Some(other_screen),
                    pane: Some(other_pane),
                    ..Default::default()
                };
                let second = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &other_selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let first_pane = first.pane.context("pane selector has no live pane")?;
                let second_pane = second.pane.context("other pane selector has no live pane")?;
                anyhow::ensure!(first_pane != second_pane, "cannot swap a pane with itself");
                let first_id = first.path.pane.context("pane selector has no public id")?;
                let second_id = second.path.pane.context("other pane selector has no public id")?;
                let first_screen =
                    state.screen_of(first_pane).context("first pane has no screen")?;
                let second_screen =
                    state.screen_of(second_pane).context("second pane has no screen")?;
                let mut first_layout =
                    state.workspaces[first_screen.0].screens[first_screen.1].layout_snapshot();
                let mut second_layout = (first_screen != second_screen).then(|| {
                    state.workspaces[second_screen.0].screens[second_screen.1].layout_snapshot()
                });
                swap_layout_panes(
                    &mut first_layout,
                    first_pane,
                    second_pane,
                    first_screen == second_screen,
                )?;
                if let Some(layout) = second_layout.as_mut() {
                    swap_layout_panes(layout, first_pane, second_pane, false)?;
                }
                let mut topology = registry.resource_topology_snapshot()?;
                if first_screen != second_screen {
                    let first_screen_id =
                        state.workspaces[first_screen.0].screens[first_screen.1].public_id.clone();
                    let second_screen_id = state.workspaces[second_screen.0].screens
                        [second_screen.1]
                        .public_id
                        .clone();
                    topology_pane_mut(&mut topology, &first_id)?.screen_id = second_screen_id;
                    topology_pane_mut(&mut topology, &second_id)?.screen_id = first_screen_id;
                }
                let first_durable = registry_screen_from_layout(
                    state,
                    first_screen.0,
                    first_screen.1,
                    &first_layout,
                    &topology,
                    state.workspaces[first_screen.0].screens[first_screen.1].name.clone(),
                )?;
                let second_durable = second_layout
                    .as_ref()
                    .map(|layout| {
                        registry_screen_from_layout(
                            state,
                            second_screen.0,
                            second_screen.1,
                            layout,
                            &topology,
                            state.workspaces[second_screen.0].screens[second_screen.1].name.clone(),
                        )
                    })
                    .transpose()?;
                let first_pane_record = topology_pane(&topology, &first_id)?.clone();
                let second_pane_record = topology_pane(&topology, &second_id)?.clone();
                let mut changes = vec![
                    ResourceChange::UpsertScreen(first_durable.clone()),
                    ResourceChange::UpsertPane(first_pane_record.clone()),
                    ResourceChange::UpsertPane(second_pane_record.clone()),
                ];
                if let Some(screen) = second_durable.clone() {
                    changes.push(ResourceChange::UpsertScreen(screen));
                }
                let mut event_values = vec![
                    (
                        "screen",
                        first_durable.public_id.to_string(),
                        screen_value(
                            &first_durable,
                            &topology,
                            topology.active_workspace.as_ref(),
                            active_screen(&topology, &first_durable.workspace_id),
                        )?,
                    ),
                    (
                        "pane",
                        first_id.to_string(),
                        pane_value(state, &first_pane_record, &topology)?,
                    ),
                    (
                        "pane",
                        second_id.to_string(),
                        pane_value(state, &second_pane_record, &topology)?,
                    ),
                ];
                if let Some(screen) = &second_durable {
                    event_values.push((
                        "screen",
                        screen.public_id.to_string(),
                        screen_value(
                            screen,
                            &topology,
                            topology.active_workspace.as_ref(),
                            active_screen(&topology, &screen.workspace_id),
                        )?,
                    ));
                }
                let deltas = Value::Array(
                    event_values
                        .into_iter()
                        .enumerate()
                        .map(|(sequence, (resource, id, value))| {
                            upsert(sequence, resource, &id, value)
                        })
                        .collect(),
                );
                let result = json!({"pane":first_id,"screen":first_durable.public_id});
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    deltas,
                    move |state| {
                        apply_layout_snapshot(
                            &mut state.workspaces[first_screen.0].screens[first_screen.1],
                            first_layout,
                        );
                        if let Some(layout) = second_layout {
                            apply_layout_snapshot(
                                &mut state.workspaces[second_screen.0].screens[second_screen.1],
                                layout,
                            );
                        }
                        if first_screen != second_screen {
                            let first_screen_slot =
                                state.workspaces[first_screen.0].screens[first_screen.1].id;
                            let second_screen_slot =
                                state.workspaces[second_screen.0].screens[second_screen.1].id;
                            state
                                .resource_indexes
                                .pane_screen
                                .insert(first_pane, second_screen_slot);
                            state
                                .resource_indexes
                                .pane_screen
                                .insert(second_pane, first_screen_slot);
                        }
                        Self::rebuild_split_screen_index(state);
                    },
                ))
            },
        )
    }

    fn resource_move_tab_selected(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let destination_workspace = required_str(fields, "destination_workspace")?.to_string();
        let destination_screen = required_str(fields, "destination_screen")?.to_string();
        let destination_pane = required_str(fields, "destination_pane")?.to_string();
        let index =
            usize::try_from(required_u64(fields, "index")?).context("tab index exceeds usize")?;
        let mux = Arc::clone(self);
        self.commit_resource_mutation_plan(
            mutation,
            "tab.move",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let source = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Tab,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let destination_selectors = ResourceSelectors {
                    machine: selectors.machine.clone(),
                    session: selectors.session.clone(),
                    workspace: Some(destination_workspace),
                    screen: Some(destination_screen),
                    pane: Some(destination_pane),
                    ..Default::default()
                };
                let destination = mux
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &destination_selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let target_workspace_id = destination
                    .path
                    .workspace
                    .clone()
                    .context("destination omitted workspace id")?;
                let target_screen_id =
                    destination.path.screen.clone().context("destination omitted screen id")?;
                let target_workspace_slot =
                    destination.workspace.context("destination workspace is not live")?;
                let target_workspace_index = state
                    .workspace_index(target_workspace_slot)
                    .context("destination workspace disappeared")?;
                let surface = source.tab.context("tab selector has no live surface")?;
                let tab_id = source.path.tab.context("tab selector has no public id")?;
                let source_pane = state.pane_of(surface).context("resolved tab has no pane")?;
                let target_pane =
                    destination.pane.context("destination pane selector has no live pane")?;
                let source_tabs = state.panes[&source_pane].tabs.clone();
                let old_index = source_tabs
                    .iter()
                    .position(|candidate| *candidate == surface)
                    .context("resolved tab disappeared")?;
                let structural = source_pane != target_pane && source_tabs.len() == 1;
                if structural {
                    return structural_tab_move_plan(
                        &mux,
                        state,
                        registry,
                        surface,
                        tab_id.clone(),
                        source_pane,
                        target_pane,
                        index,
                        json!({"tab":tab_id}),
                    );
                }
                let topology = registry.resource_topology_snapshot()?;
                let source_pane_id = state.resource_indexes.pane_ids[&source_pane].clone();
                let target_pane_id = state.resource_indexes.pane_ids[&target_pane].clone();
                let mut moved_tab = topology_tab(&topology, &tab_id)?.clone();
                let mut source_order = topology
                    .tabs
                    .iter()
                    .filter(|tab| tab.pane_id == source_pane_id)
                    .map(|tab| tab.public_id.clone())
                    .collect::<Vec<_>>();
                let mut target_order = if source_pane == target_pane {
                    Vec::new()
                } else {
                    topology
                        .tabs
                        .iter()
                        .filter(|tab| tab.pane_id == target_pane_id)
                        .map(|tab| tab.public_id.clone())
                        .collect::<Vec<_>>()
                };
                source_order.remove(old_index);
                let final_index = if source_pane == target_pane {
                    let final_index =
                        if index > old_index { index.saturating_sub(1) } else { index }
                            .min(source_order.len());
                    source_order.insert(final_index, tab_id.clone());
                    final_index
                } else {
                    let final_index = index.min(target_order.len());
                    target_order.insert(final_index, tab_id.clone());
                    moved_tab.pane_id = target_pane_id.clone();
                    final_index
                };
                moved_tab.position = final_index;
                let mut source_record = topology_pane(&topology, &source_pane_id)?.clone();
                let mut target_record = topology_pane(&topology, &target_pane_id)?.clone();
                if source_pane == target_pane {
                    source_record.active_tab = Some(tab_id.clone());
                    target_record = source_record.clone();
                } else {
                    source_record.active_tab = source_order
                        .get(
                            state.panes[&source_pane]
                                .active_tab
                                .min(source_order.len().saturating_sub(1)),
                        )
                        .cloned();
                    target_record.active_tab = Some(tab_id.clone());
                }
                let mut changes = vec![
                    ResourceChange::UpsertTab(moved_tab.clone()),
                    ResourceChange::UpsertPane(source_record.clone()),
                    ResourceChange::SetTabOrder {
                        pane_id: source_pane_id.clone(),
                        tab_ids: source_order,
                    },
                ];
                if source_pane != target_pane {
                    changes.push(ResourceChange::UpsertPane(target_record.clone()));
                    changes.push(ResourceChange::SetTabOrder {
                        pane_id: target_pane_id.clone(),
                        tab_ids: target_order,
                    });
                }
                let mut after = topology.clone();
                *topology_tab_mut(&mut after, &tab_id)? = moved_tab;
                *topology_pane_mut(&mut after, &source_pane_id)? = source_record.clone();
                *topology_pane_mut(&mut after, &target_pane_id)? = target_record.clone();
                if source_pane != target_pane {
                    let target_screen = after
                        .screens
                        .iter_mut()
                        .find(|screen| screen.public_id == target_screen_id)
                        .context("destination screen is absent from durable topology")?;
                    target_screen.active_pane = target_pane_id.clone();
                    changes.push(ResourceChange::UpsertScreen(target_screen.clone()));
                    changes.push(ResourceChange::UpsertWorkspace {
                        workspace: registry_workspace(
                            state,
                            target_workspace_index,
                            registry.session_id().as_str(),
                        ),
                        position: target_workspace_index,
                        active_screen: Some(target_screen_id.clone()),
                    });
                    changes.push(ResourceChange::SetActiveWorkspace {
                        workspace_id: Some(target_workspace_id.clone()),
                    });
                    after.active_workspace = Some(target_workspace_id.clone());
                    set_active_screen(
                        &mut after,
                        &target_workspace_id,
                        Some(target_screen_id.clone()),
                    );
                }
                let mut deltas = if source_pane != target_pane {
                    focus_deltas(
                        state,
                        &topology,
                        &after,
                        topology.active_workspace.clone(),
                        Some(target_workspace_id),
                    )?
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                } else {
                    Vec::new()
                };
                let mut changed_tabs = vec![tab_id.clone()];
                changed_tabs.extend(
                    [
                        topology_pane(&topology, &source_pane_id)?.active_tab.clone(),
                        topology_pane(&topology, &target_pane_id)?.active_tab.clone(),
                        source_record.active_tab,
                        target_record.active_tab,
                    ]
                    .into_iter()
                    .flatten(),
                );
                changed_tabs.sort();
                changed_tabs.dedup();
                for changed in changed_tabs {
                    deltas.push(upsert(
                        deltas.len(),
                        "tab",
                        changed.as_str(),
                        tab_value(topology_tab(&after, &changed)?, &after)?,
                    ));
                }
                let result = json!({"tab":tab_id});
                let previous_active = state.active_pane();
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes },
                    result,
                    Value::Array(deltas),
                    move |state| {
                        let moved = move_tab_in_state(&mux, state, surface, target_pane, index).0;
                        debug_assert!(
                            moved || source_pane == target_pane && old_index == final_index
                        );
                        if moved {
                            if previous_active != Some(target_pane)
                                && state.active_pane() == Some(target_pane)
                            {
                                stamp_pane_focus(&mux, state, target_pane);
                            } else if let Some(pane) = state.panes.get_mut(&target_pane) {
                                pane.active_at = mux.next_active_at();
                            }
                        }
                    },
                ))
            },
        )
    }

    fn resource_zoom_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        enabled: Option<bool>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "pane.zoom",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let (workspace, screen) =
                    state.screen_of(pane).context("resolved pane has no screen")?;
                let current = &state.workspaces[workspace].screens[screen];
                let mut layout = current.layout_snapshot();
                layout.zoomed_pane = match enabled {
                    Some(true) => Some(pane),
                    Some(false) => None,
                    None if layout.zoomed_pane == Some(pane) => None,
                    None => Some(pane),
                };
                let topology = registry.resource_topology_snapshot()?;
                let durable = registry_screen_from_layout(
                    state,
                    workspace,
                    screen,
                    &layout,
                    &topology,
                    current.name.clone(),
                )?;
                let mut after = topology;
                *after
                    .screens
                    .iter_mut()
                    .find(|screen| screen.public_id == durable.public_id)
                    .context("zoomed screen is absent from durable topology")? = durable.clone();
                let value = pane_value_with_zoom(
                    state,
                    topology_pane(&after, &pane_id)?,
                    &after,
                    layout.zoomed_pane == Some(pane),
                )?;
                let screen_value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result = json!({"pane":pane_id,"screen":durable.public_id});
                let deltas = upserts([
                    ("pane", pane_id.as_str(), value),
                    ("screen", durable.public_id.as_str(), screen_value),
                ]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        let screen = &mut state.workspaces[workspace].screens[screen];
                        let before = screen.layout_snapshot();
                        screen.zoomed_pane = layout.zoomed_pane;
                        if before.zoomed_pane != screen.zoomed_pane {
                            screen.record_layout_change(before, Vec::new(), None);
                        }
                    },
                ))
            },
        )
    }

    fn resource_set_split_ratio(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        split_id: &str,
        ratio: f64,
        context: LayoutMutationContext<'_>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let LayoutMutationContext { coalesce, expected_revision, mutation, fingerprint } = context;
        let split_id = SplitPublicId::parse(split_id.to_string()).map_err(anyhow::Error::new)?;
        let ratio = ratio as f32;
        anyhow::ensure!(ratio.is_finite() && 0.0 < ratio && ratio < 1.0, "invalid split ratio");
        self.commit_resource_mutation_plan(
            mutation,
            "pane.split_ratio.set",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let split = state
                    .resource_indexes
                    .splits
                    .get(&split_id)
                    .copied()
                    .with_context(|| format!("unknown split {split_id}"))?;
                let (workspace, screen) =
                    state.screen_of(pane).context("resolved pane has no screen")?;
                let current = &state.workspaces[workspace].screens[screen];
                anyhow::ensure!(
                    current.root.contains_split(split),
                    "split belongs to another screen"
                );
                let mut layout = current.layout_snapshot();
                set_layout_split_ratio(&mut layout, split, ratio)?;
                let topology = registry.resource_topology_snapshot()?;
                let durable = registry_screen_from_layout(
                    state,
                    workspace,
                    screen,
                    &layout,
                    &topology,
                    current.name.clone(),
                )?;
                let mut after = topology;
                *after
                    .screens
                    .iter_mut()
                    .find(|screen| screen.public_id == durable.public_id)
                    .context("resized screen is absent from durable topology")? = durable.clone();
                let value = pane_value(state, topology_pane(&after, &pane_id)?, &after)?;
                let screen_value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result = json!({"pane":pane_id,"screen":durable.public_id});
                let deltas = upserts([
                    ("pane", pane_id.as_str(), value),
                    ("screen", durable.public_id.as_str(), screen_value),
                ]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        let target = &mut state.workspaces[workspace].screens[screen];
                        let before = target.layout_snapshot_for_coalescing_change(coalesce);
                        target.root = layout.root;
                        target.zellij_auto_layout = layout.zellij_auto_layout;
                        target.viewport_splits = layout.viewport_splits;
                        target.viewport_base_width = layout.viewport_base_width;
                        target.layout_columns = layout.layout_columns;
                        target.record_prepared_layout_change(before, Vec::new(), coalesce);
                        Self::rebuild_split_screen_index(state);
                    },
                ))
            },
        )
    }

    fn resource_set_viewport_width(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        columns: Option<u64>,
        exact_width: Option<f64>,
        context: LayoutMutationContext<'_>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let LayoutMutationContext { coalesce, expected_revision, mutation, fingerprint } = context;
        anyhow::ensure!(
            columns.is_some() ^ exact_width.is_some(),
            "exactly one of columns or width is required"
        );
        let columns =
            columns.map(u16::try_from).transpose().context("viewport columns exceed uint16")?;
        let exact_width = exact_width.map(|width| width as f32);
        if let Some(width) = exact_width {
            anyhow::ensure!(
                width.is_finite()
                    && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                "viewport width is outside the representable range"
            );
        }
        self.commit_resource_mutation_plan(
            mutation,
            "pane.viewport_width.set",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let (workspace, screen) =
                    state.screen_of(pane).context("resolved pane has no screen")?;
                let current = &state.workspaces[workspace].screens[screen];
                anyhow::ensure!(current.layout_columns_active(), "pane is not in viewport layout");
                let mut layout = current.layout_snapshot();
                let column_index = layout
                    .layout_columns
                    .iter()
                    .position(|column| column.root.contains(pane))
                    .context("pane has no viewport column")?;
                let width = if let Some(width) = exact_width {
                    width
                } else {
                    let current_width = layout.layout_columns[column_index].width;
                    let rendered_columns = state
                        .panes
                        .get(&pane)
                        .and_then(Pane::active_surface)
                        .and_then(|surface| state.surfaces.get(&surface))
                        .map(|surface| surface.size().0)
                        .context("pane has no measurable active surface")?;
                    let viewport_columns = f32::from(rendered_columns.max(1)) / current_width;
                    f32::from(columns.expect("validated columns")) / viewport_columns
                };
                anyhow::ensure!(
                    width.is_finite()
                        && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                    "viewport width is outside the representable range"
                );
                layout.layout_columns[column_index].width = width;
                sync_layout_column_widths(&mut layout);
                let topology = registry.resource_topology_snapshot()?;
                let durable = registry_screen_from_layout(
                    state,
                    workspace,
                    screen,
                    &layout,
                    &topology,
                    current.name.clone(),
                )?;
                let mut after = topology;
                *after
                    .screens
                    .iter_mut()
                    .find(|screen| screen.public_id == durable.public_id)
                    .context("viewport screen is absent from durable topology")? = durable.clone();
                let value = pane_value(state, topology_pane(&after, &pane_id)?, &after)?;
                let screen_value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result = json!({"pane":pane_id,"screen":durable.public_id});
                let deltas = upserts([
                    ("pane", pane_id.as_str(), value),
                    ("screen", durable.public_id.as_str(), screen_value),
                ]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        let target = &mut state.workspaces[workspace].screens[screen];
                        let before = target.layout_snapshot_for_coalescing_change(coalesce);
                        target.root = layout.root;
                        target.viewport_splits = layout.viewport_splits;
                        target.viewport_base_width = layout.viewport_base_width;
                        target.layout_columns = layout.layout_columns;
                        target.record_prepared_layout_change(before, Vec::new(), coalesce);
                        Self::rebuild_split_screen_index(state);
                    },
                ))
            },
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn resource_effectful_topology_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selectors: ResourceSelectors,
        fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if is_created_path_operation(operation) {
            return self.resource_correlated_creation_operation(
                operation,
                vec![selectors],
                fields,
                expected_revision,
                mutation,
                fingerprint,
            );
        }
        let _creation_handoff = is_resource_close_operation(operation)
            .then(|| self.resource_creation_handoff.lock().unwrap());
        let _creation_fence = is_resource_close_operation(operation)
            .then(|| self.resource_creation_execution.lock().unwrap());
        let operation_name = operation_name(operation);
        let preparation = {
            let mut registry = self.workspace_registry.lock().unwrap();
            if let Some(preparation) =
                registry.lookup_resource_effect(&mutation.id, &operation_name, fingerprint)?
            {
                preparation
            } else {
                let mut state = self.state.lock().unwrap();
                let intent = self.resource_topology_effect_intent(
                    operation,
                    &selectors,
                    &fields,
                    ResourceEffectIntentContext {
                        expected_revision,
                        mutation_origin: &mutation.origin,
                    },
                    &mut state,
                    &registry,
                )?;
                registry.prepare_resource_effect(
                    &mutation.id,
                    &operation_name,
                    fingerprint,
                    &intent,
                    None,
                    expected_revision,
                )?
            }
        };
        match preparation {
            ResourceEffectPreparation::Committed { outcome, revision } => match outcome {
                ResourceEffectOutcome::Success(result) => {
                    Ok(ResourcePatchCommit { revision, result, replayed: true })
                }
                ResourceEffectOutcome::Failure(error) => Err(anyhow::Error::new(error)),
            },
            ResourceEffectPreparation::Indeterminate => Err(anyhow::Error::new(
                resource_effect_indeterminate(&mutation.id, &operation_name),
            )),
            ResourceEffectPreparation::Execute { .. } => {
                let intent = self.mark_resource_effect_executing(
                    &mutation.id,
                    &operation_name,
                    fingerprint,
                )?;
                if is_resource_close_operation(operation) {
                    let committed = match self.commit_resource_close_effect(
                        operation,
                        &intent,
                        &mutation.id,
                        &operation_name,
                        fingerprint,
                    ) {
                        Ok(committed) => committed,
                        Err(error) => {
                            let error = ResourceError::operation_failed(
                                &operation_name,
                                format!("{error:#}"),
                                json!({"idempotency_key":mutation.id}),
                            );
                            if self
                                .commit_resource_effect(
                                    &mutation.id,
                                    &operation_name,
                                    fingerprint,
                                    &ResourceEffectOutcome::Failure(error.clone()),
                                    None,
                                )
                                .is_ok()
                            {
                                return Err(anyhow::Error::new(error));
                            } else {
                                let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                                return Err(anyhow::Error::new(resource_effect_indeterminate(
                                    &mutation.id,
                                    &operation_name,
                                )));
                            }
                        }
                    };
                    drop(_creation_fence);
                    drop(_creation_handoff);
                    return Ok(self.finish_resource_close(committed));
                }
                let result = match self.execute_resource_topology_effect(operation, &intent) {
                    Ok(result) => result,
                    Err(error)
                        if error
                            .downcast_ref::<ResourceError>()
                            .is_some_and(|error| error.code == "confirmation.required") =>
                    {
                        let error = error.downcast_ref::<ResourceError>().expect("checked").clone();
                        let outcome = ResourceEffectOutcome::Failure(error.clone());
                        if self
                            .commit_resource_effect(
                                &mutation.id,
                                &operation_name,
                                fingerprint,
                                &outcome,
                                None,
                            )
                            .is_ok()
                        {
                            return Err(anyhow::Error::new(error));
                        }
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        return Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )));
                    }
                    Err(error)
                        if operation == ResourceOperation::ScreenLayoutUndo
                            && error.downcast_ref::<LayoutUndoError>().is_some() =>
                    {
                        // A stale undo is rejected before it changes live or durable state.
                        // Preserve that deterministic race as a committed revision conflict
                        // instead of poisoning the idempotency key as indeterminate.
                        let Some(expected) = expected_revision else {
                            let error = ResourceError::operation_failed(
                                &operation_name,
                                format!("{error:#}"),
                                json!({"idempotency_key":mutation.id}),
                            );
                            if self
                                .commit_resource_effect(
                                    &mutation.id,
                                    &operation_name,
                                    fingerprint,
                                    &ResourceEffectOutcome::Failure(error.clone()),
                                    None,
                                )
                                .is_ok()
                            {
                                return Err(anyhow::Error::new(error));
                            }
                            let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                            return Err(anyhow::Error::new(resource_effect_indeterminate(
                                &mutation.id,
                                &operation_name,
                            )));
                        };
                        let actual = match self
                            .workspace_registry
                            .lock()
                            .unwrap()
                            .resource_topology_snapshot()
                        {
                            Ok(snapshot) => snapshot.revision,
                            Err(_) => {
                                let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                                return Err(anyhow::Error::new(resource_effect_indeterminate(
                                    &mutation.id,
                                    &operation_name,
                                )));
                            }
                        };
                        let error = ResourceError::revision_conflict(expected, actual);
                        if self
                            .commit_resource_effect(
                                &mutation.id,
                                &operation_name,
                                fingerprint,
                                &ResourceEffectOutcome::Failure(error.clone()),
                                None,
                            )
                            .is_ok()
                        {
                            return Err(anyhow::Error::new(error));
                        }
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        return Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )));
                    }
                    Err(_error) => {
                        #[cfg(test)]
                        eprintln!("resource topology effect execution failed: {_error:#}");
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        return Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )));
                    }
                };
                match self.commit_full_resource_effect_projection(
                    &mutation.id,
                    &operation_name,
                    fingerprint,
                    result,
                ) {
                    Ok(commit) => Ok(commit),
                    Err(_error) => {
                        #[cfg(test)]
                        eprintln!("resource topology effect projection commit failed: {_error:#}");
                        let _ = self.mark_resource_effect_indeterminate(&mutation.id);
                        Err(anyhow::Error::new(resource_effect_indeterminate(
                            &mutation.id,
                            &operation_name,
                        )))
                    }
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_resource_close_effect(
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
                })
            },
        )?;
        drop(_creation_fence);
        drop(_creation_handoff);
        Ok(self.finish_resource_close(committed))
    }

    pub(crate) fn commit_resource_terminal_close_effect(
        &self,
        surface: SurfaceId,
        idempotency_key: &str,
        operation_name: &str,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let committed = self.commit_resource_close_with(
            ResourceOperation::TerminalClose,
            None,
            idempotency_key,
            operation_name,
            fingerprint,
            move |state| {
                anyhow::ensure!(
                    state.terminal_runtime_by_id(surface).is_some(),
                    "terminal disappeared"
                );
                Ok(EffectSlots { workspace: None, screen: None, pane: None, tab: Some(surface) })
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
    pub(super) fn commit_legacy_terminal_close(
        &self,
        terminal_id: &str,
        expected_incarnation: Option<&str>,
        expected_generation: Option<&str>,
        expected_terminal_revision: Option<u64>,
        mutation: &WorkspaceMutation,
    ) -> anyhow::Result<Option<TerminalCloseResult>> {
        let _creation_handoff = self.resource_creation_handoff.lock().unwrap();
        let _creation_fence = self.resource_creation_execution.lock().unwrap();
        let notifications = self.surface_notifications();
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
        let mut state = self.state.lock().unwrap();
        let durable_host = registry.terminal_host_id(&public_id)?.ok_or_else(|| {
            terminal_close_state_error(format!("terminal {public_id} has no durable host"))
        })?;
        if durable_host != terminal_id {
            return Err(terminal_close_state_error("terminal resource changed hosts"));
        }
        let content_id = ContentPublicId::Terminal(public_id.clone());
        let (target, mut plan) = if let Some(runtime) =
            state.terminal_catalog.get(&public_id).cloned()
        {
            let host = self.resource_terminal_host_identity(&runtime).ok_or_else(|| {
                terminal_close_state_error("terminal runtime omitted its durable host identity")
            })?;
            if host.terminal_id != terminal_id {
                return Err(terminal_close_state_error("terminal resource changed hosts"));
            }
            if let Some(expected) = expected_incarnation {
                anyhow::ensure!(host.incarnation == expected, "terminal_incarnation_mismatch");
            }
            let target = state.placements_of_content(&content_id).first().copied();
            let plan = self.resource_close_plan_locked(
                ResourceOperation::TerminalClose,
                EffectSlots { workspace: None, screen: None, pane: None, tab: Some(runtime.id) },
                &registry,
                &state,
                &notifications,
            )?;
            (target, plan)
        } else {
            if !state.placements_of_content(&content_id).is_empty() {
                return Err(terminal_close_state_error(format!(
                    "live terminal resource {public_id} has views but no runtime owner"
                )));
            }
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
        )?;
        let (terminal, resource) = match committed {
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
            TerminalResourceCloseCommit::Committed { terminal, resource } => (terminal, resource),
        };
        #[cfg(test)]
        if let Some(hook) = self.resource_close_after_commit.lock().unwrap().clone() {
            hook();
        }
        if !terminal.replayed && !terminal.result["already_closed"].as_bool().unwrap_or(false) {
            self.emit_terminal_registry_changed(&registry, terminal.revision);
        }
        let effects = plan.install(&mut state, resource.revision, None);
        drop(state);
        drop(registry);
        drop(_creation_fence);
        drop(_creation_handoff);
        self.finish_resource_close(CommittedResourceClose { commit: resource, effects });
        Ok(Some(TerminalCloseResult {
            surface: target,
            terminal_id: terminal_id.to_string(),
            terminal_incarnation: terminal.result["incarnation"].as_str().map(str::to_string),
            already_closed: terminal.result["already_closed"].as_bool().unwrap_or(false),
            terminal_revision: terminal.revision,
        }))
    }

    pub(super) fn terminal_exit_detach_projection_locked(
        &self,
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
        let selection_resync = selection_before != active_tree_selection(&projected);
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
        }))
    }

    pub(super) fn finish_terminal_exit_detach(&self, effects: TerminalExitDetachEffects) {
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

    /// Reconcile a lifecycle row that was committed before topology detach was
    /// introduced, or whose daemon stopped between those two older commits.
    /// The durable terminal receipt remains queryable after every view leaves.
    pub(super) fn detach_exited_terminal_topology(
        &self,
        terminal_id: &str,
    ) -> anyhow::Result<bool> {
        let mut registry = self.workspace_registry.lock().unwrap();
        let terminal = registry
            .terminal_record(terminal_id)?
            .with_context(|| format!("unknown terminal {terminal_id}"))?;
        if terminal.lifecycle == TerminalLifecycle::Tombstoned {
            return Ok(false);
        }
        anyhow::ensure!(
            terminal.lifecycle == TerminalLifecycle::Exited,
            "terminal {terminal_id} is not exited"
        );
        let Some(terminal_public_id) = registry.terminal_resource_id(terminal_id)? else {
            return Ok(false);
        };
        let mut state = self.state.lock().unwrap();
        // A keep-policy terminal retains its views while the runtime screen
        // surface is alive; reconciliation must not force-detach it out from
        // under a live daemon. Without a runtime (a daemon restart dropped
        // the in-memory VT) the kept terminal degrades to the normal detach.
        if terminal.on_exit == TerminalOnExit::Keep
            && state.terminal_catalog.contains_key(&terminal_public_id)
        {
            return Ok(false);
        }
        let Some(projection) = self.terminal_exit_detach_projection_locked(
            &registry,
            &state,
            terminal_id,
            &terminal_public_id,
        )?
        else {
            return Ok(false);
        };
        let mutation = WorkspaceMutation::local("cmux-tui-runtime");
        let fingerprint = json!({
            "operation":"terminal.exit.detach",
            "terminal_id":terminal_id,
            "terminal":terminal_public_id,
            "tabs":projection.tab_ids,
        });
        let commit = registry.commit_resource_patch(
            &mutation,
            "terminal.exit.detach",
            &fingerprint,
            None,
            Some(state.resource_revision),
            &projection.patch,
            &json!({}),
            &projection.changes,
        )?;
        let effects = projection.install(&mut state, commit.revision);
        drop(state);
        drop(registry);
        self.publish_resource_event();
        self.finish_terminal_exit_detach(effects);
        Ok(true)
    }

    #[allow(clippy::too_many_arguments)]
    fn commit_resource_close_with(
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
        let notifications = self.surface_notifications();
        let mut registry = self.workspace_registry.lock().unwrap();
        let mut state = self.state.lock().unwrap();
        let slots = resolve_slots(&state)?;
        if let Some(workspace) = workspace {
            anyhow::ensure!(
                slots.workspace == Some(workspace),
                "topology close target changed workspaces before commit"
            );
        }
        let mut plan =
            self.resource_close_plan_locked(operation, slots, &registry, &state, &notifications)?;
        let projection =
            self.resource_effect_projection_locked(&registry, &mut plan.state, json!({}))?;
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
        if matches!(
            &effects.tree_publication,
            ResourceCloseTreePublication::PendingDelta(delta)
                if delta.workspace_revision.is_some()
        ) {
            let ResourceCloseTreePublication::PendingDelta(delta) = std::mem::replace(
                &mut effects.tree_publication,
                ResourceCloseTreePublication::Published,
            ) else {
                unreachable!("revisioned workspace close publication was checked above");
            };
            self.emit_committed_workspace_delta(&registry, delta, effects.selection_resync);
        }
        drop(registry);
        drop(workspace_lifecycle);
        Ok(CommittedResourceClose { commit: close.resource, effects })
    }
    fn finish_resource_close(&self, committed: CommittedResourceClose) -> ResourcePatchCommit {
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

    fn resource_close_plan_locked(
        &self,
        operation: ResourceOperation,
        slots: EffectSlots,
        _registry: &WorkspaceRegistry,
        state: &State,
        notifications: &HashMap<SurfaceId, SurfaceNotification>,
    ) -> anyhow::Result<ResourceClosePlan> {
        let selection_before = active_tree_selection(state);
        let mut projected = state.clone();
        let ResourceCloseInputs {
            surface_ids,
            mut delta,
            changed_screens,
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
                let surface = slots.tab.context("terminal disappeared")?;
                let runtime = state
                    .terminal_runtime_by_id(surface)
                    .cloned()
                    .context("terminal disappeared")?;
                let public_id = runtime
                    .terminal_public_id()
                    .cloned()
                    .context("terminal catalog entry omitted its public identity")?;
                let host = self
                    .resource_terminal_host_identity(&runtime)
                    .context("terminal omitted its durable host identity")?;
                let placements = state
                    .placements_of_content(&ContentPublicId::Terminal(public_id.clone()))
                    .to_vec();
                let screens = unique_screen_ids(
                    placements.iter().filter_map(|surface| surface_screen_id(state, *surface)),
                );
                ResourceCloseInputs {
                    surface_ids: placements,
                    changed_screens: screens,
                    terminal_runtime: Some(runtime),
                    terminal_batch: vec![(host.terminal_id, Some(host.incarnation))],
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
            anyhow::ensure!(
                removed_runtime
                    .as_ref()
                    .zip(terminal_runtime.as_ref())
                    .is_some_and(|(removed, planned)| removed.shares_terminal_runtime(planned)),
                "terminal close lost its catalog runtime"
            );
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
            workspace_was_active = projected.active_workspace == index;
            let previous_active = projected.active_pane();
            let active_id =
                projected.workspaces.get(projected.active_workspace).map(|workspace| workspace.id);
            anyhow::ensure!(
                projected.workspaces.get(index).is_some_and(|item| item.id == workspace),
                "workspace disappeared while planning close"
            );
            projected.remove_workspace(index);
            projected.active_workspace = active_id
                .and_then(|id| projected.workspace_index(id))
                .unwrap_or_else(|| projected.workspaces.len().saturating_sub(1));
            stamp_changed_active_pane(self, &mut projected, previous_active);
            let active_workspace = projected
                .workspaces
                .get(projected.active_workspace)
                .map(|workspace| workspace.public_id.clone());
            workspace_close = Some(ResourceWorkspaceClose {
                workspace_key: workspace_key.clone(),
                remaining_workspaces: self.registry_projection(&projected),
                active_workspace,
                legacy_result: json!({
                    "workspace":workspace,
                    "key":workspace_key,
                    "index":index,
                    "changed":true,
                }),
            });
            split_index_changed = true;
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
            state: projected,
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

    #[allow(clippy::too_many_arguments)]
    fn resource_correlated_creation_operation(
        self: &Arc<Self>,
        operation: ResourceOperation,
        selector_candidates: Vec<ResourceSelectors>,
        fields: Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        debug_assert!(is_created_path_operation(operation));
        let _execution = self.resource_creation_execution.lock().unwrap();
        let operation_name = operation_name(operation);
        let correlation_key =
            fields.get("correlation_key").and_then(Value::as_str).unwrap_or(&mutation.id);
        self.reconcile_interrupted_resource_creation(correlation_key)?;
        let effect_fields = semantic_creation_fields(&fields);
        let preparation = {
            let mut registry = self.workspace_registry.lock().unwrap();
            match registry.lookup_resource_creation(
                correlation_key,
                &mutation.id,
                &operation_name,
                fingerprint,
                true,
            )? {
                Some(ResourceCreationPreparation::Execute { intent, .. }) => registry
                    .prepare_resource_creation(
                        correlation_key,
                        &mutation.id,
                        &operation_name,
                        fingerprint,
                        &intent,
                        true,
                        None,
                        expected_revision,
                    )?,
                Some(preparation) => preparation,
                None => {
                    let mut state = self.state.lock().unwrap();
                    let selectors = self.select_live_creation_selectors(
                        operation,
                        &selector_candidates,
                        &state,
                        &registry,
                    )?;
                    let intent = self.resource_topology_effect_intent(
                        operation,
                        selectors,
                        &effect_fields,
                        ResourceEffectIntentContext {
                            expected_revision,
                            mutation_origin: &mutation.origin,
                        },
                        &mut state,
                        &registry,
                    )?;
                    registry.prepare_resource_creation(
                        correlation_key,
                        &mutation.id,
                        &operation_name,
                        fingerprint,
                        &intent,
                        true,
                        None,
                        expected_revision,
                    )?
                }
            }
        };
        let commit = match preparation {
            ResourceCreationPreparation::Created { created_path, revision, .. } => {
                Ok(ResourcePatchCommit { revision, result: created_path, replayed: true })
            }
            ResourceCreationPreparation::Blocked { idempotency_key, operation } => {
                Err(anyhow::Error::new(resource_effect_indeterminate(&idempotency_key, &operation)))
            }
            ResourceCreationPreparation::Failed { error, .. } => Err(anyhow::Error::new(error)),
            ResourceCreationPreparation::Execute { idempotency_key, .. } => {
                let _activity = ResourceCreationActivity::begin(&self.resource_creation_active);
                let intent = self.mark_resource_effect_executing(
                    &idempotency_key,
                    &operation_name,
                    fingerprint,
                )?;
                let recovery = self
                    .workspace_registry
                    .lock()
                    .unwrap()
                    .resource_creation_recovery(correlation_key)?
                    .context("executing resource creation omitted its recovery record")?;
                let result = match self.execute_resource_topology_effect(operation, &intent) {
                    Ok(result) => result,
                    Err(error) => {
                        #[cfg(test)]
                        eprintln!("correlated resource creation failed: {error:#}");
                        let failure = resource_creation_failure(&recovery, &error);
                        return creation_settlement_result(
                            self.settle_resource_creation(recovery, Some(failure))?,
                            &idempotency_key,
                            &operation_name,
                        );
                    }
                };
                match self.commit_full_resource_effect_projection(
                    &idempotency_key,
                    &operation_name,
                    fingerprint,
                    result,
                ) {
                    Ok(commit) => Ok(commit),
                    Err(error) => {
                        #[cfg(test)]
                        eprintln!(
                            "correlated resource creation projection commit failed: {error:#}"
                        );
                        let failure = resource_creation_failure(&recovery, &error);
                        creation_settlement_result(
                            self.settle_resource_creation(recovery, Some(failure))?,
                            &idempotency_key,
                            &operation_name,
                        )
                    }
                }
            }
        }?;
        self.activate_created_terminal_launch(&commit.result)?;
        Ok(commit)
    }

    fn activate_created_terminal_launch(&self, result: &Value) -> anyhow::Result<()> {
        if result.get("terminal_id").and_then(Value::as_str).is_none() {
            return Ok(());
        }
        let Some(tab_id) = result.get("tab_id").and_then(Value::as_str) else {
            return Ok(());
        };
        let tab_id = TabPublicId::parse(tab_id.to_string()).map_err(anyhow::Error::new)?;
        let Some(surface_id) =
            self.state.lock().unwrap().resource_indexes.tabs.get(&tab_id).copied()
        else {
            // A replay can outlive its detached terminal view. There is no
            // launch barrier to release in that case.
            return Ok(());
        };
        if let Some(surface) = self.surface(surface_id) {
            surface.activate_hosted_launch_stream()?;
        }
        Ok(())
    }

    fn select_live_creation_selectors<'a>(
        &self,
        operation: ResourceOperation,
        candidates: &'a [ResourceSelectors],
        state: &State,
        registry: &WorkspaceRegistry,
    ) -> anyhow::Result<&'a ResourceSelectors> {
        let mut last_missing = None;
        for selectors in candidates {
            let target = effect_target(operation, selectors);
            match self.resolve_resource_path_in_state(state, registry, target, selectors) {
                Ok(_) => return Ok(selectors),
                Err(error) if error.code == "selector.not_found" => last_missing = Some(error),
                Err(error) => return Err(anyhow::Error::new(error)),
            }
        }
        Err(anyhow::Error::new(
            last_missing.expect("non-empty candidates either resolve or report missing"),
        ))
    }

    fn settle_resource_creation(
        &self,
        recovery: ResourceCreationRecovery,
        failure: Option<ResourceError>,
    ) -> anyhow::Result<ResourceCreationSettlement> {
        match self.resource_creation_evidence(&recovery)? {
            ResourceCreationEvidence::Created(created_path) => {
                match self.commit_full_resource_effect_projection(
                    &recovery.idempotency_key,
                    &recovery.operation,
                    &recovery.fingerprint,
                    created_path,
                ) {
                    Ok(commit) => Ok(ResourceCreationSettlement::Created(commit)),
                    Err(_) => {
                        if let Some(settlement) = self.persisted_creation_settlement(&recovery)? {
                            return Ok(settlement);
                        }
                        if recovery.interrupted {
                            return Ok(ResourceCreationSettlement::Pending);
                        }
                        self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                        Ok(ResourceCreationSettlement::Indeterminate)
                    }
                }
            }
            ResourceCreationEvidence::NotApplied(reason) => {
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                let error = failure.unwrap_or_else(|| {
                    ResourceError::operation_failed(
                        &recovery.operation,
                        reason,
                        json!({
                            "correlation_key":recovery.correlation_key,
                            "attempt":recovery.attempt,
                        }),
                    )
                });
                match self.commit_resource_effect(
                    &recovery.idempotency_key,
                    &recovery.operation,
                    &recovery.fingerprint,
                    &ResourceEffectOutcome::Failure(error.clone()),
                    None,
                ) {
                    Ok(_) => Ok(ResourceCreationSettlement::NotApplied(error)),
                    Err(_) => {
                        if let Some(settlement) = self.persisted_creation_settlement(&recovery)? {
                            return Ok(settlement);
                        }
                        self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                        Ok(ResourceCreationSettlement::Indeterminate)
                    }
                }
            }
            ResourceCreationEvidence::Ambiguous => {
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                Ok(ResourceCreationSettlement::Indeterminate)
            }
            ResourceCreationEvidence::AmbiguousLive => {
                self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                Ok(ResourceCreationSettlement::Indeterminate)
            }
            ResourceCreationEvidence::Pending => Ok(ResourceCreationSettlement::Pending),
            ResourceCreationEvidence::TerminalClosedAfterFailure => {
                let Some(error) = failure else {
                    self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                    self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                    return Ok(ResourceCreationSettlement::Indeterminate);
                };
                self.rollback_interrupted_workspace_creation(&recovery.intent)?;
                match self.commit_resource_effect(
                    &recovery.idempotency_key,
                    &recovery.operation,
                    &recovery.fingerprint,
                    &ResourceEffectOutcome::Failure(error.clone()),
                    None,
                ) {
                    Ok(_) => Ok(ResourceCreationSettlement::NotApplied(error)),
                    Err(_) => {
                        if let Some(settlement) = self.persisted_creation_settlement(&recovery)? {
                            return Ok(settlement);
                        }
                        self.mark_resource_effect_indeterminate(&recovery.idempotency_key)?;
                        Ok(ResourceCreationSettlement::Indeterminate)
                    }
                }
            }
        }
    }

    fn rollback_interrupted_workspace_creation(&self, intent: &Value) -> anyhow::Result<()> {
        let Some(reservation) = intent.get("workspace_reservation") else {
            return Ok(());
        };
        let public_id = WorkspacePublicId::parse(
            reservation["workspace_public_id"]
                .as_str()
                .context("stored workspace reservation omitted its public id")?
                .to_string(),
        )?;
        if self
            .workspace_registry
            .lock()
            .unwrap()
            .resource_topology_snapshot()?
            .active_screens
            .iter()
            .any(|(workspace, _)| workspace == &public_id)
        {
            return Ok(());
        }
        let workspace =
            self.state.lock().unwrap().resource_indexes.workspaces.get(&public_id).copied();
        if let Some(workspace) = workspace {
            anyhow::ensure!(
                self.close_workspace_at_revision_for_resource_effect(workspace)?.is_some(),
                "interrupted staged workspace {public_id} disappeared during rollback"
            );
        }
        Ok(())
    }

    fn persisted_creation_settlement(
        &self,
        recovery: &ResourceCreationRecovery,
    ) -> anyhow::Result<Option<ResourceCreationSettlement>> {
        let preparation = self.workspace_registry.lock().unwrap().lookup_resource_creation(
            &recovery.correlation_key,
            &recovery.idempotency_key,
            &recovery.operation,
            &recovery.fingerprint,
            true,
        )?;
        Ok(match preparation {
            Some(ResourceCreationPreparation::Created { created_path, revision, .. }) => {
                Some(ResourceCreationSettlement::Created(ResourcePatchCommit {
                    revision,
                    result: created_path,
                    replayed: true,
                }))
            }
            Some(ResourceCreationPreparation::Failed { error, .. }) => {
                Some(ResourceCreationSettlement::NotApplied(error))
            }
            _ => None,
        })
    }

    fn resource_creation_evidence(
        &self,
        recovery: &ResourceCreationRecovery,
    ) -> anyhow::Result<ResourceCreationEvidence> {
        let operation: ResourceOperation =
            serde_json::from_value(Value::String(recovery.operation.clone()))
                .context("stored resource creation has an invalid operation")?;
        match created_identity_kind(operation) {
            Some(CreatedIdentityKind::Browser) => {
                self.browser_creation_evidence(&recovery.intent, recovery.interrupted)
            }
            Some(CreatedIdentityKind::Terminal) => {
                self.terminal_creation_evidence(&recovery.intent, recovery.interrupted)
            }
            None => Ok(ResourceCreationEvidence::Ambiguous),
        }
    }

    fn browser_creation_evidence(
        &self,
        intent: &Value,
        interrupted: bool,
    ) -> anyhow::Result<ResourceCreationEvidence> {
        let expected = self.effect_browser_reservation(intent)?;
        let surface = {
            let state = self.state.lock().unwrap();
            let mut matches = state
                .surfaces
                .values()
                .filter(|surface| surface.resource_identity() == Some(&expected))
                .map(|surface| surface.id);
            let first = matches.next();
            if matches.next().is_some() {
                return Ok(if interrupted {
                    ResourceCreationEvidence::Pending
                } else {
                    ResourceCreationEvidence::AmbiguousLive
                });
            }
            first
        };
        if let Some(surface) = surface {
            return Ok(match self.created_resource_path(surface) {
                Ok(path) => ResourceCreationEvidence::Created(path),
                Err(_) if interrupted => ResourceCreationEvidence::Pending,
                Err(_) => ResourceCreationEvidence::AmbiguousLive,
            });
        }
        Ok(if self.reserved_workspace_exists(intent)? {
            ResourceCreationEvidence::Ambiguous
        } else {
            ResourceCreationEvidence::NotApplied(
                "reserved browser identity is absent after creation reconciliation",
            )
        })
    }

    fn terminal_creation_evidence(
        &self,
        intent: &Value,
        interrupted: bool,
    ) -> anyhow::Result<ResourceCreationEvidence> {
        let terminal_id = intent["terminal_reservation"]["terminal_id"]
            .as_str()
            .context("stored topology intent omitted its terminal reservation")?;
        let resolution = self.resolve_terminal(terminal_id)?;
        let Some(resolution) = resolution else {
            return Ok(if self.reserved_workspace_exists(intent)? {
                ResourceCreationEvidence::Ambiguous
            } else {
                ResourceCreationEvidence::NotApplied(
                    "reserved terminal identity is absent after creation reconciliation",
                )
            });
        };
        if let Some(surface) = resolution.surface {
            return Ok(match self.created_resource_path(surface) {
                Ok(path) => ResourceCreationEvidence::Created(path),
                Err(_) if interrupted => ResourceCreationEvidence::Pending,
                Err(_) => ResourceCreationEvidence::AmbiguousLive,
            });
        }
        Ok(match resolution.terminal.lifecycle {
            TerminalLifecycle::Launching
            | TerminalLifecycle::Adopting
            | TerminalLifecycle::Running
                if interrupted =>
            {
                ResourceCreationEvidence::Pending
            }
            TerminalLifecycle::Launching
            | TerminalLifecycle::Adopting
            | TerminalLifecycle::Running => ResourceCreationEvidence::AmbiguousLive,
            TerminalLifecycle::Exited | TerminalLifecycle::Tombstoned => {
                ResourceCreationEvidence::TerminalClosedAfterFailure
            }
        })
    }

    fn reserved_workspace_exists(&self, intent: &Value) -> anyhow::Result<bool> {
        let Some(reservation) = intent.get("workspace_reservation") else {
            return Ok(false);
        };
        let key = reservation["workspace_key"]
            .as_str()
            .context("stored workspace reservation omitted its key")?;
        Ok(self.state.lock().unwrap().workspaces.iter().any(|workspace| workspace.key == key))
    }

    fn resource_topology_effect_intent(
        &self,
        operation: ResourceOperation,
        selectors: &ResourceSelectors,
        fields: &Map<String, Value>,
        context: ResourceEffectIntentContext<'_>,
        state: &mut State,
        registry: &WorkspaceRegistry,
    ) -> anyhow::Result<Value> {
        validate_effect_fields(operation, fields)?;
        if operation == ResourceOperation::WorkspaceCreate
            && let Some(name) = fields.get("name").and_then(Value::as_str)
        {
            Self::validate_workspace_name(name)?;
        }
        if operation == ResourceOperation::WorkspaceCreate
            && let Some(key) = fields.get("workspace_key").and_then(Value::as_str)
        {
            anyhow::ensure!(
                state.workspaces.iter().all(|workspace| workspace.key != key),
                "workspace key already exists: {key}"
            );
        }
        if operation == ResourceOperation::TabCreateBrowser {
            let _ = effect_browser_cell_size(self, fields)?;
        }
        let target = effect_target(operation, selectors);
        let resolved = self
            .resolve_resource_path_in_state(state, registry, target, selectors)
            .map_err(anyhow::Error::new)?;
        let mut intent = json!({
            "path":resolved.path,
            "fields":fields,
        });
        if topology_effect_creates_terminal(operation) {
            let terminal_id = TerminalId::random()?.to_hex();
            let mutation = WorkspaceMutation::local(context.mutation_origin);
            intent["terminal_reservation"] = json!({
                "terminal_id":terminal_id,
                "mutation_id":mutation.id,
                "mutation_origin":mutation.origin,
            });
        }
        if topology_effect_may_create_workspace(operation) {
            let mutation = WorkspaceMutation::local(context.mutation_origin);
            let workspace_key = fields
                .get("workspace_key")
                .and_then(Value::as_str)
                .map(str::to_string)
                .map(Ok)
                .unwrap_or_else(Self::new_workspace_key)?;
            intent["workspace_reservation"] = json!({
                "workspace_key":workspace_key,
                "workspace_public_id":WorkspacePublicId::random()?,
                "mutation_id":mutation.id,
                "mutation_origin":mutation.origin,
            });
        }
        if operation == ResourceOperation::TabCreateBrowser {
            intent["browser_reservation"] = json!({
                "tab_id":TabPublicId::random()?,
                "browser_id":BrowserPublicId::random()?,
            });
        }
        if operation == ResourceOperation::WorkspaceLayoutApply {
            validate_layout_apply_intent(state, &resolved, &fields["layout"])?;
        }
        if operation == ResourceOperation::ScreenLayoutUndo {
            let screen = resolved.screen.context("screen selector has no live screen")?;
            let (workspace_index, screen_index) =
                find_screen(state, screen).context("resolved screen disappeared")?;
            let entry = state.workspaces[workspace_index].screens[screen_index]
                .layout_undo
                .back()
                .cloned()
                .ok_or(LayoutUndoError::Unavailable)?;
            let current_revision =
                state.workspaces[workspace_index].screens[screen_index].layout_revision;
            if entry.after_revision != current_revision {
                return Err(LayoutUndoError::Stale(
                    "layout changed since the last undoable action".to_string(),
                )
                .into());
            }
            if let Some(expected) = fields.get("expected_layout_revision").and_then(Value::as_u64)
                && expected != entry.after_revision
            {
                return Err(LayoutUndoError::Stale(format!(
                    "layout revision conflict: expected {expected}, current {}",
                    entry.after_revision
                ))
                .into());
            }
            let confirm_close =
                fields.get("confirm_close").and_then(Value::as_bool).unwrap_or(false);
            if !entry.created_panes.is_empty() && !confirm_close {
                let details = layout_undo_confirmation_details(
                    state,
                    registry,
                    workspace_index,
                    screen_index,
                )?;
                return Err(anyhow::Error::new(ResourceError::new(
                    "confirmation.required",
                    "layout undo would close panes",
                    details,
                    false,
                )));
            }
            if !entry.created_panes.is_empty() {
                let details = layout_undo_confirmation_details(
                    state,
                    registry,
                    workspace_index,
                    screen_index,
                )?;
                let confirmation_matches = context.expected_revision.is_some()
                    && fields
                        .get("confirmation_token")
                        .and_then(Value::as_str)
                        .is_some_and(|token| details["confirmation_token"].as_str() == Some(token));
                if !confirmation_matches {
                    return Err(anyhow::Error::new(ResourceError::new(
                        "confirmation.required",
                        "layout undo confirmation is missing or stale",
                        details,
                        false,
                    )));
                }
            }
            intent["layout_revision"] = json!(entry.after_revision);
        }
        Ok(intent)
    }

    fn execute_resource_topology_effect(
        self: &Arc<Self>,
        operation: ResourceOperation,
        intent: &Value,
    ) -> anyhow::Result<Value> {
        let fields =
            intent["fields"].as_object().context("stored topology intent has invalid fields")?;
        let path: ResolvedResourcePath = serde_json::from_value(intent["path"].clone())
            .context("stored topology intent has an invalid path")?;
        match operation {
            ResourceOperation::WorkspaceCreate => {
                let argv = if fields.contains_key("argv") || fields.contains_key("shell") {
                    Some(effect_command(fields)?)
                } else {
                    None
                };
                self.effect_create_workspace_terminal(
                    intent,
                    optional_owned_string(fields, "name")?,
                    TerminalEffectOptions {
                        argv,
                        cwd: optional_owned_string(fields, "cwd")?,
                        name: optional_owned_string(fields, "terminal_name")?,
                        created_screen_name: None,
                        size: effect_cell_size(fields)?,
                        on_exit: None,
                    },
                )
                .map(|created| created.path)
            }
            ResourceOperation::WorkspaceClose => {
                let target =
                    self.effect_slots(&path)?.workspace.context("workspace disappeared")?;
                anyhow::ensure!(
                    self.close_workspace_at_revision_for_resource_effect(target)?.is_some(),
                    "workspace disappeared"
                );
                Ok(json!({}))
            }
            ResourceOperation::WorkspaceRun => {
                let target =
                    self.effect_slots(&path)?.workspace.context("workspace disappeared")?;
                self.effect_create_terminal_in_workspace(
                    intent,
                    target,
                    TerminalEffectOptions {
                        argv: Some(effect_command(fields)?),
                        cwd: optional_owned_string(fields, "cwd")?,
                        name: optional_owned_string(fields, "name")?,
                        created_screen_name: None,
                        size: effect_cell_size(fields)?,
                        on_exit: effect_on_exit(fields)?,
                    },
                )
                .map(|created| created.path)
            }
            ResourceOperation::WorkspaceLayoutApply => {
                self.execute_layout_apply(&path, &fields["layout"])?;
                let workspace =
                    path.workspace.as_ref().context("layout intent omitted workspace id")?;
                Ok(json!({"workspace":workspace}))
            }
            ResourceOperation::ScreenCreate => {
                let slots = self.effect_slots(&path)?;
                let name = optional_owned_string(fields, "name")?;
                match slots.workspace {
                    Some(workspace) => self.effect_add_screen(
                        intent,
                        workspace,
                        name,
                        None,
                        effect_cell_size(fields)?,
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv: None,
                            cwd: None,
                            name: None,
                            created_screen_name: name,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                }
                .map(|created| created.path)
            }
            ResourceOperation::ScreenClose => {
                let target = self.effect_slots(&path)?.screen.context("screen disappeared")?;
                anyhow::ensure!(
                    self.close_screen_for_resource_effect(target)?,
                    "screen disappeared"
                );
                Ok(json!({}))
            }
            ResourceOperation::ScreenLayoutUndo => {
                let slots = self.effect_slots(&path)?;
                let pane = slots.pane.context("undo screen has no active pane")?;
                let revision = intent["layout_revision"]
                    .as_u64()
                    .context("stored undo intent omitted its layout revision")?;
                let confirmation_token = fields.get("confirmation_token").and_then(Value::as_str);
                match self.undo_layout_with_confirmation_token_for_resource_effect(
                    pane,
                    Some(revision),
                    fields.get("confirm_close").and_then(Value::as_bool).unwrap_or(false),
                    confirmation_token,
                )? {
                    LayoutUndoResult::Undone { .. } => {
                        let screen =
                            path.screen.as_ref().context("undo intent omitted screen id")?;
                        Ok(json!({"screen":screen}))
                    }
                    LayoutUndoResult::ConfirmationRequired { .. } => {
                        anyhow::bail!("validated layout undo unexpectedly requires confirmation")
                    }
                }
            }
            ResourceOperation::PaneCreate => {
                let slots = self.effect_slots(&path)?;
                match slots.pane {
                    Some(target) => self.effect_add_pane(
                        intent,
                        target,
                        PaneAddOptions {
                            direction: None,
                            cwd: optional_owned_string(fields, "cwd")?,
                            size: effect_cell_size(fields)?,
                            ratio: None,
                            viewport_width: None,
                        },
                    ),
                    None if slots.workspace.is_some() => self.effect_create_terminal_in_workspace(
                        intent,
                        slots.workspace.expect("checked"),
                        TerminalEffectOptions {
                            argv: None,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: None,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv: None,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: None,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                }
                .map(|created| created.path)
            }
            ResourceOperation::PaneSplit => {
                let target = self.effect_slots(&path)?.pane.context("pane disappeared")?;
                self.effect_add_pane(
                    intent,
                    target,
                    PaneAddOptions {
                        direction: Some(required_str(fields, "direction")?),
                        cwd: optional_owned_string(fields, "cwd")?,
                        size: effect_cell_size(fields)?,
                        ratio: fields
                            .get("ratio")
                            .and_then(Value::as_f64)
                            .map(|value| value as f32),
                        viewport_width: fields
                            .get("viewport_width")
                            .and_then(Value::as_f64)
                            .map(|value| value as f32),
                    },
                )
                .map(|created| created.path)
            }
            ResourceOperation::PaneClose => {
                let target = self.effect_slots(&path)?.pane.context("pane disappeared")?;
                anyhow::ensure!(self.close_pane_for_resource_effect(target)?, "pane disappeared");
                Ok(json!({}))
            }
            ResourceOperation::PaneRun => {
                let target = self.effect_slots(&path)?.pane.context("pane disappeared")?;
                self.effect_add_terminal_tab(
                    intent,
                    target,
                    Some(effect_command(fields)?),
                    optional_owned_string(fields, "cwd")?,
                    optional_owned_string(fields, "name")?,
                    effect_cell_size(fields)?,
                    effect_on_exit(fields)?,
                )
                .map(|created| created.path)
            }
            ResourceOperation::TabCreateTerminal => {
                let slots = self.effect_slots(&path)?;
                match slots.pane {
                    Some(pane) => self.effect_add_terminal_tab(
                        intent,
                        pane,
                        None,
                        optional_owned_string(fields, "cwd")?,
                        optional_owned_string(fields, "name")?,
                        effect_cell_size(fields)?,
                        None,
                    ),
                    None if slots.workspace.is_some() => self.effect_create_terminal_in_workspace(
                        intent,
                        slots.workspace.expect("checked"),
                        TerminalEffectOptions {
                            argv: None,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: optional_owned_string(fields, "name")?,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv: None,
                            cwd: optional_owned_string(fields, "cwd")?,
                            name: optional_owned_string(fields, "name")?,
                            created_screen_name: None,
                            size: effect_cell_size(fields)?,
                            on_exit: None,
                        },
                    ),
                }
                .map(|created| created.path)
            }
            ResourceOperation::TabCreateBrowser => {
                let slots = self.effect_slots(&path)?;
                let size = effect_browser_cell_size(self, fields)?;
                let identity = self.effect_browser_reservation(intent)?;
                let surface = match slots.pane {
                    Some(pane) => self.new_browser_tab_reserved(
                        required_str(fields, "url")?.to_string(),
                        Some(pane),
                        size,
                        identity,
                        None,
                    )?,
                    None if slots.workspace.is_some() => self.create_browser_surface_in_workspace(
                        slots.workspace.expect("checked"),
                        required_str(fields, "url")?.to_string(),
                        size,
                        Some(identity),
                    )?,
                    None => {
                        let (workspace_key, workspace_public_id, workspace_mutation) =
                            self.effect_workspace_reservation(intent)?;
                        let placement = self.create_empty_workspace_for_resource_effect(
                            None,
                            Some(workspace_key),
                            workspace_public_id,
                            &workspace_mutation,
                        )?;
                        self.create_browser_surface_in_workspace(
                            placement.workspace,
                            required_str(fields, "url")?.to_string(),
                            size,
                            Some(identity),
                        )?
                    }
                };
                if let Some(name) = optional_owned_string(fields, "name")? {
                    surface.set_name(Some(name));
                }
                self.created_resource_path(surface.id)
            }
            ResourceOperation::TabClose => {
                let target = self.effect_slots(&path)?.tab.context("tab disappeared")?;
                anyhow::ensure!(self.close_surface_for_resource_effect(target)?, "tab disappeared");
                Ok(json!({}))
            }
            _ => anyhow::bail!("operation is not an effectful topology operation"),
        }
    }

    fn effect_slots(&self, path: &ResolvedResourcePath) -> anyhow::Result<EffectSlots> {
        self.with_state(|state| self.effect_slots_in_state(state, path))
    }

    fn effect_slots_in_state(
        &self,
        state: &State,
        path: &ResolvedResourcePath,
    ) -> anyhow::Result<EffectSlots> {
        let workspace = path
            .workspace
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .workspaces
                    .get(id)
                    .copied()
                    .with_context(|| format!("workspace {id} disappeared"))
            })
            .transpose()?
            .or_else(|| state.workspaces.get(state.active_workspace).map(|workspace| workspace.id));
        let screen = path
            .screen
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .screens
                    .get(id)
                    .copied()
                    .with_context(|| format!("screen {id} disappeared"))
            })
            .transpose()?
            .or_else(|| {
                workspace.and_then(|workspace| {
                    state.workspace_by_id(workspace)?.active_screen_ref().map(|screen| screen.id)
                })
            });
        let pane = path
            .pane
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .panes
                    .get(id)
                    .copied()
                    .with_context(|| format!("pane {id} disappeared"))
            })
            .transpose()?
            .or_else(|| {
                screen.and_then(|screen| {
                    find_screen(state, screen).map(|(workspace, screen)| {
                        state.workspaces[workspace].screens[screen].active_pane
                    })
                })
            });
        let tab = path
            .tab
            .as_ref()
            .map(|id| {
                state
                    .resource_indexes
                    .tabs
                    .get(id)
                    .copied()
                    .with_context(|| format!("tab {id} disappeared"))
            })
            .transpose()?;
        Ok(EffectSlots { workspace, screen, pane, tab })
    }

    pub(super) fn created_resource_path(&self, surface: SurfaceId) -> anyhow::Result<Value> {
        self.with_state(|state| self.created_resource_path_in_state(state, surface))
    }

    pub(super) fn created_resource_path_in_state(
        &self,
        state: &State,
        surface: SurfaceId,
    ) -> anyhow::Result<Value> {
        let pane = state.pane_of(surface).context("created surface has no pane")?;
        let (workspace_index, screen_index) =
            state.screen_of(pane).context("created pane has no screen")?;
        let workspace = &state.workspaces[workspace_index];
        let screen = &workspace.screens[screen_index];
        let pane_id = state
            .resource_indexes
            .pane_ids
            .get(&pane)
            .context("created pane has no public identity")?;
        let live = state.surfaces.get(&surface).context("created surface disappeared")?;
        let identity =
            live.resource_identity().context("created surface has no resource identity")?;
        Ok(match &identity.content_id {
            ContentPublicId::Terminal(id) => json!({
                "kind":"terminal",
                "workspace_id":workspace.public_id,
                "screen_id":screen.public_id,
                "pane_id":pane_id,
                "tab_id":identity.tab_id,
                "terminal_id":id,
            }),
            ContentPublicId::Browser(id) => json!({
                "kind":"browser",
                "workspace_id":workspace.public_id,
                "screen_id":screen.public_id,
                "pane_id":pane_id,
                "tab_id":identity.tab_id,
                "browser_id":id,
            }),
        })
    }

    fn effect_workspace_reservation(
        &self,
        intent: &Value,
    ) -> anyhow::Result<(String, WorkspacePublicId, WorkspaceMutation)> {
        let reservation = intent["workspace_reservation"]
            .as_object()
            .context("stored topology intent omitted its workspace reservation")?;
        let key = reservation["workspace_key"]
            .as_str()
            .context("stored workspace reservation omitted its key")?
            .to_string();
        let public_id = WorkspacePublicId::parse(
            reservation["workspace_public_id"]
                .as_str()
                .context("stored workspace reservation omitted its public id")?
                .to_string(),
        )?;
        let mutation = WorkspaceMutation::new(
            reservation["mutation_id"]
                .as_str()
                .context("stored workspace reservation omitted its mutation id")?,
            reservation["mutation_origin"]
                .as_str()
                .context("stored workspace reservation omitted its mutation origin")?,
        )?;
        Ok((key, public_id, mutation))
    }

    #[allow(clippy::too_many_arguments)]
    fn effect_terminal_reservation(
        &self,
        intent: &Value,
        workspace_key: &str,
        argv: Option<&[String]>,
        cwd: Option<&str>,
        name: Option<&str>,
        size: Option<(u16, u16)>,
        on_exit: Option<TerminalOnExit>,
    ) -> anyhow::Result<TerminalReservationRequest> {
        let stored = intent["terminal_reservation"]
            .as_object()
            .context("stored topology intent omitted its terminal reservation")?;
        let terminal_hex = stored["terminal_id"]
            .as_str()
            .context("stored terminal reservation omitted its terminal id")?;
        let terminal_id = TerminalId::from_hex(terminal_hex)
            .context("stored terminal reservation has an invalid terminal id")?;
        let mutation = WorkspaceMutation::new(
            stored["mutation_id"]
                .as_str()
                .context("stored terminal reservation omitted its mutation id")?,
            stored["mutation_origin"]
                .as_str()
                .context("stored terminal reservation omitted its mutation origin")?,
        )?;
        Ok(TerminalReservationRequest {
            terminal_id,
            mutation,
            fingerprint: terminal_create_fingerprint(
                workspace_key,
                Some(terminal_hex),
                argv,
                cwd,
                name,
                size,
                on_exit,
            )?,
            expected_generation: None,
            expected_revision: None,
            on_exit: on_exit.unwrap_or_default(),
        })
    }

    fn effect_browser_reservation(&self, intent: &Value) -> anyhow::Result<TabResourceIdentity> {
        let stored = intent["browser_reservation"]
            .as_object()
            .context("stored topology intent omitted its browser reservation")?;
        let tab_id = TabPublicId::parse(
            stored["tab_id"]
                .as_str()
                .context("stored browser reservation omitted its tab id")?
                .to_string(),
        )?;
        let browser_id = BrowserPublicId::parse(
            stored["browser_id"]
                .as_str()
                .context("stored browser reservation omitted its browser id")?
                .to_string(),
        )?;
        Ok(TabResourceIdentity::persisted_browser(tab_id, browser_id))
    }

    fn effect_create_workspace_terminal(
        self: &Arc<Self>,
        intent: &Value,
        workspace_name: Option<String>,
        options: TerminalEffectOptions,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let (workspace_key, workspace_public_id, workspace_mutation) =
            self.effect_workspace_reservation(intent)?;
        let placement = self.create_empty_workspace_for_resource_effect(
            workspace_name,
            Some(workspace_key),
            workspace_public_id,
            &workspace_mutation,
        )?;
        self.effect_create_terminal_in_workspace(intent, placement.workspace, options)
    }

    fn effect_create_terminal_in_workspace(
        self: &Arc<Self>,
        intent: &Value,
        workspace: WorkspaceId,
        options: TerminalEffectOptions,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let TerminalEffectOptions { argv, cwd, name, created_screen_name, size, on_exit } = options;
        let workspace_key = self
            .with_state(|state| state.workspace_by_id(workspace).map(|item| item.key.clone()))
            .with_context(|| format!("workspace {workspace} disappeared"))?;
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            on_exit,
        )?;
        let terminal_hex = reservation.terminal_id.to_hex();
        let result = self.create_terminal_in_workspace_with_mutation(
            workspace,
            argv,
            cwd,
            name,
            size,
            Some(&terminal_hex),
            None,
            None,
            &reservation.mutation,
            on_exit,
        )?;
        let surface =
            result.created_surface.context("created terminal result omitted its local surface")?;
        if let Some(name) = created_screen_name {
            self.effect_rename_created_screen(surface, name)?;
        }
        let path =
            result.created_path.context("created terminal result omitted its public path")?;
        if let Some(surface) = self.surface(surface) {
            self.reap_if_dead(&surface);
        }
        Ok(CreatedTerminalEffect { path })
    }

    #[allow(clippy::too_many_arguments)]
    fn effect_add_terminal_tab(
        self: &Arc<Self>,
        intent: &Value,
        target: PaneId,
        argv: Option<Vec<String>>,
        cwd: Option<String>,
        name: Option<String>,
        size: Option<(u16, u16)>,
        on_exit: Option<TerminalOnExit>,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let workspace_key = self
            .workspace_key_for_pane(target)
            .with_context(|| format!("pane {target} has no workspace"))?;
        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            argv.as_deref(),
            cwd.as_deref(),
            name.as_deref(),
            size,
            on_exit,
        )?;
        let surface =
            self.spawn_surface_in_workspace_reserved(&workspace_key, cwd, size, argv, reservation)?;
        if let Some(name) = name {
            surface.set_name(Some(name));
        }
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let attached = {
            let mut state = self.state.lock().unwrap();
            let delta = match state.panes.get_mut(&target) {
                Some(pane) => {
                    pane.tabs.push(surface.id);
                    pane.active_tab = pane.tabs.len() - 1;
                    pane.active_at = active_at;
                    let index = pane.tabs.len() - 1;
                    fence_layout_undo_for_tab_membership(&mut state, &[target]);
                    let (workspace_index, screen_index) =
                        state.screen_of(target).expect("live pane belongs to a screen");
                    let workspace = state.workspaces[workspace_index].id;
                    let screen = state.workspaces[workspace_index].screens[screen_index].id;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &notifications,
                        TreeDeltaKind::TabAdded,
                        surface.id,
                    )
                    .expect("new terminal tab is present in tree snapshot");
                    Some(TreeDelta {
                        kind: TreeDeltaKind::TabAdded,
                        workspace,
                        screen: Some(screen),
                        pane: Some(target),
                        surface: Some(surface.id),
                        index: Some(index),
                        entity,
                        workspace_revision: None,
                    })
                }
                None => None,
            };
            delta
                .map(|delta| {
                    self.created_resource_path_in_state(&state, surface.id)
                        .map(|path| (delta, CreatedTerminalEffect { path }))
                })
                .transpose()?
        };
        let Some((delta, created)) = attached else {
            self.fail_hosted_terminal_attachment(
                &surface,
                "resource-terminal-tab-attach-failed",
                "pane-disappeared-before-attach",
            )?;
            anyhow::bail!("pane disappeared while creating tab");
        };
        self.emit_tree_delta(delta, true);
        self.reap_if_dead(&surface);
        Ok(created)
    }

    fn effect_add_screen(
        self: &Arc<Self>,
        intent: &Value,
        workspace: WorkspaceId,
        name: Option<String>,
        cwd: Option<String>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let workspace_key = self
            .with_state(|state| state.workspace_by_id(workspace).map(|item| item.key.clone()))
            .with_context(|| format!("workspace {workspace} disappeared"))?;
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            None,
            cwd.as_deref(),
            None,
            size,
            None,
        )?;
        let surface =
            self.spawn_surface_in_workspace_reserved(&workspace_key, cwd, size, None, reservation)?;
        let (pane_id, pane) = match self.make_pane(surface.id) {
            Ok(value) => value,
            Err(error) => {
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-screen-attach-failed",
                    "pane-identity-allocation-failed",
                )?;
                return Err(error);
            }
        };
        let screen_id = self.next_id();
        let public_id = match ScreenPublicId::random() {
            Ok(value) => value,
            Err(error) => {
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-screen-attach-failed",
                    "screen-identity-allocation-failed",
                )?;
                return Err(anyhow::Error::new(error));
            }
        };
        let created = {
            let mut state = self.state.lock().unwrap();
            let Some(workspace_index) = state.workspace_index(workspace) else {
                drop(state);
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-screen-attach-failed",
                    "workspace-disappeared-before-attach",
                )?;
                anyhow::bail!("workspace disappeared while creating screen");
            };
            state.insert_pane(pane);
            stamp_pane_focus(self, &mut state, pane_id);
            let workspace = &mut state.workspaces[workspace_index];
            workspace.screens.push(Screen {
                id: screen_id,
                public_id,
                name,
                root: Node::Leaf(pane_id),
                active_pane: pane_id,
                zoomed_pane: None,
                zellij_auto_layout: Some(vec![pane_id]),
                viewport_splits: Default::default(),
                viewport_base_width: None,
                layout_columns: Vec::new(),
                layout_revision: 0,
                layout_undo: Default::default(),
            });
            workspace.active_screen = workspace.screens.len() - 1;
            let path = self.created_resource_path_in_state(&state, surface.id)?;
            CreatedTerminalEffect { path }
        };
        self.reap_if_dead(&surface);
        Ok(created)
    }

    fn effect_rename_created_screen(&self, surface: SurfaceId, name: String) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let pane = state.pane_of(surface).context("created screen surface has no pane")?;
        let (workspace, screen) = state.screen_of(pane).context("created pane has no screen")?;
        state.workspaces[workspace].screens[screen].name = Some(name);
        Ok(())
    }

    fn effect_add_pane(
        self: &Arc<Self>,
        intent: &Value,
        target: PaneId,
        options: PaneAddOptions<'_>,
    ) -> anyhow::Result<CreatedTerminalEffect> {
        let PaneAddOptions { direction, cwd, size, ratio, viewport_width } = options;
        let split_direction = direction
            .map(|direction| {
                Ok(match direction {
                    "left" => (SplitDir::Right, true),
                    "right" => (SplitDir::Right, false),
                    "up" => (SplitDir::Down, true),
                    "down" => (SplitDir::Down, false),
                    _ => anyhow::bail!("invalid pane split direction {direction:?}"),
                })
            })
            .transpose()?;
        let workspace_key = self
            .workspace_key_for_pane(target)
            .with_context(|| format!("pane {target} has no workspace"))?;
        let cwd = cwd.or_else(|| self.pane_cwd(target));
        let pane_public_id = PanePublicId::random()?;
        let reservation = self.effect_terminal_reservation(
            intent,
            &workspace_key,
            None,
            cwd.as_deref(),
            None,
            size,
            None,
        )?;
        let surface =
            self.spawn_surface_in_workspace_reserved(&workspace_key, cwd, size, None, reservation)?;
        #[cfg(test)]
        if viewport_width.is_some()
            && let Some(hook) = self.viewport_split_after_spawn.lock().unwrap().clone()
        {
            hook();
        }
        let pane_id = self.next_id();
        let split_id = split_direction.map(|_| self.next_id());
        let base_column_id = viewport_width.map(|_| self.next_id());
        let active_at = self.next_active_at();
        let notifications = self.surface_notifications();
        let attached = (|| -> anyhow::Result<(TreeDelta, ScreenId, CreatedTerminalEffect)> {
            let mut state = self.state.lock().unwrap();
            let Some((workspace, screen_index)) = state.screen_of(target) else {
                anyhow::bail!("pane disappeared before new pane attachment");
            };
            let workspace_id = state.workspaces[workspace].id;
            let screen_id = state.workspaces[workspace].screens[screen_index].id;
            let screen = &mut state.workspaces[workspace].screens[screen_index];
            let before = screen.layout_snapshot();
            if let Some(width) = viewport_width {
                anyhow::ensure!(
                    screen.insert_layout_column_after(
                        target,
                        base_column_id.expect("viewport column reserved a base id"),
                        LayoutColumn {
                            id: split_id.expect("viewport split reserved an id"),
                            width,
                            root: Node::Leaf(pane_id),
                            zellij_auto_layout: Some(vec![pane_id]),
                        },
                    ),
                    "target pane disappeared from its layout"
                );
            } else if let Some((dir, before_target)) = split_direction {
                let split = split_id.expect("split direction reserves an id");
                let in_viewport_column = screen.layout_columns_active();
                let root = if in_viewport_column {
                    let column = screen
                        .layout_column_for_pane_mut(target)
                        .context("target pane has no viewport column")?;
                    column.zellij_auto_layout = None;
                    &mut column.root
                } else {
                    &mut screen.root
                };
                anyhow::ensure!(
                    root.split_leaf(target, split, dir, pane_id),
                    "target pane disappeared from its layout"
                );
                if before_target {
                    anyhow::ensure!(
                        root.swap_leaves(target, pane_id),
                        "new split leaves could not be ordered"
                    );
                }
                if let Some(new_ratio) = ratio {
                    let split_ratio = if before_target { new_ratio } else { 1.0 - new_ratio };
                    anyhow::ensure!(
                        root.set_split_ratio(split, split_ratio),
                        "new split ratio could not be applied"
                    );
                }
                if in_viewport_column {
                    screen.sync_layout_column_projection();
                } else {
                    screen.zellij_auto_layout = None;
                }
            } else if screen.layout_columns_active() {
                let column = screen
                    .layout_column_for_pane_mut(target)
                    .context("target pane has no viewport column")?;
                append_to_auto_layout(
                    &mut column.root,
                    &mut column.zellij_auto_layout,
                    pane_id,
                    || self.next_id(),
                );
                screen.sync_layout_column_projection();
            } else {
                append_to_auto_layout(
                    &mut screen.root,
                    &mut screen.zellij_auto_layout,
                    pane_id,
                    || self.next_id(),
                );
            }
            screen.active_pane = pane_id;
            screen.zoomed_pane = None;
            screen.record_layout_change(before, vec![pane_id], None);
            state.insert_pane(Pane {
                id: pane_id,
                public_id: pane_public_id,
                name: None,
                tabs: vec![surface.id],
                active_tab: 0,
                active_at,
                focused_at: 0,
            });
            stamp_pane_focus(self, &mut state, pane_id);
            Self::rebuild_split_screen_index(&mut state);
            let entity = crate::server::tree_entity_json(
                &state,
                &notifications,
                TreeDeltaKind::PaneAdded,
                pane_id,
            )
            .expect("new pane is present in tree snapshot");
            let pane_index = state.workspaces[workspace].screens[screen_index]
                .root
                .pane_ids_vec()
                .iter()
                .position(|candidate| *candidate == pane_id)
                .expect("new pane is present in its screen layout");
            let path = self.created_resource_path_in_state(&state, surface.id)?;
            Ok((
                TreeDelta {
                    kind: TreeDeltaKind::PaneAdded,
                    workspace: workspace_id,
                    screen: Some(screen_id),
                    pane: Some(pane_id),
                    surface: None,
                    index: Some(pane_index),
                    entity,
                    workspace_revision: None,
                },
                screen_id,
                CreatedTerminalEffect { path },
            ))
        })();
        let (delta, changed_screen, created) = match attached {
            Ok(attached) => attached,
            Err(error) => {
                self.fail_hosted_terminal_attachment(
                    &surface,
                    "resource-terminal-pane-attach-failed",
                    "pane-disappeared-before-attach",
                )?;
                return Err(error);
            }
        };
        self.emit_tree_delta(delta, false);
        self.emit(MuxEvent::LayoutChanged(changed_screen));
        self.reap_if_dead(&surface);
        Ok(created)
    }

    fn execute_layout_apply(
        &self,
        path: &ResolvedResourcePath,
        document: &Value,
    ) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let slots = self.effect_slots_in_state(&state, path)?;
        apply_resource_layout_document(self, &mut state, slots, document)
    }
}

#[derive(Debug, Clone, Copy)]
struct EffectSlots {
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
    tab: Option<SurfaceId>,
}

enum ResourceCreationEvidence {
    Created(Value),
    NotApplied(&'static str),
    Ambiguous,
    AmbiguousLive,
    Pending,
    TerminalClosedAfterFailure,
}

enum ResourceCreationSettlement {
    Created(ResourcePatchCommit),
    NotApplied(ResourceError),
    Indeterminate,
    Pending,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CreatedIdentityKind {
    Terminal,
    Browser,
}

fn resource_creation_failure(
    recovery: &ResourceCreationRecovery,
    error: &anyhow::Error,
) -> ResourceError {
    error.downcast_ref::<ResourceError>().cloned().unwrap_or_else(|| {
        ResourceError::operation_failed(
            &recovery.operation,
            error.to_string(),
            json!({
                "correlation_key":recovery.correlation_key,
                "attempt":recovery.attempt,
            }),
        )
    })
}

fn creation_settlement_result(
    settlement: ResourceCreationSettlement,
    idempotency_key: &str,
    operation: &str,
) -> anyhow::Result<ResourcePatchCommit> {
    match settlement {
        ResourceCreationSettlement::Created(commit) => Ok(commit),
        ResourceCreationSettlement::NotApplied(error) => Err(anyhow::Error::new(error)),
        ResourceCreationSettlement::Indeterminate => {
            Err(anyhow::Error::new(resource_effect_indeterminate(idempotency_key, operation)))
        }
        ResourceCreationSettlement::Pending => {
            Err(anyhow::Error::new(resource_effect_indeterminate(idempotency_key, operation)))
        }
    }
}

fn resource_effect_indeterminate(idempotency_key: &str, operation: &str) -> ResourceError {
    ResourceError::new(
        "mutation.indeterminate",
        "the external effect may have run before its outcome was recorded",
        json!({
            "idempotency_key":idempotency_key,
            "operation":operation,
            "recovery":"inspect_state_then_retry_with_new_key",
        }),
        false,
    )
}

fn topology_effect_creates_terminal(operation: ResourceOperation) -> bool {
    created_identity_kind(operation) == Some(CreatedIdentityKind::Terminal)
}

fn is_resource_close_operation(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceClose
            | ResourceOperation::ScreenClose
            | ResourceOperation::PaneClose
            | ResourceOperation::TabClose
    )
}

fn topology_effect_may_create_workspace(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceCreate
            | ResourceOperation::ScreenCreate
            | ResourceOperation::PaneCreate
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TabCreateBrowser
    )
}

fn effect_target(operation: ResourceOperation, selectors: &ResourceSelectors) -> ResourceTarget {
    match operation {
        ResourceOperation::WorkspaceCreate => ResourceTarget::Session,
        ResourceOperation::WorkspaceClose
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::WorkspaceLayoutApply => ResourceTarget::Workspace,
        ResourceOperation::ScreenClose | ResourceOperation::ScreenLayoutUndo => {
            ResourceTarget::Screen
        }
        ResourceOperation::PaneSplit
        | ResourceOperation::PaneClose
        | ResourceOperation::PaneRun => ResourceTarget::Pane,
        ResourceOperation::TabClose => ResourceTarget::Tab,
        ResourceOperation::ScreenCreate => {
            if selectors.workspace.is_some() {
                ResourceTarget::Workspace
            } else {
                ResourceTarget::Session
            }
        }
        ResourceOperation::PaneCreate => {
            // The public operation creates a pane within a selected screen.
            // Ordinary mux callers additionally carry the exact existing pane
            // whose auto-layout column should receive the new pane.
            if selectors.pane.is_some() {
                ResourceTarget::Pane
            } else if selectors.screen.is_some() {
                ResourceTarget::Screen
            } else if selectors.workspace.is_some() {
                ResourceTarget::Workspace
            } else {
                ResourceTarget::Session
            }
        }
        ResourceOperation::TabCreateTerminal | ResourceOperation::TabCreateBrowser => {
            if selectors.pane.is_some() {
                ResourceTarget::Pane
            } else if selectors.screen.is_some() {
                ResourceTarget::Screen
            } else if selectors.workspace.is_some() {
                ResourceTarget::Workspace
            } else {
                ResourceTarget::Session
            }
        }
        _ => ResourceTarget::Session,
    }
}

fn validate_effect_fields(
    operation: ResourceOperation,
    fields: &Map<String, Value>,
) -> anyhow::Result<()> {
    match operation {
        ResourceOperation::WorkspaceCreate => {
            anyhow::ensure!(
                required_str(fields, "initial_content")? == "terminal",
                "effectful workspace creation requires terminal initial content"
            );
            if fields.contains_key("argv") || fields.contains_key("shell") {
                let _ = effect_command(fields)?;
            }
        }
        ResourceOperation::WorkspaceRun | ResourceOperation::PaneRun => {
            let _ = effect_command(fields)?;
            let _ = effect_cell_size(fields)?;
        }
        ResourceOperation::WorkspaceLayoutApply => {
            anyhow::ensure!(fields["layout"].is_object(), "layout must be an object");
        }
        ResourceOperation::PaneCreate | ResourceOperation::TabCreateTerminal => {
            let _ = effect_cell_size(fields)?;
        }
        ResourceOperation::PaneSplit => {
            let direction = required_str(fields, "direction")?;
            anyhow::ensure!(
                matches!(direction, "left" | "right" | "up" | "down"),
                "invalid pane split direction"
            );
            if let Some(ratio) = fields.get("ratio").and_then(Value::as_f64) {
                anyhow::ensure!(
                    ratio.is_finite() && 0.0 < ratio && ratio < 1.0,
                    "invalid pane split ratio"
                );
                let ratio = ratio as f32;
                anyhow::ensure!(
                    ratio.is_finite() && 0.0 < ratio && ratio < 1.0,
                    "pane split ratio cannot be represented"
                );
            }
            if let Some(width) = fields.get("viewport_width").and_then(Value::as_f64) {
                anyhow::ensure!(
                    direction == "right"
                        && width.is_finite()
                        && (f64::from(MIN_VIEWPORT_PANE_WIDTH)
                            ..=f64::from(MAX_VIEWPORT_PANE_WIDTH))
                            .contains(&width),
                    "invalid viewport pane width"
                );
            }
            let _ = effect_cell_size(fields)?;
        }
        ResourceOperation::TabCreateBrowser => {
            anyhow::ensure!(!required_str(fields, "url")?.is_empty(), "browser URL is empty");
            let dimensions = (
                fields.get("width_px").and_then(Value::as_u64),
                fields.get("height_px").and_then(Value::as_u64),
            );
            anyhow::ensure!(
                matches!(dimensions, (None, None) | (Some(_), Some(_))),
                "browser pixel dimensions must be paired"
            );
        }
        _ => {}
    }
    Ok(())
}

fn optional_owned_string(
    fields: &Map<String, Value>,
    name: &str,
) -> anyhow::Result<Option<String>> {
    fields
        .get(name)
        .map(|value| {
            value
                .as_str()
                .map(str::to_string)
                .with_context(|| format!("field {name:?} must be a string"))
        })
        .transpose()
}

fn effect_on_exit(fields: &Map<String, Value>) -> anyhow::Result<Option<TerminalOnExit>> {
    fields
        .get("on_exit")
        .map(|value| {
            let value = value.as_str().context("field \"on_exit\" must be a string")?;
            TerminalOnExit::parse(value)
        })
        .transpose()
}

fn effect_command(fields: &Map<String, Value>) -> anyhow::Result<Vec<String>> {
    match (fields.get("argv"), fields.get("shell")) {
        (Some(Value::Array(argv)), None) => {
            let argv = argv
                .iter()
                .map(|argument| {
                    argument.as_str().map(str::to_string).context("argv entries must be strings")
                })
                .collect::<anyhow::Result<Vec<_>>>()?;
            anyhow::ensure!(
                argv.first().is_some_and(|program| !program.is_empty()),
                "argv must contain a non-empty executable"
            );
            Ok(argv)
        }
        (None, Some(Value::String(shell))) if !shell.is_empty() => {
            Ok(vec![crate::platform::default_shell(), "-lc".to_string(), shell.clone()])
        }
        _ => anyhow::bail!("exactly one of argv or shell must be present"),
    }
}

fn effect_cell_size(fields: &Map<String, Value>) -> anyhow::Result<Option<(u16, u16)>> {
    match (fields.get("cols").and_then(Value::as_u64), fields.get("rows").and_then(Value::as_u64)) {
        (None, None) => Ok(None),
        (Some(cols), Some(rows)) => Ok(Some((
            u16::try_from(cols).context("cols exceed uint16")?,
            u16::try_from(rows).context("rows exceed uint16")?,
        ))),
        _ => anyhow::bail!("cols and rows must be paired"),
    }
}

fn effect_browser_cell_size(
    mux: &Mux,
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<(u16, u16)>> {
    let (width, height) = match (
        fields.get("width_px").and_then(Value::as_u64),
        fields.get("height_px").and_then(Value::as_u64),
    ) {
        (None, None) => return Ok(None),
        (Some(width), Some(height)) => (width, height),
        _ => anyhow::bail!("width_px and height_px must be paired"),
    };
    let (cell_width, cell_height) = mux.cell_pixel_size();
    let columns = width
        .checked_add(u64::from(cell_width).saturating_sub(1))
        .context("browser width overflows")?
        / u64::from(cell_width.max(1));
    let rows = height
        .checked_add(u64::from(cell_height).saturating_sub(1))
        .context("browser height overflows")?
        / u64::from(cell_height.max(1));
    Ok(Some((
        u16::try_from(columns).context("browser width exceeds terminal geometry")?,
        u16::try_from(rows).context("browser height exceeds terminal geometry")?,
    )))
}

#[derive(Debug)]
struct ParsedResourceLayout {
    workspace_index: usize,
    screen_index: usize,
    snapshot: ScreenLayoutSnapshot,
    tab_orders: Vec<(PaneId, Vec<SurfaceId>, usize)>,
}

fn validate_layout_apply_intent(
    state: &State,
    resolved: &ResolvedResourceSlots,
    document: &Value,
) -> anyhow::Result<()> {
    let _ = parse_resource_layout_document(state, resolved.workspace, document)?;
    Ok(())
}

fn parse_resource_layout_document(
    state: &State,
    resolved_workspace: Option<WorkspaceId>,
    document: &Value,
) -> anyhow::Result<ParsedResourceLayout> {
    let object = document.as_object().context("layout document must be an object")?;
    anyhow::ensure!(object["version"].as_u64() == Some(1), "unsupported layout version");
    let screen_id = ScreenPublicId::parse(
        object["screen_id"].as_str().context("layout omitted screen_id")?.to_string(),
    )
    .map_err(anyhow::Error::new)?;
    let screen_slot = state
        .resource_indexes
        .screens
        .get(&screen_id)
        .copied()
        .with_context(|| format!("layout references unknown screen {screen_id}"))?;
    let (workspace_index, screen_index) =
        find_screen(state, screen_slot).context("layout screen is not live")?;
    anyhow::ensure!(
        resolved_workspace == Some(state.workspaces[workspace_index].id),
        "layout screen belongs to another workspace"
    );
    let current = &state.workspaces[workspace_index].screens[screen_index];
    let active_pane = parse_layout_pane(state, screen_slot, &object["active_pane_id"])?;
    let zoomed_pane = match object.get("zoomed_pane_id") {
        Some(Value::Null) | None => None,
        Some(value) => Some(parse_layout_pane(state, screen_slot, value)?),
    };
    let mut seen_panes = HashSet::new();
    let mut seen_splits = HashSet::new();
    let mut seen_tabs = HashSet::new();
    let mut tab_orders = Vec::new();
    let root_value = object.get("root").context("layout omitted root")?;
    let (root, layout_columns, viewport_base_width) =
        if root_value["kind"].as_str() == Some("viewport") {
            let base_width =
                root_value["base_width"].as_f64().context("viewport omitted base_width")? as f32;
            anyhow::ensure!(
                base_width.is_finite()
                    && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&base_width),
                "invalid viewport base width"
            );
            let columns = root_value["columns"]
                .as_array()
                .filter(|columns| !columns.is_empty())
                .context("viewport columns must be non-empty")?;
            let mut parsed = Vec::with_capacity(columns.len());
            for column in columns {
                let id = parse_layout_split(state, screen_slot, &column["column_id"])?;
                anyhow::ensure!(seen_splits.insert(id), "layout split appears more than once");
                let width = column["width"].as_f64().context("column omitted width")? as f32;
                anyhow::ensure!(
                    width.is_finite()
                        && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                    "invalid viewport column width"
                );
                let root = parse_resource_layout_node(
                    state,
                    screen_slot,
                    &column["root"],
                    &mut seen_panes,
                    &mut seen_splits,
                    &mut seen_tabs,
                    &mut tab_orders,
                )?;
                parsed.push(LayoutColumn { id, width, root, zellij_auto_layout: None });
            }
            anyhow::ensure!(
                parsed.first().is_some_and(|column| column.width == base_width),
                "viewport base_width must equal the first column width"
            );
            let mut snapshot = current.layout_snapshot();
            snapshot.layout_columns = parsed.clone();
            sync_layout_column_projection(&mut snapshot);
            (snapshot.root, parsed, Some(base_width))
        } else {
            (
                parse_resource_layout_node(
                    state,
                    screen_slot,
                    root_value,
                    &mut seen_panes,
                    &mut seen_splits,
                    &mut seen_tabs,
                    &mut tab_orders,
                )?,
                Vec::new(),
                None,
            )
        };
    let current_panes = current.root.pane_ids_vec().into_iter().collect::<HashSet<_>>();
    anyhow::ensure!(
        seen_panes == current_panes,
        "layout pane membership must exactly match the live screen"
    );
    let current_tabs = current_panes
        .iter()
        .flat_map(|pane| {
            state.panes.get(pane).into_iter().flat_map(|pane| pane.tabs.iter().copied())
        })
        .collect::<HashSet<_>>();
    anyhow::ensure!(
        seen_tabs == current_tabs,
        "layout tab membership must exactly match the live screen"
    );
    anyhow::ensure!(seen_panes.contains(&active_pane), "active pane is absent from layout");
    anyhow::ensure!(
        zoomed_pane.is_none_or(|pane| seen_panes.contains(&pane)),
        "zoomed pane is absent from layout"
    );
    let mut snapshot = ScreenLayoutSnapshot {
        root,
        active_pane,
        zoomed_pane,
        zellij_auto_layout: None,
        viewport_splits: Default::default(),
        viewport_base_width,
        layout_columns,
    };
    if !snapshot.layout_columns.is_empty() {
        sync_layout_column_projection(&mut snapshot);
    }
    Ok(ParsedResourceLayout { workspace_index, screen_index, snapshot, tab_orders })
}

fn parse_resource_layout_node(
    state: &State,
    screen: ScreenId,
    value: &Value,
    seen_panes: &mut HashSet<PaneId>,
    seen_splits: &mut HashSet<SplitId>,
    seen_tabs: &mut HashSet<SurfaceId>,
    tab_orders: &mut Vec<(PaneId, Vec<SurfaceId>, usize)>,
) -> anyhow::Result<Node> {
    Ok(match value["kind"].as_str().context("layout node omitted kind")? {
        "leaf" => {
            let pane = parse_layout_pane(state, screen, &value["pane_id"])?;
            anyhow::ensure!(seen_panes.insert(pane), "pane appears more than once in layout");
            let tab_values = value["tab_ids"]
                .as_array()
                .filter(|tabs| !tabs.is_empty())
                .context("leaf tab_ids must be non-empty")?;
            let mut tabs = Vec::with_capacity(tab_values.len());
            for value in tab_values {
                let tab = parse_layout_tab(state, screen, value)?;
                anyhow::ensure!(seen_tabs.insert(tab), "tab appears more than once in layout");
                tabs.push(tab);
            }
            let active = match value.get("active_tab_id") {
                Some(active) => {
                    let active = parse_layout_tab(state, screen, active)?;
                    tabs.iter()
                        .position(|tab| *tab == active)
                        .context("active_tab_id is absent from leaf tab_ids")?
                }
                None => 0,
            };
            tab_orders.push((pane, tabs, active));
            Node::Leaf(pane)
        }
        "split" => {
            let split = parse_layout_split(state, screen, &value["split_id"])?;
            anyhow::ensure!(seen_splits.insert(split), "split appears more than once in layout");
            let ratio = value["ratio"].as_f64().context("split omitted ratio")? as f32;
            anyhow::ensure!(ratio.is_finite() && 0.0 < ratio && ratio < 1.0, "invalid split ratio");
            let direction = match value["direction"].as_str() {
                Some("horizontal") => SplitDir::Right,
                Some("vertical") => SplitDir::Down,
                _ => anyhow::bail!("invalid layout split direction"),
            };
            Node::Split {
                id: split,
                dir: direction,
                ratio,
                a: Box::new(parse_resource_layout_node(
                    state,
                    screen,
                    &value["first"],
                    seen_panes,
                    seen_splits,
                    seen_tabs,
                    tab_orders,
                )?),
                b: Box::new(parse_resource_layout_node(
                    state,
                    screen,
                    &value["second"],
                    seen_panes,
                    seen_splits,
                    seen_tabs,
                    tab_orders,
                )?),
            }
        }
        "stack" => {
            let panes = value["pane_ids"]
                .as_array()
                .filter(|panes| !panes.is_empty())
                .context("stack pane_ids must be non-empty")?
                .iter()
                .map(|value| parse_layout_pane(state, screen, value))
                .collect::<anyhow::Result<Vec<_>>>()?;
            for pane in &panes {
                anyhow::ensure!(seen_panes.insert(*pane), "pane appears more than once in layout");
                let record = state
                    .panes
                    .get(pane)
                    .with_context(|| format!("layout stack references missing pane {pane}"))?;
                for tab in &record.tabs {
                    anyhow::ensure!(seen_tabs.insert(*tab), "tab appears more than once in layout");
                }
                tab_orders.push((
                    *pane,
                    record.tabs.clone(),
                    record.active_tab.min(record.tabs.len().saturating_sub(1)),
                ));
            }
            let expanded = parse_layout_pane(state, screen, &value["expanded_pane_id"])?;
            Node::stack_with_expanded(panes, expanded)
                .context("expanded pane is absent from stack")?
        }
        other => anyhow::bail!("invalid layout node kind {other:?}"),
    })
}

fn parse_layout_pane(state: &State, screen: ScreenId, value: &Value) -> anyhow::Result<PaneId> {
    let id = PanePublicId::parse(value.as_str().context("pane id must be a string")?.to_string())
        .map_err(anyhow::Error::new)?;
    let pane = state
        .resource_indexes
        .panes
        .get(&id)
        .copied()
        .with_context(|| format!("layout references unknown pane {id}"))?;
    anyhow::ensure!(
        state.resource_indexes.pane_screen.get(&pane) == Some(&screen),
        "layout pane belongs to another screen"
    );
    Ok(pane)
}

fn parse_layout_tab(state: &State, screen: ScreenId, value: &Value) -> anyhow::Result<SurfaceId> {
    let id = TabPublicId::parse(value.as_str().context("tab id must be a string")?.to_string())
        .map_err(anyhow::Error::new)?;
    let tab = state
        .resource_indexes
        .tabs
        .get(&id)
        .copied()
        .with_context(|| format!("layout references unknown tab {id}"))?;
    let pane = state.pane_of(tab).context("layout tab has no live pane")?;
    anyhow::ensure!(
        state.resource_indexes.pane_screen.get(&pane) == Some(&screen),
        "layout tab belongs to another screen"
    );
    Ok(tab)
}

fn parse_layout_split(state: &State, screen: ScreenId, value: &Value) -> anyhow::Result<SplitId> {
    let id = SplitPublicId::parse(value.as_str().context("split id must be a string")?.to_string())
        .map_err(anyhow::Error::new)?;
    let split = state
        .resource_indexes
        .splits
        .get(&id)
        .copied()
        .with_context(|| format!("layout references unknown split {id}"))?;
    let (workspace_index, screen_index) =
        find_screen(state, screen).context("layout screen is not live")?;
    let live = &state.workspaces[workspace_index].screens[screen_index];
    anyhow::ensure!(
        live.root.contains_split(split)
            || live.layout_columns.iter().any(|column| column.id == split),
        "layout split belongs to another screen"
    );
    Ok(split)
}

fn apply_resource_layout_document(
    _mux: &Mux,
    state: &mut State,
    slots: EffectSlots,
    document: &Value,
) -> anyhow::Result<()> {
    let parsed = parse_resource_layout_document(state, slots.workspace, document)?;
    for (pane, tabs, active) in parsed.tab_orders {
        let record = state.panes.get_mut(&pane).context("layout pane disappeared")?;
        record.tabs = tabs;
        record.active_tab = active.min(record.tabs.len().saturating_sub(1));
        for tab in &record.tabs {
            state.resource_indexes.tab_pane.insert(*tab, pane);
        }
    }
    apply_layout_snapshot(
        &mut state.workspaces[parsed.workspace_index].screens[parsed.screen_index],
        parsed.snapshot,
    );
    Mux::rebuild_split_screen_index(state);
    Ok(())
}

fn parse_direction(value: &str) -> anyhow::Result<Direction> {
    Ok(match value {
        "left" => Direction::Left,
        "right" => Direction::Right,
        "up" => Direction::Up,
        "down" => Direction::Down,
        _ => anyhow::bail!("invalid pane direction {value:?}"),
    })
}

fn operation_name(operation: ResourceOperation) -> String {
    serde_json::to_value(operation)
        .expect("resource operations serialize")
        .as_str()
        .expect("resource operations serialize as strings")
        .to_string()
}

fn required_str<'a>(fields: &'a Map<String, Value>, name: &str) -> anyhow::Result<&'a str> {
    fields[name].as_str().with_context(|| format!("field {name:?} is missing"))
}

fn required_u64(fields: &Map<String, Value>, name: &str) -> anyhow::Result<u64> {
    fields[name].as_u64().with_context(|| format!("field {name:?} is missing"))
}

fn required_f64(fields: &Map<String, Value>, name: &str) -> anyhow::Result<f64> {
    fields[name].as_f64().with_context(|| format!("field {name:?} is missing"))
}

fn layout_resize_coalesce(
    fields: &Map<String, Value>,
) -> anyhow::Result<Option<LayoutMutationKey>> {
    let Some(kind) = fields.get("resize_owner_kind") else {
        anyhow::ensure!(
            !fields.contains_key("resize_owner") && !fields.contains_key("resize_transaction"),
            "resize transaction fields must be supplied together"
        );
        return Ok(None);
    };
    let owner = required_u64(fields, "resize_owner")?;
    let transaction = required_u64(fields, "resize_transaction")?;
    let owner = match kind.as_str().context("resize_owner_kind must be a string")? {
        "control-client" => LayoutResizeOwner::ControlClient(owner),
        "in-process" => LayoutResizeOwner::InProcess(owner),
        value => anyhow::bail!("invalid resize owner kind {value:?}"),
    };
    Ok(Some(LayoutMutationKey::Resize { owner, transaction }))
}

fn nullable_name(fields: &Map<String, Value>) -> anyhow::Result<Option<String>> {
    match fields.get("name") {
        Some(Value::Null) => Ok(None),
        Some(Value::String(name)) => Ok(Some(name.clone())),
        _ => anyhow::bail!("field \"name\" must be a string or null"),
    }
}

fn is_effectful(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::WorkspaceCreate
            | ResourceOperation::WorkspaceClose
            | ResourceOperation::WorkspaceRun
            | ResourceOperation::WorkspaceLayoutApply
            | ResourceOperation::ScreenCreate
            | ResourceOperation::ScreenClose
            | ResourceOperation::ScreenLayoutUndo
            | ResourceOperation::PaneCreate
            | ResourceOperation::PaneSplit
            | ResourceOperation::PaneClose
            | ResourceOperation::PaneRun
            | ResourceOperation::TabCreateTerminal
            | ResourceOperation::TabCreateBrowser
            | ResourceOperation::TabClose
    )
}

fn is_created_path_operation(operation: ResourceOperation) -> bool {
    created_identity_kind(operation).is_some()
}

fn created_identity_kind(operation: ResourceOperation) -> Option<CreatedIdentityKind> {
    match operation {
        ResourceOperation::WorkspaceCreate
        | ResourceOperation::WorkspaceRun
        | ResourceOperation::ScreenCreate
        | ResourceOperation::PaneCreate
        | ResourceOperation::PaneSplit
        | ResourceOperation::PaneRun
        | ResourceOperation::TabCreateTerminal => Some(CreatedIdentityKind::Terminal),
        ResourceOperation::TabCreateBrowser => Some(CreatedIdentityKind::Browser),
        _ => None,
    }
}

fn semantic_creation_fields(fields: &Map<String, Value>) -> Map<String, Value> {
    let mut fields = fields.clone();
    fields.remove("expected_revision");
    fields.remove("correlation_key");
    fields.remove("idempotency_key");
    fields
}

fn find_screen(state: &State, target: ScreenId) -> Option<(usize, usize)> {
    state.workspaces.iter().enumerate().find_map(|(workspace, item)| {
        item.screens.iter().position(|screen| screen.id == target).map(|screen| (workspace, screen))
    })
}

fn topology_screen<'a>(
    topology: &'a ResourceTopologySnapshot,
    id: &ScreenPublicId,
) -> anyhow::Result<&'a RegistryScreen> {
    topology
        .screens
        .iter()
        .find(|screen| &screen.public_id == id)
        .with_context(|| format!("screen {id} is absent from durable topology"))
}

fn topology_pane<'a>(
    topology: &'a ResourceTopologySnapshot,
    id: &PanePublicId,
) -> anyhow::Result<&'a RegistryPane> {
    topology
        .panes
        .iter()
        .find(|pane| &pane.public_id == id)
        .with_context(|| format!("pane {id} is absent from durable topology"))
}

fn topology_pane_mut<'a>(
    topology: &'a mut ResourceTopologySnapshot,
    id: &PanePublicId,
) -> anyhow::Result<&'a mut RegistryPane> {
    topology
        .panes
        .iter_mut()
        .find(|pane| &pane.public_id == id)
        .with_context(|| format!("pane {id} is absent from durable topology"))
}

fn topology_tab<'a>(
    topology: &'a ResourceTopologySnapshot,
    id: &TabPublicId,
) -> anyhow::Result<&'a RegistryTab> {
    topology
        .tabs
        .iter()
        .find(|tab| &tab.public_id == id)
        .with_context(|| format!("tab {id} is absent from durable topology"))
}

fn topology_tab_mut<'a>(
    topology: &'a mut ResourceTopologySnapshot,
    id: &TabPublicId,
) -> anyhow::Result<&'a mut RegistryTab> {
    topology
        .tabs
        .iter_mut()
        .find(|tab| &tab.public_id == id)
        .with_context(|| format!("tab {id} is absent from durable topology"))
}

fn active_screen<'a>(
    topology: &'a ResourceTopologySnapshot,
    workspace: &WorkspacePublicId,
) -> Option<&'a ScreenPublicId> {
    topology
        .active_screens
        .iter()
        .find(|(candidate, _)| candidate == workspace)
        .and_then(|(_, screen)| screen.as_ref())
}

fn set_active_screen(
    topology: &mut ResourceTopologySnapshot,
    workspace: &WorkspacePublicId,
    screen: Option<ScreenPublicId>,
) {
    if let Some((_, active)) =
        topology.active_screens.iter_mut().find(|(candidate, _)| candidate == workspace)
    {
        *active = screen;
    }
}

fn registry_workspace(state: &State, index: usize, session: &str) -> RegistryWorkspace {
    let workspace = &state.workspaces[index];
    RegistryWorkspace {
        id: workspace.id,
        public_id: workspace.public_id.clone(),
        key: workspace.key.clone(),
        name: workspace.name.clone(),
        group_key: session.to_string(),
    }
}

fn upsert(sequence: usize, resource: &str, id: &str, value: Value) -> Value {
    json!({
        "kind":"upsert",
        "sequence":u32::try_from(sequence).unwrap_or(u32::MAX),
        "resource":resource,
        "id":id,
        "value":value,
    })
}

fn upserts<'a>(values: impl IntoIterator<Item = (&'a str, &'a str, Value)>) -> Value {
    Value::Array(
        values
            .into_iter()
            .enumerate()
            .map(|(sequence, (resource, id, value))| upsert(sequence, resource, id, value))
            .collect(),
    )
}

fn workspace_value(
    state: &State,
    topology: &ResourceTopologySnapshot,
    id: &WorkspacePublicId,
) -> anyhow::Result<Value> {
    let index = state
        .workspaces
        .iter()
        .position(|workspace| &workspace.public_id == id)
        .with_context(|| format!("workspace {id} is not live"))?;
    let workspace = &state.workspaces[index];
    Ok(json!({
        "id":id,
        "session_id":topology.session_id,
        "name":workspace.name,
        "index":u32::try_from(index).context("workspace index exceeds uint32")?,
        "focused":topology.active_workspace.as_ref() == Some(id),
    }))
}

fn screen_value(
    screen: &RegistryScreen,
    topology: &ResourceTopologySnapshot,
    active_workspace: Option<&WorkspacePublicId>,
    active_screen: Option<&ScreenPublicId>,
) -> anyhow::Result<Value> {
    Ok(json!({
        "id":screen.public_id,
        "workspace_id":screen.workspace_id,
        "name":screen.name,
        "index":u32::try_from(screen.position).context("screen index exceeds uint32")?,
        "focused":active_workspace == Some(&screen.workspace_id)
            && active_screen == Some(&screen.public_id),
        "layout":layout_document(screen, topology)?,
    }))
}

fn pane_value(
    state: &State,
    pane: &RegistryPane,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let screen = topology_screen(topology, &pane.screen_id)?;
    let focused = topology.active_workspace.as_ref() == Some(&screen.workspace_id)
        && active_screen(topology, &screen.workspace_id) == Some(&screen.public_id)
        && screen.active_pane == pane.public_id;
    pane_value_with_flags(pane, focused, screen.zoomed_pane.as_ref() == Some(&pane.public_id))
        .inspect(|_value| {
            debug_assert!(state.resource_indexes.panes.contains_key(&pane.public_id));
        })
}

fn pane_value_with_zoom(
    state: &State,
    pane: &RegistryPane,
    topology: &ResourceTopologySnapshot,
    zoomed: bool,
) -> anyhow::Result<Value> {
    let mut value = pane_value(state, pane, topology)?;
    value["zoomed"] = json!(zoomed);
    Ok(value)
}

fn pane_value_with_flags(
    pane: &RegistryPane,
    focused: bool,
    zoomed: bool,
) -> anyhow::Result<Value> {
    Ok(json!({
        "id":pane.public_id,
        "screen_id":pane.screen_id,
        "name":pane.name,
        "focused":focused,
        "zoomed":zoomed,
    }))
}

fn tab_value(tab: &RegistryTab, topology: &ResourceTopologySnapshot) -> anyhow::Result<Value> {
    let pane = topology_pane(topology, &tab.pane_id)?;
    Ok(json!({
        "id":tab.public_id,
        "pane_id":tab.pane_id,
        "name":tab.name,
        "index":u32::try_from(tab.position).context("tab index exceeds uint32")?,
        "focused":pane.active_tab.as_ref() == Some(&tab.public_id),
        "content_kind":match tab.content_id {
            ContentPublicId::Terminal(_) => "terminal",
            ContentPublicId::Browser(_) => "browser",
        },
        "content_id":tab.content_id.as_str(),
    }))
}

fn layout_document(
    screen: &RegistryScreen,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    let root = if screen.viewport.columns.is_empty() {
        layout_node_value(&screen.layout, topology)?
    } else {
        json!({
            "kind":"viewport",
            "base_width":screen.viewport.base_width.context("viewport has no base width")?,
            "columns":screen.viewport.columns.iter().map(|column| {
                Ok(json!({
                    "column_id":column.id,
                    "width":column.width,
                    "root":layout_node_value(&column.layout, topology)?,
                }))
            }).collect::<anyhow::Result<Vec<_>>>()?,
        })
    };
    Ok(json!({
        "version":1,
        "screen_id":screen.public_id,
        "active_pane_id":screen.active_pane,
        "zoomed_pane_id":screen.zoomed_pane,
        "root":root,
    }))
}

fn layout_node_value(
    node: &RegistryLayoutNode,
    topology: &ResourceTopologySnapshot,
) -> anyhow::Result<Value> {
    Ok(match node {
        RegistryLayoutNode::Leaf { pane } => {
            let record = topology_pane(topology, pane)?;
            let tabs = topology.tabs.iter().filter(|tab| &tab.pane_id == pane).collect::<Vec<_>>();
            let mut value = json!({
                "kind":"leaf",
                "pane_id":pane,
                "tab_ids":tabs.iter().map(|tab| &tab.public_id).collect::<Vec<_>>(),
            });
            if let Some(active) = &record.active_tab {
                value["active_tab_id"] = json!(active);
            }
            value
        }
        RegistryLayoutNode::Split { split, direction, ratio, first, second } => json!({
            "kind":"split",
            "split_id":split,
            "direction":match direction.as_str() {
                "right" | "horizontal" => "horizontal",
                "down" | "vertical" => "vertical",
                other => anyhow::bail!("invalid durable split direction {other:?}"),
            },
            "ratio":ratio,
            "first":layout_node_value(first, topology)?,
            "second":layout_node_value(second, topology)?,
        }),
        RegistryLayoutNode::Stack { panes, expanded } => json!({
            "kind":"stack",
            "pane_ids":panes,
            "expanded_pane_id":expanded,
        }),
    })
}

fn focus_deltas(
    state: &State,
    before: &ResourceTopologySnapshot,
    after: &ResourceTopologySnapshot,
    previous_workspace: Option<WorkspacePublicId>,
    next_workspace: Option<WorkspacePublicId>,
) -> anyhow::Result<Value> {
    let mut changes = Vec::new();
    let mut workspaces =
        [previous_workspace, next_workspace].into_iter().flatten().collect::<Vec<_>>();
    workspaces.sort();
    workspaces.dedup();
    for id in &workspaces {
        changes.push(("workspace", id.to_string(), workspace_value(state, after, id)?));
    }
    let mut screens = Vec::new();
    for topology in [before, after] {
        if let Some(workspace) = topology.active_workspace.as_ref()
            && let Some(screen) = active_screen(topology, workspace)
        {
            screens.push(screen.clone());
        }
    }
    screens.sort();
    screens.dedup();
    for id in &screens {
        let screen = topology_screen(after, id).or_else(|_| topology_screen(before, id))?;
        changes.push((
            "screen",
            id.to_string(),
            screen_value(
                screen,
                after,
                after.active_workspace.as_ref(),
                active_screen(after, &screen.workspace_id),
            )?,
        ));
    }
    let mut panes = Vec::new();
    for topology in [before, after] {
        for screen in &screens {
            if let Ok(screen) = topology_screen(topology, screen) {
                panes.push(screen.active_pane.clone());
            }
        }
    }
    panes.sort();
    panes.dedup();
    for id in &panes {
        let pane = topology_pane(after, id).or_else(|_| topology_pane(before, id))?;
        changes.push(("pane", id.to_string(), pane_value(state, pane, after)?));
    }
    Ok(Value::Array(
        changes
            .into_iter()
            .enumerate()
            .map(|(sequence, (resource, id, value))| upsert(sequence, resource, &id, value))
            .collect(),
    ))
}

fn focus_pane_plan(
    mux: &Arc<Mux>,
    state: &mut State,
    registry: &WorkspaceRegistry,
    pane: PaneId,
) -> anyhow::Result<ResourceMutationPlan> {
    let (workspace_index, screen_index) =
        state.screen_of(pane).context("resolved pane has no screen")?;
    let workspace_id = state.workspaces[workspace_index].public_id.clone();
    let screen_id = state.workspaces[workspace_index].screens[screen_index].public_id.clone();
    let pane_id = state.resource_indexes.pane_ids[&pane].clone();
    let topology = registry.resource_topology_snapshot()?;
    let previous = topology.active_workspace.clone();
    let mut after = topology.clone();
    after.active_workspace = Some(workspace_id.clone());
    set_active_screen(&mut after, &workspace_id, Some(screen_id.clone()));
    let current = &state.workspaces[workspace_index].screens[screen_index];
    let mut focused_layout = current.layout_snapshot();
    let previous_pane = focused_layout.active_pane;
    if focused_layout.layout_columns.is_empty() {
        focused_layout.root.expand_stack_pane(previous_pane);
        focused_layout.root.expand_stack_pane(pane);
    } else {
        for column in &mut focused_layout.layout_columns {
            column.root.expand_stack_pane(previous_pane);
            column.root.expand_stack_pane(pane);
        }
        sync_layout_column_projection(&mut focused_layout);
    }
    focused_layout.active_pane = pane;
    let durable_screen = registry_screen_from_layout(
        state,
        workspace_index,
        screen_index,
        &focused_layout,
        &topology,
        current.name.clone(),
    )?;
    *after
        .screens
        .iter_mut()
        .find(|screen| screen.public_id == screen_id)
        .context("pane screen is absent from durable topology")? = durable_screen.clone();
    let deltas = focus_deltas(state, &topology, &after, previous, Some(workspace_id.clone()))?;
    let workspace_record =
        registry_workspace(state, workspace_index, registry.session_id().as_str());
    let result = json!({"pane":pane_id,"screen":screen_id});
    let mux = Arc::clone(mux);
    Ok(ResourceMutationPlan::new(
        ResourcePatch {
            changes: vec![
                ResourceChange::UpsertWorkspace {
                    workspace: workspace_record,
                    position: workspace_index,
                    active_screen: Some(screen_id),
                },
                ResourceChange::SetActiveWorkspace { workspace_id: Some(workspace_id) },
                ResourceChange::UpsertScreen(durable_screen),
            ],
        },
        result,
        deltas,
        move |state| apply_focus_path(&mux, state, pane),
    ))
}

fn apply_focus_path(mux: &Mux, state: &mut State, pane: PaneId) {
    let (workspace, screen) = state.screen_of(pane).expect("planned pane remains in its screen");
    state.active_workspace = workspace;
    state.workspaces[workspace].active_screen = screen;
    let current = &mut state.workspaces[workspace].screens[screen];
    let previous = current.active_pane;
    if current.layout_columns_active() {
        let mut expanded = false;
        for column in &mut current.layout_columns {
            expanded |= column.root.expand_stack_pane(previous);
            expanded |= column.root.expand_stack_pane(pane);
        }
        if expanded {
            current.sync_layout_column_projection();
        }
    } else {
        current.root.expand_stack_pane(previous);
        current.root.expand_stack_pane(pane);
    }
    current.active_pane = pane;
    stamp_pane_focus(mux, state, pane);
}

#[allow(clippy::too_many_arguments)]
pub(super) fn structural_tab_move_plan(
    mux: &Arc<Mux>,
    state: &mut State,
    registry: &WorkspaceRegistry,
    surface: SurfaceId,
    tab_id: TabPublicId,
    source_pane: PaneId,
    target_pane: PaneId,
    index: usize,
    result: Value,
) -> anyhow::Result<ResourceMutationPlan> {
    let previous_active = state.active_pane();
    let source_location = state.screen_of(source_pane).context("source pane has no screen")?;
    let target_location = state.screen_of(target_pane).context("target pane has no screen")?;
    let source_screen_slot = state.workspaces[source_location.0].screens[source_location.1].id;
    let source_screen_id =
        state.workspaces[source_location.0].screens[source_location.1].public_id.clone();
    let source_workspace_id = state.workspaces[source_location.0].public_id.clone();
    let target_screen_id =
        state.workspaces[target_location.0].screens[target_location.1].public_id.clone();
    let target_workspace_id = state.workspaces[target_location.0].public_id.clone();
    let source_pane_id = state.resource_indexes.pane_ids[&source_pane].clone();
    let target_pane_id = state.resource_indexes.pane_ids[&target_pane].clone();
    let mut source_layout =
        state.workspaces[source_location.0].screens[source_location.1].layout_snapshot();
    let source_screen_remains = remove_pane_from_layout(&mut source_layout, source_pane);
    if source_screen_remains && source_layout.active_pane == source_pane {
        source_layout.active_pane =
            if source_screen_slot == target_location_screen(state, target_location) {
                target_pane
            } else {
                source_layout.root.first_visible_pane()
            };
    }
    if source_layout.zoomed_pane == Some(source_pane) {
        source_layout.zoomed_pane = None;
    }

    let topology = registry.resource_topology_snapshot()?;
    let mut after = topology;
    after.panes.retain(|pane| pane.public_id != source_pane_id);
    let target_order = {
        let mut target_tabs = after
            .tabs
            .iter()
            .filter(|tab| tab.pane_id == target_pane_id)
            .map(|tab| tab.public_id.clone())
            .collect::<Vec<_>>();
        let moved_index = index.min(target_tabs.len());
        target_tabs.insert(moved_index, tab_id.clone());
        for tab in &mut after.tabs {
            if let Some(position) =
                target_tabs.iter().position(|candidate| candidate == &tab.public_id)
            {
                tab.pane_id = target_pane_id.clone();
                tab.position = position;
            }
        }
        target_tabs
    };
    let moved_tab = topology_tab(&after, &tab_id)?.clone();
    let target_record = {
        let pane = topology_pane_mut(&mut after, &target_pane_id)?;
        pane.active_tab = Some(tab_id.clone());
        pane.clone()
    };
    if !source_screen_remains {
        after.screens.retain(|screen| screen.public_id != source_screen_id);
    }
    after.active_workspace = Some(target_workspace_id.clone());
    set_active_screen(&mut after, &target_workspace_id, Some(target_screen_id.clone()));

    let mut changes = vec![
        ResourceChange::UpsertTab(moved_tab.clone()),
        ResourceChange::UpsertPane(target_record.clone()),
        ResourceChange::SetTabOrder { pane_id: target_pane_id.clone(), tab_ids: target_order },
        ResourceChange::TombstonePane { pane_id: source_pane_id.clone() },
    ];

    let target_durable = if source_screen_slot == target_location_screen(state, target_location) {
        source_layout.active_pane = target_pane;
        registry_screen_from_layout(
            state,
            source_location.0,
            source_location.1,
            &source_layout,
            &after,
            state.workspaces[source_location.0].screens[source_location.1].name.clone(),
        )?
    } else {
        let mut durable = topology_screen(&after, &target_screen_id)?.clone();
        durable.active_pane = target_pane_id.clone();
        durable
    };
    if let Some(screen) =
        after.screens.iter_mut().find(|screen| screen.public_id == target_screen_id)
    {
        *screen = target_durable.clone();
    }
    changes.push(ResourceChange::UpsertScreen(target_durable.clone()));

    let source_durable = if source_screen_remains && source_screen_id != target_screen_id {
        let durable = registry_screen_from_layout(
            state,
            source_location.0,
            source_location.1,
            &source_layout,
            &after,
            state.workspaces[source_location.0].screens[source_location.1].name.clone(),
        )?;
        if let Some(screen) =
            after.screens.iter_mut().find(|screen| screen.public_id == source_screen_id)
        {
            *screen = durable.clone();
        }
        changes.push(ResourceChange::UpsertScreen(durable.clone()));
        Some(durable)
    } else {
        None
    };
    if !source_screen_remains {
        changes.push(ResourceChange::TombstoneScreen { screen_id: source_screen_id.clone() });
        changes.push(ResourceChange::SetScreenOrder {
            workspace_id: source_workspace_id.clone(),
            screen_ids: state.workspaces[source_location.0]
                .screens
                .iter()
                .filter(|screen| screen.id != source_screen_slot)
                .map(|screen| screen.public_id.clone())
                .collect(),
        });
    }

    let target_workspace_index = target_location.0;
    changes.push(ResourceChange::UpsertWorkspace {
        workspace: registry_workspace(
            state,
            target_workspace_index,
            registry.session_id().as_str(),
        ),
        position: target_workspace_index,
        active_screen: Some(target_screen_id.clone()),
    });
    if source_workspace_id != target_workspace_id {
        let active_screen = if source_screen_remains {
            state.workspaces[source_location.0]
                .screens
                .get(state.workspaces[source_location.0].active_screen)
                .map(|screen| screen.public_id.clone())
        } else {
            state.workspaces[source_location.0]
                .screens
                .iter()
                .filter(|screen| screen.id != source_screen_slot)
                .nth(
                    state.workspaces[source_location.0]
                        .active_screen
                        .min(state.workspaces[source_location.0].screens.len().saturating_sub(2)),
                )
                .map(|screen| screen.public_id.clone())
        };
        changes.push(ResourceChange::UpsertWorkspace {
            workspace: registry_workspace(state, source_location.0, registry.session_id().as_str()),
            position: source_location.0,
            active_screen,
        });
        if let ContentPublicId::Terminal(terminal_id) = &moved_tab.content_id {
            let host_id =
                moved_tab.terminal_id.as_deref().context("terminal tab omitted its host id")?;
            let mut terminal = registry
                .terminal_snapshot()?
                .terminals
                .into_iter()
                .find(|terminal| terminal.terminal_id == host_id)
                .context("terminal has no durable host placement")?;
            terminal.workspace_key = state.workspaces[target_location.0].key.clone();
            changes
                .push(ResourceChange::UpsertTerminal { public_id: terminal_id.clone(), terminal });
        }
    }
    changes.push(ResourceChange::SetActiveWorkspace {
        workspace_id: Some(target_workspace_id.clone()),
    });

    let mut delta_values = vec![
        ("tab", tab_id.to_string(), tab_value(&moved_tab, &after)?),
        ("pane", target_pane_id.to_string(), pane_value(state, &target_record, &after)?),
        (
            "screen",
            target_screen_id.to_string(),
            screen_value(
                &target_durable,
                &after,
                after.active_workspace.as_ref(),
                active_screen(&after, &target_workspace_id),
            )?,
        ),
        (
            "workspace",
            target_workspace_id.to_string(),
            workspace_value(state, &after, &target_workspace_id)?,
        ),
    ];
    if let Some(source) = &source_durable {
        delta_values.push((
            "screen",
            source_screen_id.to_string(),
            screen_value(
                source,
                &after,
                after.active_workspace.as_ref(),
                active_screen(&after, &source_workspace_id),
            )?,
        ));
    }
    if source_workspace_id != target_workspace_id {
        delta_values.push((
            "workspace",
            source_workspace_id.to_string(),
            workspace_value(state, &after, &source_workspace_id)?,
        ));
    }
    let mut deltas = delta_values
        .into_iter()
        .enumerate()
        .map(|(sequence, (resource, id, value))| upsert(sequence, resource, &id, value))
        .collect::<Vec<_>>();
    deltas.push(delete_delta(deltas.len(), "pane", source_pane_id.as_str()));
    if !source_screen_remains {
        deltas.push(delete_delta(deltas.len(), "screen", source_screen_id.as_str()));
    }

    let source_screen_public = source_screen_id.clone();
    let target_screen_public = target_screen_id;
    let mux = Arc::clone(mux);
    Ok(ResourceMutationPlan::new(
        ResourcePatch { changes },
        result,
        Value::Array(deltas),
        move |state| {
            let moved = move_tab_in_state(&mux, state, surface, target_pane, index);
            debug_assert!(moved.0 && moved.1);
            if source_screen_remains
                && let Some((workspace, screen)) =
                    state.workspaces.iter().enumerate().find_map(|(workspace, item)| {
                        item.screens
                            .iter()
                            .position(|screen| screen.public_id == source_screen_public)
                            .map(|screen| (workspace, screen))
                    })
            {
                overwrite_layout_snapshot(
                    &mut state.workspaces[workspace].screens[screen],
                    source_layout,
                );
            }
            let (target_workspace, target_screen) = state
                .workspaces
                .iter()
                .enumerate()
                .find_map(|(workspace, item)| {
                    item.screens
                        .iter()
                        .position(|screen| screen.public_id == target_screen_public)
                        .map(|screen| (workspace, screen))
                })
                .expect("planned target screen remains live");
            state.active_workspace = target_workspace;
            state.workspaces[target_workspace].active_screen = target_screen;
            state.workspaces[target_workspace].screens[target_screen].active_pane = target_pane;
            if previous_active != Some(target_pane) {
                stamp_pane_focus(&mux, state, target_pane);
            } else if let Some(pane) = state.panes.get_mut(&target_pane) {
                pane.active_at = mux.next_active_at();
            }
            Mux::rebuild_split_screen_index(state);
        },
    ))
}

fn target_location_screen(state: &State, location: (usize, usize)) -> ScreenId {
    state.workspaces[location.0].screens[location.1].id
}

fn remove_pane_from_layout(layout: &mut ScreenLayoutSnapshot, pane: PaneId) -> bool {
    layout.zellij_auto_layout = None;
    if layout.layout_columns.is_empty() {
        let root = std::mem::replace(&mut layout.root, Node::Leaf(0));
        let Some(root) = root.remove_leaf(pane) else {
            return false;
        };
        layout.root = root;
        return true;
    }
    let Some(index) = layout.layout_columns.iter().position(|column| column.root.contains(pane))
    else {
        return true;
    };
    let column = &mut layout.layout_columns[index];
    column.zellij_auto_layout = None;
    let root = std::mem::replace(&mut column.root, Node::Leaf(0));
    if let Some(root) = root.remove_leaf(pane) {
        column.root = root;
    } else {
        layout.layout_columns.remove(index);
    }
    match layout.layout_columns.len() {
        0 => false,
        1 => {
            let column = layout.layout_columns.remove(0);
            layout.root = column.root;
            layout.zellij_auto_layout = column.zellij_auto_layout;
            layout.viewport_splits.clear();
            layout.viewport_base_width = None;
            true
        }
        _ => {
            sync_layout_column_projection(layout);
            true
        }
    }
}

fn delete_delta(sequence: usize, resource: &str, id: &str) -> Value {
    json!({
        "kind":"delete",
        "sequence":u32::try_from(sequence).unwrap_or(u32::MAX),
        "resource":resource,
        "id":id,
    })
}

fn registry_screen_from_layout(
    state: &State,
    workspace_index: usize,
    screen_index: usize,
    layout: &ScreenLayoutSnapshot,
    topology: &ResourceTopologySnapshot,
    name: Option<String>,
) -> anyhow::Result<RegistryScreen> {
    let workspace = &state.workspaces[workspace_index];
    let screen = &workspace.screens[screen_index];
    let public_pane = |pane: PaneId| {
        state
            .resource_indexes
            .pane_ids
            .get(&pane)
            .cloned()
            .with_context(|| format!("pane {pane} has no public identity"))
    };
    let layout_node = registry_layout_node(state, &layout.root)?;
    let auto_layout = layout
        .zellij_auto_layout
        .as_ref()
        .map(|panes| {
            panes.iter().map(|pane| public_pane(*pane)).collect::<anyhow::Result<Vec<_>>>()
        })
        .transpose()?;
    let columns = layout
        .layout_columns
        .iter()
        .map(|column| {
            Ok(RegistryViewportColumn {
                id: state
                    .resource_indexes
                    .split_ids
                    .get(&column.id)
                    .cloned()
                    .with_context(|| format!("column {} has no public identity", column.id))?,
                width: column.width,
                layout: registry_layout_node(state, &column.root)?,
                auto_layout: column
                    .zellij_auto_layout
                    .as_ref()
                    .map(|panes| {
                        panes
                            .iter()
                            .map(|pane| public_pane(*pane))
                            .collect::<anyhow::Result<Vec<_>>>()
                    })
                    .transpose()?,
            })
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    let durable = RegistryScreen {
        public_id: screen.public_id.clone(),
        workspace_id: workspace.public_id.clone(),
        position: screen_index,
        name,
        layout: layout_node,
        active_pane: public_pane(layout.active_pane)?,
        zoomed_pane: layout.zoomed_pane.map(public_pane).transpose()?,
        auto_layout,
        viewport: RegistryViewport { base_width: layout.viewport_base_width, columns },
    };
    let expected_panes = topology
        .panes
        .iter()
        .filter(|pane| pane.screen_id == durable.public_id)
        .map(|pane| pane.public_id.clone())
        .collect::<HashSet<_>>();
    crate::workspace_registry::validate_registry_screen_projection(&durable, &expected_panes)?;
    Ok(durable)
}

fn registry_layout_node(state: &State, node: &Node) -> anyhow::Result<RegistryLayoutNode> {
    Ok(match node {
        Node::Leaf(pane) => RegistryLayoutNode::Leaf {
            pane: state
                .resource_indexes
                .pane_ids
                .get(pane)
                .cloned()
                .with_context(|| format!("pane {pane} has no public identity"))?,
        },
        Node::Split { id, dir, ratio, a, b } => RegistryLayoutNode::Split {
            split: state
                .resource_indexes
                .split_ids
                .get(id)
                .cloned()
                .with_context(|| format!("split {id} has no public identity"))?,
            direction: match dir {
                SplitDir::Right => "right",
                SplitDir::Down => "down",
            }
            .to_string(),
            ratio: *ratio,
            first: Box::new(registry_layout_node(state, a)?),
            second: Box::new(registry_layout_node(state, b)?),
        },
        Node::Stack { panes, expanded } => RegistryLayoutNode::Stack {
            panes: panes
                .iter()
                .map(|pane| {
                    state
                        .resource_indexes
                        .pane_ids
                        .get(pane)
                        .cloned()
                        .with_context(|| format!("pane {pane} has no public identity"))
                })
                .collect::<anyhow::Result<Vec<_>>>()?,
            expanded: state
                .resource_indexes
                .pane_ids
                .get(expanded)
                .cloned()
                .with_context(|| format!("pane {expanded} has no public identity"))?,
        },
    })
}

fn set_layout_split_ratio(
    layout: &mut ScreenLayoutSnapshot,
    split: SplitId,
    ratio: f32,
) -> anyhow::Result<()> {
    if let Some(index) = layout
        .layout_columns
        .iter()
        .position(|column| column.id == split)
        .filter(|index| *index > 0)
    {
        let width_before =
            layout.layout_columns[..index].iter().map(|column| column.width).sum::<f32>();
        let width = width_before * (1.0 - ratio) / ratio;
        anyhow::ensure!(
            width.is_finite()
                && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
            "split ratio implies an invalid viewport width"
        );
        layout.layout_columns[index].width = width;
        sync_layout_column_widths(layout);
        return Ok(());
    }
    let changed = if layout.layout_columns.is_empty() {
        layout.root.set_split_ratio(split, ratio)
    } else {
        let changed = layout
            .layout_columns
            .iter_mut()
            .any(|column| column.root.set_split_ratio(split, ratio));
        if changed {
            layout.root.set_split_ratio(split, ratio);
        }
        changed
    };
    anyhow::ensure!(changed, "unknown split");
    layout.zellij_auto_layout = None;
    Ok(())
}

fn swap_layout_panes(
    layout: &mut ScreenLayoutSnapshot,
    first: PaneId,
    second: PaneId,
    both_present: bool,
) -> anyhow::Result<()> {
    if both_present {
        anyhow::ensure!(
            layout.root.contains(first) && layout.root.contains(second),
            "pane swap targets changed"
        );
    } else {
        anyhow::ensure!(
            layout.root.contains(first) || layout.root.contains(second),
            "pane swap target changed"
        );
    }
    layout.root.swap_leaf_ids(first, second);
    for column in &mut layout.layout_columns {
        if column.root.contains(first) || column.root.contains(second) {
            column.root.swap_leaf_ids(first, second);
            column.zellij_auto_layout = None;
        }
    }
    if !layout.layout_columns.is_empty() {
        sync_layout_column_projection(layout);
    }
    layout.zellij_auto_layout = None;
    if !both_present {
        if layout.active_pane == first {
            layout.active_pane = second;
        } else if layout.active_pane == second {
            layout.active_pane = first;
        }
        if layout.zoomed_pane == Some(first) {
            layout.zoomed_pane = Some(second);
        } else if layout.zoomed_pane == Some(second) {
            layout.zoomed_pane = Some(first);
        }
    }
    Ok(())
}

fn apply_layout_snapshot(screen: &mut Screen, layout: ScreenLayoutSnapshot) {
    let before = screen.layout_snapshot();
    overwrite_layout_snapshot(screen, layout);
    screen.record_layout_change(before, Vec::new(), None);
}

fn overwrite_layout_snapshot(screen: &mut Screen, layout: ScreenLayoutSnapshot) {
    screen.root = layout.root;
    screen.active_pane = layout.active_pane;
    screen.zoomed_pane = layout.zoomed_pane;
    screen.zellij_auto_layout = layout.zellij_auto_layout;
    screen.viewport_splits = layout.viewport_splits;
    screen.viewport_base_width = layout.viewport_base_width;
    screen.layout_columns = layout.layout_columns;
}

fn sync_layout_column_projection(layout: &mut ScreenLayoutSnapshot) {
    let Some(first) = layout.layout_columns.first() else {
        layout.viewport_splits.clear();
        layout.viewport_base_width = None;
        return;
    };
    layout.viewport_splits.clear();
    layout.viewport_base_width = Some(first.width);
    layout.zellij_auto_layout = None;
    let mut root = first.root.clone();
    let mut width_before = first.width;
    for column in layout.layout_columns.iter().skip(1) {
        let ratio = width_before / (width_before + column.width);
        root = Node::Split {
            id: column.id,
            dir: SplitDir::Right,
            ratio,
            a: Box::new(root),
            b: Box::new(column.root.clone()),
        };
        layout.viewport_splits.insert(column.id, column.width);
        width_before += column.width;
    }
    layout.root = root;
}

fn sync_layout_column_widths(layout: &mut ScreenLayoutSnapshot) {
    let Some(first) = layout.layout_columns.first() else {
        layout.viewport_splits.clear();
        layout.viewport_base_width = None;
        return;
    };
    layout.viewport_splits.clear();
    layout.viewport_base_width = Some(first.width);
    let mut ratios = std::collections::BTreeMap::new();
    let mut before = first.width;
    for column in layout.layout_columns.iter().skip(1) {
        ratios.insert(column.id, before / (before + column.width));
        layout.viewport_splits.insert(column.id, column.width);
        before += column.width;
    }
    set_node_split_ratios(&mut layout.root, &ratios);
}

fn set_node_split_ratios(node: &mut Node, ratios: &std::collections::BTreeMap<SplitId, f32>) {
    match node {
        Node::Leaf(_) | Node::Stack { .. } => {}
        Node::Split { id, ratio, a, b, .. } => {
            if let Some(next) = ratios.get(id) {
                *ratio = *next;
            }
            set_node_split_ratios(a, ratios);
            set_node_split_ratios(b, ratios);
        }
    }
}

#[cfg(test)]
mod creation_recovery_tests {
    use super::*;

    #[test]
    fn resumed_correlated_creation_rechecks_its_resource_revision() {
        let registry = WorkspaceRegistry::in_memory("creation-resume-precondition").unwrap();
        let mux = Mux::from_workspace_registry(
            "creation-resume-precondition".into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap();
        let operation = ResourceOperation::TabCreateBrowser;
        let operation_name = operation_name(operation);
        let correlation_key = "correlation";
        let mutation = WorkspaceMutation::new("attempt-one", "test").unwrap();
        let fingerprint = json!({"operation":operation_name});
        let intent = json!({
            "browser_reservation":{
                "tab_id":TabPublicId::random().unwrap(),
                "browser_id":BrowserPublicId::random().unwrap(),
            },
        });
        mux.workspace_registry
            .lock()
            .unwrap()
            .prepare_resource_creation(
                correlation_key,
                &mutation.id,
                &operation_name,
                &fingerprint,
                &intent,
                true,
                None,
                Some(0),
            )
            .unwrap();
        mux.resource_create_empty_workspace(
            None,
            None,
            None,
            &WorkspaceMutation::local("concurrent-test"),
        )
        .unwrap();

        let error = mux
            .resource_correlated_creation_operation(
                operation,
                vec![ResourceSelectors::default()],
                json!({
                    "correlation_key":correlation_key,
                    "url":"https://example.test",
                })
                .as_object()
                .unwrap()
                .clone(),
                Some(0),
                &mutation,
                &fingerprint,
            )
            .unwrap_err();
        assert_eq!(error.to_string(), "resource revision conflict: expected 0, current 1");
        mux.shutdown();
    }

    #[test]
    fn restart_reconciles_absent_effects_for_every_created_path_operation() {
        let operations = [
            ResourceOperation::WorkspaceCreate,
            ResourceOperation::WorkspaceRun,
            ResourceOperation::ScreenCreate,
            ResourceOperation::PaneCreate,
            ResourceOperation::PaneSplit,
            ResourceOperation::PaneRun,
            ResourceOperation::TabCreateTerminal,
            ResourceOperation::TabCreateBrowser,
        ];
        for (index, operation) in operations.into_iter().enumerate() {
            let root = std::env::temp_dir().join(format!(
                "cmux-created-path-recovery-{index}-{}",
                crate::workspace_registry::new_uuid_v4()
            ));
            let session = format!("creation-recovery-{index}");
            let operation_name = operation_name(operation);
            let correlation_key = format!("correlation-{index}");
            let idempotency_key = format!("attempt-{index}");
            let fingerprint = json!({"operation":operation_name});
            let intent = match created_identity_kind(operation).unwrap() {
                CreatedIdentityKind::Terminal => json!({
                    "terminal_reservation":{
                        "terminal_id":TerminalId::random().unwrap().to_hex(),
                    },
                }),
                CreatedIdentityKind::Browser => json!({
                    "browser_reservation":{
                        "tab_id":TabPublicId::random().unwrap(),
                        "browser_id":BrowserPublicId::random().unwrap(),
                    },
                }),
            };
            {
                let mut registry = WorkspaceRegistry::open(&root, &session).unwrap();
                registry
                    .prepare_resource_creation(
                        &correlation_key,
                        &idempotency_key,
                        &operation_name,
                        &fingerprint,
                        &intent,
                        true,
                        None,
                        None,
                    )
                    .unwrap();
                registry
                    .mark_resource_effect_executing(&idempotency_key, &operation_name, &fingerprint)
                    .unwrap();
            }
            let registry = WorkspaceRegistry::open(&root, &session).unwrap();
            let mux = Mux::from_workspace_registry(
                session,
                SurfaceOptions::default(),
                registry,
                ProviderWorkspaceState::default(),
                true,
            )
            .unwrap();
            assert_eq!(
                mux.resource_creation_resolution(&correlation_key).unwrap(),
                json!({
                    "correlation_key":correlation_key,
                    "operation":operation_name,
                    "idempotency_key":idempotency_key,
                    "state":"not_applied",
                    "recovery":"retry_new_idempotency_key",
                })
            );
            mux.shutdown();
            drop(mux);
            std::fs::remove_dir_all(root).unwrap();
        }
    }

    #[test]
    fn restart_rejects_multiple_interrupted_creation_receipts() {
        let root = std::env::temp_dir().join(format!(
            "cmux-created-path-multiple-{}",
            crate::workspace_registry::new_uuid_v4()
        ));
        let session = "creation-recovery-multiple";
        {
            let mut registry = WorkspaceRegistry::open(&root, session).unwrap();
            for index in 0..2 {
                let correlation_key = format!("correlation-{index}");
                let idempotency_key = format!("attempt-{index}");
                let fingerprint = json!({"operation":"tab.create_browser","index":index});
                let intent = json!({
                    "browser_reservation":{
                        "tab_id":TabPublicId::random().unwrap(),
                        "browser_id":BrowserPublicId::random().unwrap(),
                    },
                });
                registry
                    .prepare_resource_creation(
                        &correlation_key,
                        &idempotency_key,
                        "tab.create_browser",
                        &fingerprint,
                        &intent,
                        true,
                        None,
                        None,
                    )
                    .unwrap();
                registry
                    .mark_resource_effect_executing(
                        &idempotency_key,
                        "tab.create_browser",
                        &fingerprint,
                    )
                    .unwrap();
            }
        }
        let registry = WorkspaceRegistry::open(&root, session).unwrap();
        let error = match Mux::from_workspace_registry(
            session.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        ) {
            Ok(mux) => {
                mux.shutdown();
                panic!("multiple interrupted creations unexpectedly started")
            }
            Err(error) => error,
        };
        assert!(
            error
                .to_string()
                .contains("multiple interrupted resource creations cannot be recovered atomically")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn all_created_path_operations_have_restart_evidence_identity() {
        let operations = [
            (ResourceOperation::WorkspaceCreate, CreatedIdentityKind::Terminal),
            (ResourceOperation::WorkspaceRun, CreatedIdentityKind::Terminal),
            (ResourceOperation::ScreenCreate, CreatedIdentityKind::Terminal),
            (ResourceOperation::PaneCreate, CreatedIdentityKind::Terminal),
            (ResourceOperation::PaneSplit, CreatedIdentityKind::Terminal),
            (ResourceOperation::PaneRun, CreatedIdentityKind::Terminal),
            (ResourceOperation::TabCreateTerminal, CreatedIdentityKind::Terminal),
            (ResourceOperation::TabCreateBrowser, CreatedIdentityKind::Browser),
        ];
        for (operation, expected) in operations {
            assert!(is_created_path_operation(operation));
            assert_eq!(created_identity_kind(operation), Some(expected));
        }
        assert_eq!(created_identity_kind(ResourceOperation::WorkspaceClose), None);
        assert_eq!(created_identity_kind(ResourceOperation::TabClose), None);
    }

    #[test]
    fn creation_fingerprint_excludes_delivery_metadata_only() {
        let fields = json!({
            "correlation_key":"correlation-one",
            "idempotency_key":"attempt-one",
            "expected_revision":"42",
            "url":"https://example.test",
            "name":"Example",
        })
        .as_object()
        .unwrap()
        .clone();
        assert_eq!(
            semantic_creation_fields(&fields),
            json!({
                "url":"https://example.test",
                "name":"Example",
            })
            .as_object()
            .unwrap()
            .clone()
        );
    }
}
