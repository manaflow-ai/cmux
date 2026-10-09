use crate::Actor;
use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use anyhow::Context;
use serde_json::{Map, Value, json};

use super::*;
use crate::model::{ColumnDock, LayoutColumn, ScreenLayoutSnapshot};
use crate::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, ResourceError, ResourceOperation,
    ScreenPublicId, SplitPublicId, TabPublicId, TabResourceIdentity, WorkspacePublicId,
};
use crate::resource_mutation::ResourceMutationPlan;
use crate::server::MAX_CREATION_SELECTOR_FALLBACKS;
use crate::terminal_end::DetachProof;
use crate::workspace_registry::{
    RegistryPane, RegistryScreen, RegistryTab, RegistryViewportColumn, ResourceCreationPreparation,
    ResourceCreationRecovery, ResourcePatchCommit, ResourceWorkspaceClose, ResourceWorkspaceLedger,
    TerminalLifecycle, TerminalOnExit, TerminalResourceCloseCommit, WorkspacePresentationUpdate,
};
use crate::{ResolvedResourcePath, ResourceSelectors, ResourceTarget, SurfaceKind};
use cmux_layout_reducer::LayoutOpKind;

mod batch_close;
mod close_effects;
mod column_update;
mod effectful_operation;
mod emptied_workspace;
mod end_terminals_batch;
mod layout_ops;
mod layout_projection;
mod pane_browser;
mod pane_tab_moves;
mod published_screen;
mod rename_focus;
mod reservations;
mod screen_create;
mod structural_move;
mod tab_workspace_move;
mod topology_operation;
#[cfg(test)]
mod topology_test_hooks;
mod unpublished_creation;
pub(crate) use batch_close::{BatchCloseOutcome, BatchCloseTarget, CloseReason};
use layout_projection::{remove_pane_from_layout, sync_layout_column_projection};
use pane_browser::{creation_identity_kind, effect_browser_cell_size};
use published_screen::screen_value;
pub(super) use structural_move::structural_tab_move_plan;

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
    mutation: &'a WorkspaceMutation,
}

