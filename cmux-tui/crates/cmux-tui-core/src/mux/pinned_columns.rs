//! Pinned dock columns (`pinned-dock-v1`): the Home dock.
//!
//! A pinned column's first tab is its pinned tab (Home's page). It never
//! closes, never leaves the column and keeps the first place. While the
//! column's `allow_tabs` is off (the default) no other tab enters it: a new
//! tab, a move in or a drop is refused. A terminal tab aimed at it opens in a
//! new column right of it instead, in one `pane.split` commit
//! ([`terminal_column_beside_closed_dock`], FC-1), and so does a browser or
//! conversation tab made in a pinned column alone on its screen
//! (`pinned-dock-alone-v1`, [`lone_pinned_dock_taking_no_tabs`]). A pinned column is never removed,
//! undocked or moved to another edge either. Closing the whole workspace (or
//! its last screen) and a terminal that exited on its own are not refusals;
//! a tab or pane close that would empty the workspace and close it with the
//! pinned tab is (the pinned tab of a lone pinned column, `pinned-dock-alone-v1`).
//!
//! The rule reads the column's tabs only, never a title or a page name, so
//! it holds for every client and every path (a resource op, a JSON-lines
//! command, a layout undo). A batch close (`close-tabs`, `close-tab-group`,
//! `layout.bulk`, `stash.create`) keeps the rule of the single close it
//! stands for and refuses the whole set: nothing in it closes.

use super::*;
use crate::mux::dock_columns::PINNED_COLUMN_CODE;

/// The tabs of one pinned column before a change.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PinnedColumn {
    workspace: WorkspaceId,
    column: SplitId,
    /// The column's tabs in order (its panes in layout order).
    tabs: Vec<SurfaceId>,
}

/// Every pinned column of `state`, with its tabs.
pub(crate) fn pinned_columns(state: &State) -> Vec<PinnedColumn> {
    pinned_column_views(state).map(|(column, _)| column).collect()
}

/// The pinned tab (first tab) of every pinned column of `state`. A close
/// that picks its own tabs (a `layout.bulk` preset, a Workspace-form stash)
/// leaves these out, as it leaves out pinned tabs.
pub(crate) fn pinned_dock_tabs(state: &State) -> HashSet<SurfaceId> {
    pinned_column_views(state).filter_map(|(column, _)| column.tabs.first().copied()).collect()
}

fn pinned_column_views(state: &State) -> impl Iterator<Item = (PinnedColumn, bool)> + '_ {
    state.workspaces.iter().flat_map(move |workspace| {
        workspace.screens.iter().flat_map(move |screen| {
            screen.layout_columns.iter().filter_map(move |column| {
                let flag = column.dock.filter(|flag| flag.pinned)?;
                let tabs = column
                    .root
                    .pane_ids_vec()
                    .into_iter()
                    .filter_map(|pane| state.panes.get(&pane))
                    .flat_map(|pane| pane.tabs.iter().copied())
                    .collect();
                Some((
                    PinnedColumn { workspace: workspace.id, column: column.id, tabs },
                    flag.allow_tabs,
                ))
            })
        })
    })
}

const PINNED_TAB_KEPT: &str =
    "the pinned tab cannot close, leave its column or lose the first place";

/// Why a change breaks a pinned column, if it does. With
/// `workspace_close_counts` a workspace the change closed still loses its
/// pinned tab (a tab or pane close that emptied it); otherwise it is no removal.
fn violation(
    before: &[PinnedColumn],
    after: &State,
    workspace_close_counts: bool,
) -> Option<&'static str> {
    if before.is_empty() {
        return None;
    }
    let after_columns = pinned_column_views(after).collect::<Vec<_>>();
    for column in before {
        if !after.workspaces.iter().any(|workspace| workspace.id == column.workspace) {
            if workspace_close_counts && !column.tabs.is_empty() {
                return Some(PINNED_TAB_KEPT);
            }
            continue; // the workspace closed: not a removal
        }
        let Some((now, allow_tabs)) = after_columns
            .iter()
            .find(|(now, _)| now.workspace == column.workspace && now.column == column.column)
        else {
            return Some("the pinned column cannot be removed, undocked or unpinned this way");
        };
        if let Some(first) = column.tabs.first()
            && now.tabs.first() != Some(first)
        {
            return Some(PINNED_TAB_KEPT);
        }
        if !allow_tabs && now.tabs.iter().any(|tab| !column.tabs.contains(tab)) {
            return Some("the pinned column takes no other tab (allow_tabs is off)");
        }
    }
    None
}

