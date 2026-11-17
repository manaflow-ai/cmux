//! Daemon side of the layout invariants: project the live [`State`] to the
//! pure [`cmux_layout_reducer::LayoutState`] and validate layout commands
//! against the reducer before they commit.
//!
//! The invariants themselves (I1 tab conservation, I2 single placement, I3
//! no empty panes, I4 own-position moves, I5 idempotent replay) and their
//! checkers live in the `cmux-layout-reducer` crate. For every tab-conserving
//! resource operation (see [`conserves_tabs`]), with both writer locks held
//! and before the durable commit, the daemon
//!
//! 1. runs the reducer on the model of the live state when the operation
//!    names its [`LayoutOpKind`] ([`model_result`]), and rejects the
//!    operation on a reducer rejection before the live state changes;
//! 2. runs the live state change, and [`validate_layout_transition`] rejects
//!    it, restoring the previous state, when the result introduces an I1-I3
//!    violation the previous state did not have or places a tab differently
//!    than the reducer does.
//!
//! Both steps model only the workspaces the operation touches
//! ([`operation_scope`]: those its plan's patch and its reducer op name, and
//! those it creates), so their work does not grow with the session
//! (https://github.com/manaflow-ai/cmux/issues/45007). A step that adds or
//! removes a pane or a runtime surface outside them is checked on the whole
//! state, and a plan that names nothing in the layout is too.
//!
//! The check is relative on purpose: state restored from an older build that
//! already breaks an invariant must not block every later layout operation.
//! This module depends only on the layout model, never on PTY or session
//! runtime, so it can move to the workspace-store side unchanged.

use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;

use cmux_layout_reducer::{
    Column, LayoutOp, LayoutOpKind, LayoutState, Row, Screen, TabContent, Workspace, apply_mut,
    introduced_violations, placement_mismatches,
};
use serde_json::json;

use crate::resource::{ContentPublicId, PanePublicId, ResourceError, ScreenPublicId, TabPublicId};
use crate::workspace_registry::{ResourceChange, ResourcePatch};
use crate::{PaneId, State, SurfaceId, WorkspaceId};

/// `reason_code` in the `operation.failed` details of a rejected operation.
pub(crate) const LAYOUT_CONSERVATION_VIOLATION: &str = "layout-conservation-violation";

/// Resource operations that move tabs and must keep every tab (I1).
/// Creation and close operations are absent (they change the tab set on
/// purpose), and so are operations that cannot move a tab (workspace
/// reorder, screen pins, renames, focus).
const TAB_CONSERVING_OPERATIONS: &[&str] = &[
    "tab.move",
    "tab.drag",
    "tab.move_workspace",
    "tab.group.create",
    "tab.group.add",
    "tab.group.remove",
    "tab.group.move",
    "pane.swap",
    "pane.move",
    "screen.move",
    "screen.group.create",
    "screen.group.add",
    "screen.group.remove",
    "screen.group.move",
    "terminal.move",
];

/// Whether `operation` must conserve tabs, so the daemon validates its
/// result before it commits.
pub(crate) fn conserves_tabs(operation: &str) -> bool {
    TAB_CONSERVING_OPERATIONS.contains(&operation)
}

/// The workspaces an operation's layout check covers: the ones holding what
/// its plan and reducer op name, or every workspace when they name nothing
/// in the layout (https://github.com/manaflow-ai/cmux/issues/45007).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LayoutScope {
    All,
    Workspaces(BTreeSet<WorkspaceId>),
}

impl LayoutScope {
    fn contains(&self, workspace: WorkspaceId) -> bool {
        match self {
            Self::All => true,
            Self::Workspaces(workspaces) => workspaces.contains(&workspace),
        }
    }

    /// The scope after the operation's state step: the workspaces it
    /// created are in it too.
    fn with_created(&self, before: &State, after: &State) -> Self {
        match self {
            Self::All => Self::All,
            Self::Workspaces(workspaces) => {
                let mut workspaces = workspaces.clone();
                workspaces.extend(
                    after
                        .workspaces
                        .iter()
                        .map(|workspace| workspace.id)
                        .filter(|id| before.workspace_index(*id).is_none()),
                );
                Self::Workspaces(workspaces)
            }
        }
    }
}

