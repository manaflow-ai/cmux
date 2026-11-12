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

#[cfg(unix)]
mod agent_cli_job;
mod effect_fields;
#[cfg(unix)]
pub(crate) use agent_cli_job::AgentCLIJobBusy;
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
pub(super) use topology_lookup::pane_value;
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
pub(super) use focus_plan::focus_change_deltas;
use focus_plan::focus_deltas;
use focus_plan::focus_pane_plan;
use focus_plan::reindex_target_tab_positions;
mod registry_layout;
use registry_layout::apply_layout_snapshot;
use registry_layout::overwrite_layout_snapshot;
use registry_layout::registry_screen_from_layout;
use registry_layout::set_layout_divider_hidden;
use registry_layout::set_layout_split_ratio;
use registry_layout::swap_layout_panes;
mod batch_close;
mod client_ids;
pub(crate) use client_ids::ensure_client_pane_id_unused;
mod close_effects;
mod column_update;
mod creation_burst_seams;
mod creation_group;
mod creation_settlement;
mod effect_execution;
mod effectful_operation;
mod emptied_workspace;
mod end_terminals_batch;
mod layout_ops;
pub(in crate::mux) use layout_ops::LayoutSizesUnchanged;
mod layout_projection;
mod pane_browser;
mod pane_move;
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
#[cfg(test)]
pub(super) use creation_burst_seams::CreationBurstSeams;
pub(super) use creation_group::CreationGroups;
pub(crate) use creation_group::with_group_join_notice;
use creation_group::{StagedCreation, StagedCreationOutcome, creation_shares_group_commit};
mod unpublished_creation;
pub(crate) use batch_close::{BatchCloseOutcome, BatchCloseTarget, CloseReason, RoomClose};
use layout_projection::{remove_pane_from_layout, sync_layout_column_projection};
pub(crate) use pane_browser::{PANE_BROWSER_URL_FIELD, TabSplit};

/// `pane.split`'s `focus` field: whether the new pane takes the focus. The
/// resource router sends `false` when a caller omits it, so a programmatic
/// split keeps the user's focus; the daemon's and the user's own splits omit
/// it and focus the new pane.
pub(crate) const PANE_SPLIT_FOCUS_FIELD: &str = "focus";

/// `workspace.create`'s `focus` field: whether the new workspace becomes the
/// focused one. The resource router sends `false` when a caller omits it.
pub(crate) const WORKSPACE_CREATE_FOCUS_FIELD: &str = "focus";

/// `screen.create`'s `focus` field: whether the new screen becomes its
/// workspace's focused screen. The resource router sends `false` when a
/// caller omits it; the daemon's and the user's own new screens omit it and
/// focus the new screen.
pub(crate) const SCREEN_CREATE_FOCUS_FIELD: &str = "focus";
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
    /// Whether the new pane takes the screen's focus. The user's own splits
    /// (raw `split`, the TUI, the app) do; a `pane.split` resource request
    /// does only with `focus: true` (the router defaults it to false).
    focus: bool,
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
    /// The terminals the close ended, for their after-commit work.
    ended: EndedTerminals,
}

/// When a close ends the terminals it leaves with no view (W7-C: one close
/// model for every close).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CloseMode {
    /// Leave them running with no tab and mark each one `keep`, so the
    /// reaper leaves it too (`terminals: keep`, `--keep-terminals`).
    Keep,
    /// Leave them with no tab and no mark; a running reaper ends them after
    /// its grace (the raw closes, `terminals: detach`).
    Detach,
    /// Leave them with no tab until the reaper's grace ends them, so
    /// `closed.reopen` in that window shows the same process again; with no
    /// reaper running, end them now. The default of every public close.
    Grace,
    /// End them now (`--now`).
    Now,
}

impl CloseMode {
    /// The mode of a raw batch close's `end_terminals` flag: `true` ends
    /// now, `false` detaches.
    pub(crate) fn ending(end_terminals: bool) -> Self {
        if end_terminals { Self::Now } else { Self::Detach }
    }
}

/// What a close does with each terminal it leaves with no view (W7-C:
/// "close ends what it closed", one model with a grace window).
///
/// A terminal marked `keep` or with an attached viewer (`terminal attach`)
/// is left running. A terminal whose process is the caller's (the actor's
/// own terminal, or one whose process is the request's socket peer, an
/// ancestor of it or its process session's leader) is never ended now. Any
/// other one ends now in ``CloseMode::Now``, and in ``CloseMode::Grace``
/// when no reaper runs. In ``CloseMode::Keep`` the rest stay running and are
/// marked `keep`. The rest stay with no tab: while a reaper runs they end at
/// the close time plus its grace (`ending`), else they keep running.
pub(super) struct CloseTerminals {
    mode: CloseMode,
    /// The actor's own terminal.
    spare: Option<TerminalPublicId>,
    /// The socket peer's processes (`crate::server::peer_processes`).
    peer: Vec<u32>,
    /// Leave an exited terminal's record, so `terminal.wait_exit` still
    /// answers its exit (the public closes; the batch closes end it).
    keep_exited: bool,
    /// The reaper's grace while it runs; None: no reaper.
    reap_grace: Option<Duration>,
}

