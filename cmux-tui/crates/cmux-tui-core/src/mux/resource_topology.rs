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

mod effect_fields;
use effect_fields::created_identity_kind;
use effect_fields::effect_cell_size;
use effect_fields::effect_command;
use effect_fields::effect_on_exit;
use effect_fields::effect_target;
use effect_fields::is_created_path_operation;
use effect_fields::is_effectful;
use effect_fields::is_resource_close_operation;
use effect_fields::layout_resize_coalesce;
use effect_fields::nullable_name;
use effect_fields::operation_name;
use effect_fields::optional_effect_command;
use effect_fields::optional_owned_string;
use effect_fields::parse_direction;
use effect_fields::required_f64;
use effect_fields::required_str;
use effect_fields::required_u64;
use effect_fields::resource_effect_indeterminate;
use effect_fields::semantic_creation_fields;
use effect_fields::topology_effect_may_create_workspace;
use effect_fields::validate_effect_fields;
use effect_fields::validate_requested_terminal_id;
mod layout_document;
use layout_document::apply_resource_layout_document;
use layout_document::validate_layout_apply_intent;
mod topology_lookup;
use topology_lookup::active_screen;
use topology_lookup::delete_delta;
use topology_lookup::find_screen;
pub(super) use topology_lookup::new_workspace_position;
use topology_lookup::pane_value;
use topology_lookup::pane_value_with_flags;
use topology_lookup::pane_value_with_zoom;
use topology_lookup::registry_workspace;
use topology_lookup::set_active_screen;
use topology_lookup::tab_value;
use topology_lookup::target_location_screen;
use topology_lookup::topology_pane;
use topology_lookup::topology_pane_mut;
use topology_lookup::topology_screen;
use topology_lookup::topology_tab;
use topology_lookup::topology_tab_mut;
use topology_lookup::upsert;
use topology_lookup::upserts;
use topology_lookup::workspace_value;
mod focus_plan;
use focus_plan::apply_focus_path;
use focus_plan::focus_deltas;
use focus_plan::focus_pane_plan;
use focus_plan::reindex_target_tab_positions;
mod registry_layout;
use registry_layout::apply_layout_snapshot;
use registry_layout::overwrite_layout_snapshot;
use registry_layout::registry_screen_from_layout;
use registry_layout::set_layout_split_ratio;
use registry_layout::swap_layout_panes;
use registry_layout::sync_layout_column_widths;
mod batch_close;
mod client_ids;
mod close_effects;
mod column_update;
mod creation_settlement;
mod effect_execution;
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