/// The scope of an operation on `state` (before it): the workspaces of the
/// tabs, panes, screens and workspaces that `kind` and the `patch` it
/// commits name. Ids that `state` does not hold yet are created by the
/// operation; their parent is named too (a new pane's screen, a new screen's
/// workspace), and a new workspace joins after the step
/// ([`LayoutScope::with_created`]).
pub(crate) fn operation_scope(
    state: &State,
    kind: Option<&LayoutOpKind>,
    patch: &ResourcePatch,
) -> LayoutScope {
    let indexes = &state.resource_indexes;
    let mut workspaces = BTreeSet::new();
    let mut workspace = |id: WorkspaceId| {
        if state.workspace_index(id).is_some() {
            workspaces.insert(id);
        }
    };
    let pane_workspace =
        |pane: PaneId| state.screen_of(pane).map(|(workspace, _)| state.workspaces[workspace].id);
    let screen_workspace = |screen: &ScreenPublicId| {
        indexes.screens.get(screen).and_then(|screen| indexes.screen_workspace.get(screen)).copied()
    };
    let tab_workspace = |tab: SurfaceId| state.pane_of(tab).and_then(pane_workspace);
    let public_pane =
        |pane: &PanePublicId| indexes.panes.get(pane).copied().and_then(pane_workspace);
    let public_tab = |tab: &TabPublicId| indexes.tabs.get(tab).copied().and_then(tab_workspace);
    let mut named = Vec::<Option<WorkspaceId>>::new();
    if let Some(kind) = kind {
        match kind {
            LayoutOpKind::MoveTab { tab, pane, .. }
            | LayoutOpKind::MoveTabToSplit { tab, pane, .. }
            | LayoutOpKind::MoveTabToColumn { tab, anchor: pane, .. }
            | LayoutOpKind::MoveTabToRow { tab, anchor: pane, .. } => {
                named.extend([tab_workspace(*tab), pane_workspace(*pane)]);
            }
            LayoutOpKind::MoveTabToNewWorkspace { tab, .. } => named.push(tab_workspace(*tab)),
            LayoutOpKind::MoveTabToWorkspace { tab, workspace, pane, .. } => {
                named.extend([tab_workspace(*tab), Some(*workspace)]);
                named.push(pane.and_then(pane_workspace));
            }
            LayoutOpKind::InsertRow { after_pane, .. } => named.push(pane_workspace(*after_pane)),
            LayoutOpKind::SetRowHeights { column, .. } | LayoutOpKind::FlattenRows { column } => {
                named.push(
                    state
                        .workspaces
                        .iter()
                        .find(|workspace| {
                            workspace.screens.iter().any(|screen| {
                                screen
                                    .layout_columns
                                    .iter()
                                    .any(|candidate| candidate.id == *column)
                            })
                        })
                        .map(|workspace| workspace.id),
                );
            }
            LayoutOpKind::CloseTab { tab } => named.push(tab_workspace(*tab)),
            LayoutOpKind::RuntimeExited { .. } => return LayoutScope::All,
        }
    }
    for change in &patch.changes {
        match change {
            ResourceChange::UpsertWorkspace { workspace, .. } => named.push(Some(workspace.id)),
            ResourceChange::TombstoneWorkspace { workspace_id }
            | ResourceChange::SetScreenOrder { workspace_id, .. } => {
                named.push(indexes.workspaces.get(workspace_id).copied());
            }
            ResourceChange::UpsertScreen(screen) => {
                named.push(screen_workspace(&screen.public_id));
                named.push(indexes.workspaces.get(&screen.workspace_id).copied());
            }
            ResourceChange::TombstoneScreen { screen_id } => {
                named.push(screen_workspace(screen_id));
            }
            ResourceChange::UpsertPane(pane) => {
                named.extend([public_pane(&pane.public_id), screen_workspace(&pane.screen_id)]);
            }
            ResourceChange::TombstonePane { pane_id } => named.push(public_pane(pane_id)),
            ResourceChange::UpsertTab(tab) => {
                named.extend([public_tab(&tab.public_id), public_pane(&tab.pane_id)]);
            }
            ResourceChange::TombstoneTab { tab_id, .. } => named.push(public_tab(tab_id)),
            ResourceChange::SetTabOrder { pane_id, tab_ids } => {
                named.push(public_pane(pane_id));
                named.extend(tab_ids.iter().map(public_tab));
            }
            // Order, focus and content change no workspace's layout.
            ResourceChange::SetWorkspaceOrder { .. }
            | ResourceChange::SetActiveWorkspace { .. }
            | ResourceChange::UpsertTerminal { .. }
            | ResourceChange::TombstoneTerminal { .. }
            | ResourceChange::UpsertBrowser(_)
            | ResourceChange::TombstoneBrowser { .. } => {}
        }
    }
    named.into_iter().flatten().for_each(&mut workspace);
    if workspaces.is_empty() { LayoutScope::All } else { LayoutScope::Workspaces(workspaces) }
}