struct PaneAddOptions<'a> {
    direction: Option<&'a str>,
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    size: Option<(u16, u16)>,
    ratio: Option<f32>,
    viewport_width: Option<f32>,
    /// `new-row` (`rows-v1`): the new row's height in permille.
    row_height: Option<u16>,
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
    /// The workspace the detach emptied, closed in the same commit.
    pub(super) workspace_close: Option<ResourceWorkspaceClose>,
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
        workspace_revision: Option<u64>,
    ) -> TerminalExitDetachEffects {
        self.state.resource_revision = resource_revision;
        if let Some(revision) = workspace_revision {
            self.state.workspace_revision = revision;
        }
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
                    .prepare_resource_creation_for(
                        correlation_key,
                        mutation,
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
                        ResourceEffectIntentContext { expected_revision, mutation },
                        &mut state,
                        &registry,
                    )?;
                    registry.prepare_resource_creation_for(
                        correlation_key,
                        mutation,
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
                let result = match self.execute_resource_topology_effect(
                    &mutation.actor,
                    operation,
                    &intent,
                ) {
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
                    Err(error) => self.settle_unpublished_creation(&recovery, failure, error),
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
                self.close_workspace_at_revision_for_resource_effect(&Actor::Daemon, workspace)?
                    .is_some(),
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
        let fields = recovery.intent["fields"].as_object().cloned().unwrap_or_default();
        match creation_identity_kind(operation, &fields) {
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
        let creates = creation_identity_kind(operation, fields);
        if creates == Some(CreatedIdentityKind::Terminal) {
            let terminal_id = match fields.get(RESERVED_TERMINAL_ID_FIELD) {
                Some(requested) => {
                    let requested =
                        requested.as_str().context("bad request: terminal_id must be a string")?;
                    validate_requested_terminal_id(requested)?;
                    anyhow::ensure!(
                        registry.terminal_record(requested)?.is_none(),
                        "terminal_id_exists: {requested}"
                    );
                    requested.to_string()
                }
                None => TerminalId::random()?.to_hex(),
            };
            let mutation = context.mutation.reservation();
            intent["terminal_reservation"] = json!({
                "terminal_id":terminal_id,
                "mutation_id":mutation.id,
                "mutation_origin":mutation.origin,
                "mutation_actor":mutation.actor.wire(),
            });
        }
        if topology_effect_may_create_workspace(operation) {
            let mutation = context.mutation.reservation();
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
                "mutation_actor":mutation.actor.wire(),
            });
        }
        if creates == Some(CreatedIdentityKind::Browser) {
            // A frontend-rendered browser registers its content id before
            // the tab commits, so the creation must use that exact id.
            let browser_id = match fields.get("frontend_browser_id").and_then(Value::as_str) {
                Some(id) => Mux::unbound_frontend_browser_id(&registry.connection, id)?,
                None => BrowserPublicId::random()?,
            };
            intent["browser_reservation"] = json!({
                "tab_id":TabPublicId::random()?,
                "browser_id":browser_id,
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
        actor: &Actor,
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
                    self.close_workspace_at_revision_for_resource_effect(actor, target)?.is_some(),
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
                let cwd = optional_owned_string(fields, "cwd")?;
                let argv = optional_effect_command(fields)?;
                match slots.workspace {
                    Some(workspace) => self.effect_add_screen(
                        intent,
                        workspace,
                        name,
                        cwd,
                        argv,
                        effect_cell_size(fields)?,
                    ),
                    None => self.effect_create_workspace_terminal(
                        intent,
                        None,
                        TerminalEffectOptions {
                            argv,
                            cwd,
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
                            argv: optional_effect_command(fields)?,
                            cwd: optional_owned_string(fields, "cwd")?,
                            size: effect_cell_size(fields)?,
                            ratio: None,
                            viewport_width: None,
                            row_height: None,
                        },
                    ),
                    None if slots.workspace.is_some() => self.effect_create_terminal_in_workspace(
                        intent,
                        slots.workspace.expect("checked"),
                        TerminalEffectOptions {
                            argv: optional_effect_command(fields)?,
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
                            argv: optional_effect_command(fields)?,
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
                        argv: optional_effect_command(fields)?,
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
                        row_height: rows::row_height_field(fields)?,
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
                        optional_effect_command(fields)?,
                        optional_owned_string(fields, "cwd")?,
                        optional_owned_string(fields, "name")?,
                        effect_cell_size(fields)?,
                        None,
                    ),
                    None if slots.workspace.is_some() => self.effect_create_terminal_in_workspace(
                        intent,
                        slots.workspace.expect("checked"),
                        TerminalEffectOptions {
                            argv: optional_effect_command(fields)?,
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
                            argv: optional_effect_command(fields)?,
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
                    Some(pane) => self.new_browser_tab_for_effect(fields, pane, size, identity)?,
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
                            false,
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
        Ok(EffectSlots { workspace, screen, pane, tab, terminal: path.terminal.clone() })
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
        // `workspace.create {ephemeral: true}` stages the flag with the
        // workspace row; the request's fields are part of its fingerprint.
        let ephemeral = intent["fields"]["ephemeral"].as_bool().unwrap_or(false);
        let placement = self.create_empty_workspace_for_resource_effect(
            workspace_name,
            Some(workspace_key),
            workspace_public_id,
            &workspace_mutation,
            ephemeral,
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
        // The reservation's env is the creation's own (`env` field), so a
        // create into a fresh workspace gets it like one into a pane.
        let result = self.create_terminal_in_workspace_with_mutation_env(
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
            reservation.env.clone(),
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
        let notifications = self.tree_decorations();
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
                        transaction: None,
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
        let PaneAddOptions { direction, argv, cwd, size, ratio, viewport_width, row_height } =
            options;
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
        let pane_public_id = PanePublicId::random()?;
        let spawned =
            self.effect_spawn_pane_surface(intent, target, &workspace_key, argv, cwd, size)?;
        let surface = spawned.surface().clone();
        #[cfg(test)]
        if viewport_width.is_some()
            && let Some(hook) = self.viewport_split_after_spawn.lock().unwrap().clone()
        {
            hook();
        }
        let pane_id = self.next_id();
        let split_id = split_direction.map(|_| self.next_id());
        let base_column_id =
            (viewport_width.is_some() || row_height.is_some()).then(|| self.next_id());
        let base_row_id = row_height.map(|_| self.next_id());
        let active_at = self.next_active_at();
        let notifications = self.tree_decorations();
        let attached = (|| -> anyhow::Result<(TreeDelta, ScreenId, CreatedTerminalEffect)> {
            let mut state = self.state.lock().unwrap();
            let Some((workspace, screen_index)) = state.screen_of(target) else {
                anyhow::bail!("pane disappeared before new pane attachment");
            };
            let workspace_id = state.workspaces[workspace].id;
            let screen_id = state.workspaces[workspace].screens[screen_index].id;
            let screen = &mut state.workspaces[workspace].screens[screen_index];
            let before = screen.layout_snapshot();
            if let Some(height) = row_height {
                anyhow::ensure!(
                    screen.insert_layout_row_below(
                        target,
                        base_column_id.expect("new row reserved a base column id"),
                        base_row_id.expect("new row reserved a base row id"),
                        crate::model::LayoutRow::new(split_id.expect("row id"), height),
                        pane_id,
                    ),
                    "target pane disappeared from its layout"
                );
            } else if let Some(width) = viewport_width {
                let column = LayoutColumn::single(split_id.expect("column id"), width, pane_id);
                let base = base_column_id.expect("viewport column reserved a base id");
                anyhow::ensure!(
                    screen.insert_layout_column_after(target, base, column),
                    "target pane disappeared from its layout"
                );
            } else if let Some((dir, before_target)) = split_direction {
                let split = split_id.expect("split direction reserves an id");
                let in_viewport_column = screen.layout_columns_active();
                let root = if in_viewport_column {
                    let column = screen
                        .layout_column_for_pane_mut(target)
                        .context("target pane has no viewport column")?;
                    column.creation_order_auto_layout = None;
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
                    screen.creation_order_auto_layout = None;
                }
            } else if screen.layout_columns_active() {
                let column = screen
                    .layout_column_for_pane_mut(target)
                    .context("target pane has no viewport column")?;
                column.edit_row_of(target, |root, auto_layout| {
                    append_to_auto_layout(root, auto_layout, pane_id, || self.next_id());
                });
                screen.sync_layout_column_projection();
            } else {
                append_to_auto_layout(
                    &mut screen.root,
                    &mut screen.creation_order_auto_layout,
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
                    transaction: None,
                },
                screen_id,
                CreatedTerminalEffect { path },
            ))
        })();
        let (delta, changed_screen, created) = match attached {
            Ok(attached) => attached,
            Err(error) => {
                self.fail_pane_surface_attachment(&spawned)?;
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

#[derive(Debug, Clone)]
struct EffectSlots {
    workspace: Option<WorkspaceId>,
    screen: Option<ScreenId>,
    pane: Option<PaneId>,
    tab: Option<SurfaceId>,
    terminal: Option<TerminalPublicId>,
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

/// A caller-chosen terminal id is a lowercase UUIDv4 in 32 hex digits, the
/// same shape as a daemon-generated one.
fn validate_requested_terminal_id(value: &str) -> anyhow::Result<()> {
    let bytes = value.as_bytes();
    anyhow::ensure!(
        bytes.len() == 32
            && bytes.iter().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(byte))
            && bytes[12] == b'4'
            && matches!(bytes[16], b'8'..=b'b'),
        "bad request: terminal_id must be a 32-character lowercase UUIDv4 hex value"
    );
    Ok(())
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
        ResourceOperation::PaneCreate
        | ResourceOperation::TabCreateTerminal
        | ResourceOperation::ScreenCreate => {
            let _ = effect_cell_size(fields)?;
            let _ = optional_effect_command(fields)?;
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
            rows::validate_row_height_field(fields, direction)?;
            pane_browser::validate_pane_browser_fields(fields)?;
            let _ = effect_cell_size(fields)?;
            let _ = optional_effect_command(fields)?;
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

/// `argv` or `shell` when the creation names one, else none (the default
/// shell). Placement verbs store `argv` for `shell_args`.
fn optional_effect_command(fields: &Map<String, Value>) -> anyhow::Result<Option<Vec<String>>> {
    if fields.contains_key("argv") || fields.contains_key("shell") {
        effect_command(fields).map(Some)
    } else {
        Ok(None)
    }
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
    rows::refuse_layout_replace(current)?;
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
            let mut changed_dock = false;
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
                // `dock` present: `null` clears the flag, an object sets
                // it. Absent: a column that keeps its id keeps its flag, so a
                // client without `dock-columns-v1` never clears one.
                let kept = current
                    .layout_columns
                    .iter()
                    .find(|column| column.id == id)
                    .and_then(|column| column.dock);
                let dock = match column.get("dock") {
                    Some(Value::Null) => None,
                    Some(value) => Some(
                        serde_json::from_value::<ColumnDock>(value.clone())
                            .context("invalid viewport column dock")?,
                    ),
                    None => kept,
                };
                changed_dock |= dock.is_some() && dock != kept;
                parsed.push(LayoutColumn { dock, ..LayoutColumn::new(id, width, root, None) });
            }
            // A document that sets a new flag must satisfy the docked
            // invariants itself. Flags it keeps or echoes unchanged are
            // repaired by normalization, as when a column is removed.
            anyhow::ensure!(
                !changed_dock || crate::model::dock_columns_are_consistent(&parsed),
                "invalid viewport dock columns"
            );
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
        creation_order_auto_layout: None,
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
    operation.wire_name().to_owned()
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

/// Registry position for a workspace created into `group` (`None` =
/// ungrouped) at final index `index` among that section's members. Groups
/// partition the workspace order, so the position sits among the members,
/// and after the last member when `index` is past the end. Without an index
/// the workspace goes after the section's last member, or last overall.
pub(super) fn new_workspace_position(
    state: &State,
    presentation: &crate::workspace_registry::PresentationSnapshot,
    group: Option<&str>,
    index: Option<usize>,
) -> usize {
    let members = state
        .workspaces
        .iter()
        .enumerate()
        .filter(|(_, workspace)| {
            presentation.workspace(&workspace.key).and_then(|record| record.group.as_deref())
                == group
        })
        .map(|(position, _)| position)
        .collect::<Vec<_>>();
    match (index, members.last()) {
        (Some(index), Some(_)) if index < members.len() => members[index],
        (_, Some(last)) if group.is_some() || index.is_some() => last + 1,
        _ => state.workspaces.len(),
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
    u32::try_from(tab.position).context("tab index exceeds uint32")?;
    Ok(tab.public_value(pane.active_tab.as_ref() == Some(&tab.public_id)))
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

/// Assign target-pane positions in one pass over the topology tabs.
///
/// `target_order` is authoritative for both the moved tab and existing target
/// tabs. Keeping the first map entry preserves the previous `position` lookup
/// behavior if malformed input contains a duplicate public id.
fn reindex_target_tab_positions(
    tabs: &mut [RegistryTab],
    target_pane_id: &PanePublicId,
    target_order: &[TabPublicId],
) {
    let mut positions = HashMap::with_capacity(target_order.len());
    for (position, tab_id) in target_order.iter().enumerate() {
        positions.entry(tab_id).or_insert(position);
    }
    for tab in tabs {
        if let Some(&position) = positions.get(&tab.public_id) {
            tab.pane_id = target_pane_id.clone();
            tab.position = position;
        }
    }
}

fn target_location_screen(state: &State, location: (usize, usize)) -> ScreenId {
    state.workspaces[location.0].screens[location.1].id
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
        .creation_order_auto_layout
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
                    .creation_order_auto_layout
                    .as_ref()
                    .map(|panes| {
                        panes
                            .iter()
                            .map(|pane| public_pane(*pane))
                            .collect::<anyhow::Result<Vec<_>>>()
                    })
                    .transpose()?,
                dock: column.dock,
                rows: registry_viewport::registry_rows(state, column)?,
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
    layout.creation_order_auto_layout = None;
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
            column.creation_order_auto_layout = None;
        }
    }
    if !layout.layout_columns.is_empty() {
        sync_layout_column_projection(layout);
    }
    layout.creation_order_auto_layout = None;
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
    screen.creation_order_auto_layout = layout.creation_order_auto_layout;
    screen.viewport_splits = layout.viewport_splits;
    screen.viewport_base_width = layout.viewport_base_width;
    screen.layout_columns = layout.layout_columns;
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
mod structural_tab_move_tests;

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
        let mutation = WorkspaceMutation::daemon("attempt-one", "test").unwrap();
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
            .prepare_resource_creation_for(
                correlation_key,
                &mutation,
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
            &WorkspaceMutation::daemon_local("concurrent-test"),
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
