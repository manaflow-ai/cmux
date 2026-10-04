//! A1 and A4 of the app screens: the rule table, every layout op touching an
//! app screen, and the shape check.

use super::*;
use crate::{Column, Edge, LayoutOp, TabContent, Workspace, apply, check_state};

/// Workspace 1: an `App` screen 2 (pane 3, tab 4). Workspace 14: an
/// ordinary screen 15 with two columns: pane 16 (tabs 17 and 18) and pane
/// 19 (tab 20).
fn state() -> LayoutState {
    let mut state = LayoutState::default();
    for (tab, runtime) in [(4, 40), (17, 170), (18, 180), (20, 200)] {
        state.tabs.insert(tab, TabContent { runtime, terminal: None, dead: false });
    }
    state.panes.insert(3, vec![4]);
    state.panes.insert(16, vec![17, 18]);
    state.panes.insert(19, vec![20]);
    let screen = |id, columns, columns_active, kind| Screen { id, columns, columns_active, kind };
    state.workspaces = vec![
        Workspace {
            id: 1,
            screens: vec![screen(2, vec![Column::single(0, vec![3])], false, ScreenKind::App)],
        },
        Workspace {
            id: 14,
            screens: vec![screen(
                15,
                vec![Column::single(21, vec![16]), Column::single(22, vec![19])],
                true,
                ScreenKind::Workspace,
            )],
        },
    ];
    assert!(check_state(&state).is_empty(), "{:?}", check_state(&state));
    state
}

fn run(kind: LayoutOpKind) -> Result<LayoutState, Reject> {
    let state = state();
    apply(&state, &LayoutOp { key: "k".into(), kind }).map(|(next, _)| next)
}

#[test]
fn app_rule_table_covers_every_kind_and_action() {
    use AppAction as A;
    for action in [
        A::AddTab,
        A::Split,
        A::AddColumn,
        A::MoveTabOut,
        A::CloseTab,
        A::ClosePane,
        A::Dock,
        A::Reorder,
        A::ApplyLayout,
        A::Width,
        A::CloseScreen,
    ] {
        let free = matches!(action, A::Width | A::CloseScreen);
        assert_eq!(check_app_target(ScreenKind::Workspace, action), Ok(()));
        let expected = if free { Ok(()) } else { Err(AppRefusal::ScreenFixed) };
        assert_eq!(check_app_target(ScreenKind::App, action), expected, "{action:?}");
    }
}

#[test]
fn app_screen_refuses_every_layout_op() {
    let fixed = Err(Reject::AppScreenFixed(2));
    let edge = Edge::Right;
    for kind in [
        LayoutOpKind::MoveTab { tab: 17, pane: 3, index: 0 },
        LayoutOpKind::MoveTab { tab: 4, pane: 16, index: 0 },
        LayoutOpKind::MoveTabToSplit { tab: 17, pane: 3, edge, new_pane: 90, respawn: None },
        LayoutOpKind::MoveTabToSplit { tab: 4, pane: 16, edge, new_pane: 90, respawn: None },
        LayoutOpKind::MoveTabToColumn {
            tab: 17,
            anchor: 3,
            after_column: None,
            width_permille: 500,
            new_pane: 90,
            new_column: 91,
            base_column: 92,
        },
        LayoutOpKind::MoveTabToNewWorkspace {
            tab: 4,
            index: None,
            new_workspace: 90,
            new_screen: 91,
            new_pane: 92,
        },
        LayoutOpKind::MoveTabToWorkspace {
            tab: 17,
            workspace: 1,
            pane: Some(3),
            new_screen: 90,
            new_pane: 91,
        },
        LayoutOpKind::CloseTab { tab: 4 },
    ] {
        assert_eq!(run(kind.clone()), fixed, "{kind:?}");
    }
}

#[test]
fn app_tab_in_a_workspace_screen_is_ordinary() {
    // The kind travels with the screen: tabs of screen 15 move freely.
    assert!(run(LayoutOpKind::MoveTab { tab: 17, pane: 19, index: 0 }).is_ok());
    let edge = Edge::Bottom;
    assert!(
        run(LayoutOpKind::MoveTabToSplit { tab: 17, pane: 16, edge, new_pane: 90, respawn: None })
            .is_ok()
    );
    assert!(run(LayoutOpKind::CloseTab { tab: 18 }).is_ok());
}

#[test]
fn app_screen_shape_is_an_introduced_violation() {
    let mut state = state();
    state.panes.get_mut(&3).unwrap().push(18);
    state.panes.get_mut(&16).unwrap().retain(|tab| *tab != 18);
    assert!(check_state(&state).contains(&Violation::AppScreenShape { screen: 2 }));
}