/// The layout model of `state`. A tab's content is the address of its
/// runtime (stable while both compared states hold it) and its terminal.
pub(crate) fn project(state: &State) -> LayoutState {
    project_scope(state, &LayoutScope::All, std::iter::empty())
}

/// The model of the workspaces in `scope`: their layout, the panes it
/// places and those panes' tabs, plus the tabs in `named` that `state` still
/// holds wherever they are (so a tab a step dropped from its pane reads as
/// unplaced, not lost). The whole scope also has every pane and every
/// runtime surface.
pub(crate) fn project_scope(
    state: &State,
    scope: &LayoutScope,
    named: impl IntoIterator<Item = SurfaceId>,
) -> LayoutState {
    let workspaces = state
        .workspaces
        .iter()
        .filter(|workspace| scope.contains(workspace.id))
        .map(project_workspace)
        .collect::<Vec<_>>();
    let (panes, tabs) = match scope {
        LayoutScope::All => (
            state.panes.iter().map(|(id, pane)| (*id, pane.tabs.clone())).collect(),
            state
                .surfaces
                .iter()
                .map(|(id, runtime)| (*id, surface_content(runtime)))
                .chain(unmaterialized_tabs(state))
                .collect(),
        ),
        LayoutScope::Workspaces(_) => {
            let panes = workspaces
                .iter()
                .flat_map(Workspace::pane_ids)
                .filter_map(|pane| Some((pane, state.panes.get(&pane)?.tabs.clone())))
                .collect::<BTreeMap<_, _>>();
            let tabs = panes
                .values()
                .flatten()
                .copied()
                .chain(named)
                .filter_map(|tab| Some((tab, tab_content(state, tab)?)))
                .collect();
            (panes, tabs)
        }
    };
    #[cfg(test)]
    PROJECTED_PANES.with(|count| count.set(count.get() + panes.len()));
    LayoutState::new(workspaces, panes, tabs)
}

fn project_workspace(workspace: &crate::model::Workspace) -> Workspace {
    Workspace {
        id: workspace.id,
        screens: workspace
            .screens
            .iter()
            .map(|screen| Screen {
                id: screen.id,
                columns_active: !screen.layout_columns.is_empty(),
                // While columns are active, `root` is a derived
                // projection of them.
                columns: if screen.layout_columns.is_empty() {
                    vec![Column::single(0, screen.root.pane_ids_vec())]
                } else {
                    screen.layout_columns.iter().map(project_column).collect()
                },
            })
            .collect(),
    }
}

fn surface_content(runtime: &Arc<crate::Surface>) -> TabContent {
    TabContent {
        runtime: Arc::as_ptr(runtime) as *const () as usize as u64,
        terminal: runtime.terminal_public_id().map(ToString::to_string),
        dead: runtime.is_dead(),
    }
}

/// The content of `tab`: its runtime surface, or its durable content.
fn tab_content(state: &State, tab: SurfaceId) -> Option<TabContent> {
    match state.surfaces.get(&tab) {
        Some(runtime) => Some(surface_content(runtime)),
        None => durable_content(state, tab),
    }
}

/// A placed tab's durable identity with no runtime (0, never a surface
/// address).
fn durable_content(state: &State, tab: SurfaceId) -> Option<TabContent> {
    let terminal = match state.resource_indexes.content_ids.get(&tab)? {
        ContentPublicId::Terminal(terminal) => Some(terminal.to_string()),
        ContentPublicId::Browser(_) => None,
    };
    Some(TabContent { runtime: 0, terminal, dead: false })
}

/// Placed tabs with durable content but no runtime surface, such as a
/// terminal still adopting after a daemon restart or one whose host was lost
/// (R41). Their content is their durable identity with no runtime, so the
/// reducer moves them like any other tab
/// (https://github.com/manaflow-ai/cmux/issues/25999).
fn unmaterialized_tabs(state: &State) -> impl Iterator<Item = (SurfaceId, TabContent)> + '_ {
    state.panes.values().flat_map(|pane| &pane.tabs).filter_map(|tab| {
        if state.surfaces.contains_key(tab) {
            return None;
        }
        Some((*tab, durable_content(state, *tab)?))
    })
}

/// The model of what `kind` touches in `state`, for a reducer check before
/// an operation without a plan.
pub(crate) fn project_for(state: &State, kind: &LayoutOpKind) -> LayoutState {
    let scope = operation_scope(state, Some(kind), &ResourcePatch { changes: Vec::new() });
    project_scope(state, &scope, std::iter::empty())
}