/// Refuses a change that broke a pinned column of `before` (see the module
/// docs). The error carries `reason_code` `dock-column-pinned`.
pub(crate) fn ensure_pinned_columns_kept(
    operation: &str,
    before: &[PinnedColumn],
    after: &State,
) -> anyhow::Result<()> {
    refuse(operation, violation(before, after, false))
}

/// [`ensure_pinned_columns_kept`] for a tab or pane close: a close that
/// empties the workspace and so closes it with the pinned tab is refused too
/// (Home's dock alone on its screen keeps its tab, `pinned-dock-alone-v1`).
pub(crate) fn ensure_pinned_tabs_not_closed(
    operation: &str,
    before: &[PinnedColumn],
    after: &State,
) -> anyhow::Result<()> {
    refuse(operation, violation(before, after, true))
}

fn refuse(operation: &str, reason: Option<&'static str>) -> anyhow::Result<()> {
    let Some(reason) = reason else {
        return Ok(());
    };
    Err(ResourceError::operation_failed(
        operation,
        format!("{PINNED_COLUMN_CODE}: {reason}"),
        serde_json::json!({"reason_code": PINNED_COLUMN_CODE}),
    )
    .into())
}

/// Refuses a new tab in `pane` when its column is pinned and takes no
/// tabs. Tab creation that spawns a process outside the staged plan checks
/// here first, so nothing starts for a refused tab.
pub(crate) fn ensure_pane_takes_tabs(
    operation: &str,
    state: &State,
    pane: PaneId,
) -> anyhow::Result<()> {
    if !pane_in_pinned_column_taking_no_tabs(state, pane) {
        return Ok(());
    }
    Err(ResourceError::operation_failed(
        operation,
        format!("{PINNED_COLUMN_CODE}: the pinned column takes no other tab (allow_tabs is off)"),
        serde_json::json!({"reason_code": PINNED_COLUMN_CODE}),
    )
    .into())
}

/// Whether `pane` is in a pinned column that takes no other tab (`allow_tabs` off).
pub(crate) fn pane_in_pinned_column_taking_no_tabs(state: &State, pane: PaneId) -> bool {
    state
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.layout_columns.iter())
        .any(|column| {
            column.dock.is_some_and(|flag| flag.pinned && !flag.allow_tabs)
                && column.root.contains(pane)
        })
}

/// The width of the new column a terminal tab aimed at `pane` opens in when
/// `pane` is in a pinned column that takes no tabs (FC-1), else `None`:
/// [`LONE_DOCK_NEIGHBOR_WIDTH`] beside a lone dock, as a link Home opens there;
/// the default column width beside a dock with other columns.
pub(crate) fn terminal_column_beside_closed_dock(state: &State, pane: PaneId) -> Option<f32> {
    if !pane_in_pinned_column_taking_no_tabs(state, pane) {
        return None;
    }
    Some(if pane_in_lone_pinned_column(state, pane) {
        LONE_DOCK_NEIGHBOR_WIDTH
    } else {
        crate::layout::DEFAULT_VIEWPORT_PANE_WIDTH
    })
}

/// The width of the column that opens right of a lone pinned column
/// (`pinned-dock-alone-v1`): a conversation split from Home's dock and a link
/// Home opens (`workspace.open_url`) both get it. A column width is a share of
/// the strip right of the dock, so 1.0 fills that space; 0.5 left half of it empty.
pub(crate) const LONE_DOCK_NEIGHBOR_WIDTH: f32 = 1.0;

/// Whether `pane` is in a pinned column alone on its screen
/// (`pinned-dock-alone-v1`: Home's dock with nothing beside it).
pub(crate) fn pane_in_lone_pinned_column(state: &State, pane: PaneId) -> bool {
    state.workspaces.iter().flat_map(|workspace| workspace.screens.iter()).any(
        |screen| match screen.layout_columns.as_slice() {
            [column] => column.dock.is_some_and(|flag| flag.pinned) && column.root.contains(pane),
            _ => false,
        },
    )
}

/// Whether `pane` is in a pinned column alone on its screen that takes no
/// tabs: a browser or conversation tab made there opens in a new column right
/// of it ([`LONE_DOCK_NEIGHBOR_WIDTH`]), so the dock never holds another tab.
pub(crate) fn lone_pinned_dock_taking_no_tabs(state: &State, pane: PaneId) -> bool {
    pane_in_lone_pinned_column(state, pane)
        && state
            .workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.layout_columns.iter())
            .any(|column| column.root.contains(pane) && column.dock.is_some_and(|f| !f.allow_tabs))
}
