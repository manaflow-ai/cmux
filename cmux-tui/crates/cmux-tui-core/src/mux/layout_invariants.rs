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
//! The check is relative on purpose: state restored from an older build that
//! already breaks an invariant must not block every later layout operation.
//! This module depends only on the layout model, never on PTY or session
//! runtime, so it can move to the workspace-store side unchanged.

use std::collections::BTreeSet;
use std::sync::Arc;

use cmux_layout_reducer::{
    Column, LayoutOp, LayoutOpKind, LayoutState, Row, Screen, TabContent, Workspace, apply,
    introduced_violations, placement_mismatches,
};
use serde_json::json;

use crate::State;
use crate::resource::ResourceError;

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

/// The layout model of `state`. A tab's content is the address of its
/// runtime (stable while both compared states hold it) and its terminal.
pub(crate) fn project(state: &State) -> LayoutState {
    LayoutState {
        workspaces: state
            .workspaces
            .iter()
            .map(|workspace| Workspace {
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
            })
            .collect(),
        panes: state.panes.iter().map(|(id, pane)| (*id, pane.tabs.clone())).collect(),
        tabs: state
            .surfaces
            .iter()
            .map(|(id, runtime)| {
                (
                    *id,
                    TabContent {
                        runtime: Arc::as_ptr(runtime) as *const () as usize as u64,
                        terminal: runtime.terminal_public_id().map(ToString::to_string),
                        dead: runtime.is_dead(),
                    },
                )
            })
            .collect(),
    }
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
    apply(before, &op).map(|(model, _)| model).map_err(|reject| {
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
    let after = project(after);
    let mut problems = introduced_violations(before, &after, &BTreeSet::new())
        .iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    if let Some(model) = model {
        problems.extend(
            placement_mismatches(model, &after)
                .iter()
                .map(|mismatch| format!("the layout reducer disagrees: {mismatch}")),
        );
    }
    problems
}

/// Reject a tab-conserving `operation` whose live result `after` breaks a
/// layout invariant or differs from the reducer's result `model`.
pub(crate) fn validate_layout_transition(
    operation: &str,
    before: &LayoutState,
    model: Option<&LayoutState>,
    after: &State,
) -> anyhow::Result<()> {
    let problems = transition_problems(before, model, after);
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
pub(crate) fn rejections_on_this_thread() -> usize {
    REJECTIONS.with(std::cell::Cell::get)
}

#[cfg(test)]
#[path = "layout_invariants_tests.rs"]
mod tests;