/// One viewport column of the model: its panes in order and, with
/// `rows-v1`, the rows partitioning them.
fn project_column(column: &crate::model::LayoutColumn) -> Column {
    let rows = column
        .row_trees()
        .into_iter()
        .map(|(row, tree)| Row {
            id: row.id,
            height_permille: row.height,
            len: tree.pane_ids_vec().len(),
        })
        .collect();
    Column { id: column.id, panes: column.root.pane_ids_vec(), rows }
}

/// Run the reducer for `kind` on the model of the live state `before`.
/// A reducer rejection rejects the operation before the live state changes.
pub(crate) fn model_result(
    operation: &str,
    before: &LayoutState,
    kind: &LayoutOpKind,
) -> anyhow::Result<LayoutState> {
    // The daemon keeps its own durable replay ledger, so the key is unused.
    let op = LayoutOp { key: String::new(), kind: kind.clone() };
    let mut model = before.clone();
    apply_mut(&mut model, &op).map(|_| model).map_err(|reject| {
        rejection(operation, vec![format!("the layout reducer rejects it: {reject}")])
    })
}

/// Every reason to reject the change from `before` (the model of the live
/// state before it) to the live state `after`: introduced invariant
/// violations, and, when the reducer ran, a placement it does not produce.
pub(crate) fn transition_problems(
    before: &LayoutState,
    model: Option<&LayoutState>,
    after: &State,
) -> Vec<String> {
    problems(before, model, &project(after))
}

fn problems(before: &LayoutState, model: Option<&LayoutState>, after: &LayoutState) -> Vec<String> {
    let mut problems = introduced_violations(before, after, &BTreeSet::new())
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    if let Some(model) = model {
        problems.extend(
            placement_mismatches(model, after)
                .iter()
                .map(|mismatch| format!("the layout reducer disagrees: {mismatch}")),
        );
    }
    problems
}

/// [`transition_problems`] for an operation of `scope`, from the live state
/// `before_state` (whose model of `scope` is `before`) to `after`. It
/// projects the scope's workspaces, plus those the step created, and checks
/// that the panes and runtime surfaces outside them did not change in
/// number; when they did, it checks the whole state.
pub(crate) fn scoped_transition_problems(
    scope: &LayoutScope,
    before_state: &State,
    before: &LayoutState,
    model: Option<&LayoutState>,
    after: &State,
) -> Vec<String> {
    if *scope == LayoutScope::All {
        return transition_problems(before, model, after);
    }
    let scope = scope.with_created(before_state, after);
    let after_model = project_scope(after, &scope, before.tabs.keys().copied());
    let surfaces = |model: &LayoutState| model.tabs.values().filter(|tab| tab.runtime != 0).count();
    let outside_kept = before_state.panes.len() - before.panes.len()
        == after.panes.len() - after_model.panes.len()
        && before_state.surfaces.len() - surfaces(before)
            == after.surfaces.len() - surfaces(&after_model);
    if outside_kept {
        problems(before, model, &after_model)
    } else {
        // The step reached past its scope: the whole state decides.
        problems(&project(before_state), None, &project(after))
    }
}

/// Reject a tab-conserving `operation` of `scope` whose live result `after`
/// breaks a layout invariant or differs from the reducer's result `model`.
pub(crate) fn validate_layout_transition(
    operation: &str,
    scope: &LayoutScope,
    before_state: &State,
    before: &LayoutState,
    model: Option<&LayoutState>,
    after: &State,
) -> anyhow::Result<()> {
    let problems = scoped_transition_problems(scope, before_state, before, model, after);
    if problems.is_empty() { Ok(()) } else { Err(rejection(operation, problems)) }
}

fn rejection(operation: &str, problems: Vec<String>) -> anyhow::Error {
    #[cfg(test)]
    REJECTIONS.with(|count| count.set(count.get() + 1));
    ResourceError::operation_failed(
        operation,
        format!("{LAYOUT_CONSERVATION_VIOLATION}: {}", problems.join("; ")),
        json!({
            "reason_code": LAYOUT_CONSERVATION_VIOLATION,
            "violations": problems,
        }),
    )
    .into()
}

#[cfg(test)]
thread_local! {
    /// Rejections on this thread, so property tests can tell a layout bug
    /// that the daemon caught from an ordinary rejection.
    static REJECTIONS: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
thread_local! {
    /// Panes the layout projections on this thread put in a model: the work
    /// the daemon's validation does per operation.
    static PROJECTED_PANES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(crate) fn projected_panes_on_this_thread() -> usize {
    PROJECTED_PANES.with(std::cell::Cell::get)
}

#[cfg(test)]
pub(crate) fn rejections_on_this_thread() -> usize {
    REJECTIONS.with(std::cell::Cell::get)
}

#[cfg(test)]
#[path = "layout_invariants_tests.rs"]
mod tests;
