//! Pinned dock columns (`pinned-dock-v1`): the Home dock.
//!
//! A pinned column's first tab is its pinned tab (Home's page). It never
//! closes, never leaves the column and keeps the first place. While the
//! column's `allow_tabs` is off (the default) no other tab enters it: a new
//! tab, a move in or a drop is refused. A pinned column is never removed,
//! undocked or moved to another edge either. Closing the whole workspace and
//! a terminal that exited on its own are not refusals.
//!
//! The rule reads the column's tabs only, never a title or a page name, so
//! it holds for every client and every path (a resource op, a JSON-lines
//! command, a layout undo).

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

/// Why a change breaks a pinned column, if it does.
fn violation(before: &[PinnedColumn], after: &State) -> Option<&'static str> {
    if before.is_empty() {
        return None;
    }
    let after_columns = pinned_column_views(after).collect::<Vec<_>>();
    for column in before {
        if !after.workspaces.iter().any(|workspace| workspace.id == column.workspace) {
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
            return Some("the pinned tab cannot close, leave its column or lose the first place");
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
    let Some(reason) = violation(before, after) else {
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
    let refused = state
        .workspaces
        .iter()
        .flat_map(|workspace| workspace.screens.iter())
        .flat_map(|screen| screen.layout_columns.iter())
        .any(|column| {
            column.dock.is_some_and(|flag| flag.pinned && !flag.allow_tabs)
                && column.root.contains(pane)
        });
    if !refused {
        return Ok(());
    }
    Err(ResourceError::operation_failed(
        operation,
        format!("{PINNED_COLUMN_CODE}: the pinned column takes no other tab (allow_tabs is off)"),
        serde_json::json!({"reason_code": PINNED_COLUMN_CODE}),
    )
    .into())
}