impl CloseTerminals {
    /// A batch close (`close-tabs`, the container closes with
    /// `end_terminals`, `layout.bulk`) of `mutation` in `mode`.
    pub(super) fn batch(mux: &Mux, mode: CloseMode, mutation: &WorkspaceMutation) -> Self {
        Self::new(mux, mode, mutation, false)
    }

    /// A public tab, pane, screen or workspace close of `mutation` in `mode`.
    pub(super) fn public(mux: &Mux, mode: CloseMode, mutation: &WorkspaceMutation) -> Self {
        Self::new(mux, mode, mutation, true)
    }

    fn new(mux: &Mux, mode: CloseMode, mutation: &WorkspaceMutation, keep_exited: bool) -> Self {
        Self {
            mode,
            spare: actor_terminal(&mutation.actor),
            peer: mutation.peer_pid.map(crate::server::peer_processes).unwrap_or_default(),
            keep_exited,
            reap_grace: mux.terminal_reaper_running().then(|| mux.terminal_reap_grace()),
        }
    }

    /// Whether the close may end `runtime` now: not the caller's own terminal
    /// nor one the request's socket peer runs in, and the mode ends now.
    fn ends_now(&self, public_id: &TerminalPublicId, runtime: &Surface) -> bool {
        !self.callers(public_id, runtime)
            && match self.mode {
                CloseMode::Now => true,
                CloseMode::Grace => self.reap_grace.is_none(),
                CloseMode::Keep | CloseMode::Detach => false,
            }
    }

    /// Whether `runtime` is the caller's own terminal or one the request's
    /// socket peer runs in.
    fn callers(&self, public_id: &TerminalPublicId, runtime: &Surface) -> bool {
        self.spare.as_ref() == Some(public_id)
            || runtime.process_id().is_some_and(|process| self.peer.contains(&process))
    }

    /// Whether the close marks `runtime` `keep`: in ``CloseMode::Keep``,
    /// each one but the caller's own, which the reaper still ends after its
    /// grace (the worktree close keeps its terminals and ends them itself,
    /// all but the caller's).
    fn marks_kept(&self, public_id: &TerminalPublicId, runtime: &Surface) -> bool {
        self.mode == CloseMode::Keep && !self.callers(public_id, runtime)
    }
}

/// The actor's own terminal, when the actor is a terminal.
fn actor_terminal(actor: &Actor) -> Option<TerminalPublicId> {
    match actor {
        Actor::Terminal { id } => TerminalPublicId::parse(id.clone()).ok(),
        _ => None,
    }
}

/// The terminals one close ended, the ones it left with no view until the
/// reaper's grace ends them, and the ones it left running with no view.
#[derive(Default)]
pub(super) struct EndedTerminals {
    runtimes: Vec<Arc<Surface>>,
    public_ids: Vec<TerminalPublicId>,
    ended: Vec<batch_close::EndedTerminal>,
    ending: Vec<TerminalPublicId>,
    /// When the reaper ends `ending` (milliseconds since the epoch).
    ends_at_ms: Option<u64>,
    running: Vec<TerminalPublicId>,
    /// The host ids of the terminals the close marks `keep` once it has
    /// committed (``CloseMode::Keep``).
    keep_hosts: Vec<String>,
}

impl EndedTerminals {
    /// Names the sets in a close's result object: `ended_terminal_ids`,
    /// `ending_terminal_ids` (with `ends_at_ms`, a decimal string, when any)
    /// and `running_terminal_ids`.
    pub(super) fn name_in(&self, result: &mut Value) {
        let Some(fields) = result.as_object_mut() else { return };
        fields.insert("ended_terminal_ids".into(), json!(self.public_ids));
        fields.insert("ending_terminal_ids".into(), json!(self.ending));
        if let Some(ends_at_ms) = self.ends_at_ms.filter(|_| !self.ending.is_empty()) {
            fields.insert("ends_at_ms".into(), json!(ends_at_ms.to_string()));
        }
        fields.insert("running_terminal_ids".into(), json!(self.running));
    }
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
    /// The typed end each `SurfaceExited` carries.
    end: Option<Arc<Value>>,
}

impl TerminalExitDetachEffects {
    pub(super) fn with_end(mut self, end: Option<Arc<Value>>) -> Self {
        self.end = end;
        self
    }
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
            end: None,
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

/// Cause logged when a creation waits on an earlier attempt that is still
/// running or has an indeterminate outcome.
const BLOCKED_CREATION_CAUSE: &str =
    "an earlier attempt of this creation is still running or has an indeterminate outcome";

/// Joins an indeterminate creation's reason with the failure that started its
/// settlement, when there is one.
fn creation_cause(reason: &str, failure: Option<&ResourceError>) -> String {
    match failure {
        Some(failure) => {
            format!("{reason}; the attempt failed ({}: {})", failure.code, failure.message)
        }
        None => reason.to_string(),
    }
}

fn creation_settlement_result(
    mux: &Mux,
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
            mux.report_resource_effect_indeterminate(
                idempotency_key,
                operation,
                "an interrupted attempt of this creation has not settled yet",
            );
            Err(anyhow::Error::new(resource_effect_indeterminate(idempotency_key, operation)))
        }
    }
}

#[cfg(test)]
mod structural_tab_move_tests;

#[cfg(test)]
mod creation_recovery_tests;

#[cfg(all(test, unix))]
mod launch_activation_tests;
