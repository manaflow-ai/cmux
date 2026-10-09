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
