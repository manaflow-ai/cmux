//! App screens (plans/cmux-next/app-screens.md, `app-screens-v1`).
//!
//! A screen has a [`ScreenKind`]. An `App` screen holds exactly one pane with
//! one tab (the app), and it is the only screen of its app workspace.
//! [`check_app_target`] is the one rule table for every command shape: the
//! daemon calls it for raw commands and v2 operations alike, and
//! [`apply`](crate::apply) calls it through [`check_app_op`] for every layout op.
//!
//! Invariants (with the reducer tests):
//! - **A1.** An `App` screen has one column, one pane, one tab.
//! - **A4.** A refused op changes nothing ([`Reject::AppScreenFixed`]).
//!
//! A1 is structural here; the daemon also checks that the one tab is an `app`
//! tab for the screen's own app, and that the app workspace has no other
//! screen.

use std::collections::BTreeSet;

use crate::{LayoutOpKind, LayoutState, PaneId, Reject, Screen, ScreenId, Violation};

/// The kind of a screen. `Workspace` is today's screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ScreenKind {
    #[default]
    Workspace,
    App,
}

/// What a command does at its target pane, column or screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppAction {
    /// A new or moved tab enters the target pane.
    AddTab,
    /// A new pane or row inside the target's split tree.
    Split,
    /// A new column right of the target's column.
    AddColumn,
    /// A tab leaves the target pane.
    MoveTabOut,
    /// The target tab closes.
    CloseTab,
    /// The target pane closes.
    ClosePane,
    /// The target column's dock flag changes.
    Dock,
    /// The target pane or column swaps or moves.
    Reorder,
    /// The screen's whole layout is replaced.
    ApplyLayout,
    /// The target column's width changes.
    Width,
    /// The screen closes (with its workspace).
    CloseScreen,
}

/// Why [`check_app_target`] refuses an action.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppRefusal {
    /// `app-screen-fixed`: the target is in an `App` screen.
    ScreenFixed,
}

impl AppRefusal {
    /// The reject of this refusal on `screen`.
    pub fn on(self, screen: ScreenId) -> Reject {
        match self {
            Self::ScreenFixed => Reject::AppScreenFixed(screen),
        }
    }
}

/// The one rule table: whether `action` may run at a target on a screen of
/// `kind`. An app screen allows only closing it (with its workspace).
pub fn check_app_target(kind: ScreenKind, action: AppAction) -> Result<(), AppRefusal> {
    match (kind, action) {
        (ScreenKind::Workspace, _) | (_, AppAction::Width | AppAction::CloseScreen) => Ok(()),
        (ScreenKind::App, _) => Err(AppRefusal::ScreenFixed),
    }
}

/// `pane`'s screen and its kind.
pub fn pane_target(state: &LayoutState, pane: PaneId) -> Option<(ScreenId, ScreenKind)> {
    let slot = state.slot(pane)?;
    let screen = &state.workspaces[slot.workspace].screens[slot.screen];
    Some((screen.id, screen.kind))
}

fn check_pane(state: &LayoutState, pane: PaneId, action: AppAction) -> Result<(), Reject> {
    match pane_target(state, pane) {
        Some((screen, kind)) => {
            check_app_target(kind, action).map_err(|refusal| refusal.on(screen))
        }
        None => Ok(()),
    }
}

fn check_tab(state: &LayoutState, tab: u64, action: AppAction) -> Result<(), Reject> {
    match state.pane_of(tab) {
        Some(pane) => check_pane(state, pane, action),
        None => Ok(()),
    }
}

/// [`check_app_target`] for every place a layout op touches. Unknown ids
/// pass: the op itself rejects them.
pub fn check_app_op(state: &LayoutState, op: &LayoutOpKind) -> Result<(), Reject> {
    use AppAction as A;
    match op {
        LayoutOpKind::MoveTab { tab, pane, .. } => {
            if state.pane_of(*tab) == Some(*pane) {
                return Ok(());
            }
            check_tab(state, *tab, A::MoveTabOut)?;
            check_pane(state, *pane, A::AddTab)
        }
        LayoutOpKind::MoveTabToSplit { tab, pane, .. } => {
            check_tab(state, *tab, A::MoveTabOut)?;
            check_pane(state, *pane, A::Split)
        }
        LayoutOpKind::MoveTabToColumn { tab, anchor, .. } => {
            check_tab(state, *tab, A::MoveTabOut)?;
            check_pane(state, *anchor, A::AddColumn)
        }
        LayoutOpKind::MoveTabToNewWorkspace { tab, .. } => check_tab(state, *tab, A::MoveTabOut),
        LayoutOpKind::MoveTabToWorkspace { tab, pane, .. } => {
            check_tab(state, *tab, A::MoveTabOut)?;
            pane.map_or(Ok(()), |pane| check_pane(state, pane, A::AddTab))
        }
        LayoutOpKind::InsertRow { after_pane, .. } => check_pane(state, *after_pane, A::Split),
        LayoutOpKind::MoveTabToRow { tab, anchor, .. } => {
            check_tab(state, *tab, A::MoveTabOut)?;
            check_pane(state, *anchor, A::Split)
        }
        LayoutOpKind::SetRowHeights { column, .. } | LayoutOpKind::FlattenRows { column } => {
            let pane = state.workspaces.iter().flat_map(|workspace| &workspace.screens).find_map(
                |screen| {
                    let found = screen.columns.iter().find(|candidate| candidate.id == *column)?;
                    found.panes.first().copied()
                },
            );
            pane.map_or(Ok(()), |pane| check_pane(state, pane, A::Split))
        }
        LayoutOpKind::CloseTab { tab } => check_tab(state, *tab, A::CloseTab),
        LayoutOpKind::RuntimeExited { .. } => Ok(()),
    }
}

/// A1: the structural shape of every app screen.
pub(crate) fn shape_violations(state: &LayoutState) -> BTreeSet<Violation> {
    let one_tab = |pane: &PaneId| state.panes.get(pane).is_some_and(|tabs| tabs.len() == 1);
    let lone_pane = |screen: &Screen| match screen.columns.as_slice() {
        [column] => matches!(column.panes.as_slice(), [pane] if one_tab(pane)),
        _ => false,
    };
    state
        .workspaces
        .iter()
        .flat_map(|workspace| &workspace.screens)
        .filter(|screen| screen.kind == ScreenKind::App && !lone_pane(screen))
        .map(|screen| Violation::AppScreenShape { screen: screen.id })
        .collect()
}

#[cfg(test)]
#[path = "app_screens_tests.rs"]
mod tests;
