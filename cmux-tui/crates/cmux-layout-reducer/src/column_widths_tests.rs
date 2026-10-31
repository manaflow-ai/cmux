//! R3b (Lawrence 2026-10-31, "creating new columns must never resize
//! existing columns"): every op that creates a column leaves each column
//! that existed before at its width exactly, and the new column is new
//! space at its own width.

use super::*;

const NEW: u16 = 667;

fn tab(id: TabId) -> TabContent {
    TabContent { runtime: id * 10, terminal: None, dead: false }
}

/// One workspace (1), one screen (2). `widths` empty: a split tree of two
/// panes, 3 [4] and 5 [6, 7]. Otherwise one strip column per width, column
/// `10 + i` holding pane `20 + i` with tabs `30 + i` and `40 + i`.
fn screen(widths: &[u16]) -> LayoutState {
    let mut state = LayoutState::default();
    let columns = if widths.is_empty() {
        for (pane, tabs) in [(3, vec![4]), (5, vec![6, 7])] {
            for tab_id in &tabs {
                state.tabs.insert(*tab_id, tab(*tab_id));
            }
            state.panes.insert(pane, tabs);
        }
        vec![Column::single(0, vec![3, 5])]
    } else {
        widths
            .iter()
            .enumerate()
            .map(|(index, width)| {
                let index = index as u64;
                let tabs = vec![30 + index, 40 + index];
                for tab_id in &tabs {
                    state.tabs.insert(*tab_id, tab(*tab_id));
                }
                state.panes.insert(20 + index, tabs);
                Column::sized(10 + index, vec![20 + index], *width)
            })
            .collect()
    };
    let columns_active = !widths.is_empty();
    state
        .workspaces
        .push(Workspace { id: 1, screens: vec![Screen { id: 2, columns, columns_active }] });
    state
}

fn widths(state: &LayoutState) -> Vec<(ColumnId, u16)> {
    state.workspaces[0].screens[0].columns.iter().map(|c| (c.id, c.width_permille)).collect()
}

fn insert(anchor: PaneId, before: bool) -> LayoutOpKind {
    LayoutOpKind::InsertColumn {
        anchor,
        before,
        width_permille: NEW,
        new_pane: 100,
        new_column: 101,
        base_column: 102,
        new_tab: NewTab { tab: 103, content: tab(103) },
    }
}

fn applied(state: &LayoutState, kind: LayoutOpKind) -> LayoutState {
    let anchor = kind.column_anchor().expect("a create");
    let (next, _) = apply(state, &LayoutOp { key: "k".into(), kind }).unwrap();
    let resized = resized_columns(state, &next, anchor);
    assert!(resized.is_empty(), "{resized:?}");
    next
}

#[test]
fn a_new_column_beside_the_focused_one_keeps_every_width() {
    let state = screen(&[500, 750, 300]);
    // New Column Right of the middle column, then New Column Left of it.
    let right = applied(&state, insert(21, false));
    assert_eq!(widths(&right), vec![(10, 500), (11, 750), (101, NEW), (12, 300)]);
    let left = applied(&state, insert(21, true));
    assert_eq!(widths(&left), vec![(10, 500), (101, NEW), (11, 750), (12, 300)]);
    // At either end of the strip.
    let last = applied(&state, insert(22, false));
    assert_eq!(widths(&last), vec![(10, 500), (11, 750), (12, 300), (101, NEW)]);
    let first = applied(&state, insert(20, true));
    assert_eq!(widths(&first), vec![(101, NEW), (10, 500), (11, 750), (12, 300)]);
    assert_eq!(right.panes[&100], vec![103]);
}

#[test]
fn the_first_column_beside_a_split_tree_leaves_the_tree_full_width() {
    let state = screen(&[]);
    for (anchor, before) in [(3, false), (5, false), (3, true)] {
        let next = applied(&state, insert(anchor, before));
        let expected =
            if before { vec![(101, NEW), (102, 1000)] } else { vec![(102, 1000), (101, NEW)] };
        assert_eq!(widths(&next), expected, "anchor {anchor} before {before}");
        assert!(next.workspaces[0].screens[0].columns_active);
    }
}

#[test]
fn a_tab_dropped_into_a_new_column_keeps_every_width() {
    // Between strip columns, and at the end.
    let state = screen(&[500, 750, 300]);
    let drop = |after_column| LayoutOpKind::MoveTabToColumn {
        tab: 40,
        anchor: 20,
        after_column,
        width_permille: NEW,
        new_pane: 100,
        new_column: 101,
        base_column: 102,
    };
    let between = applied(&state, drop(Some(10)));
    assert_eq!(widths(&between), vec![(10, 500), (101, NEW), (11, 750), (12, 300)]);
    let end = applied(&state, drop(None));
    assert_eq!(widths(&end), vec![(10, 500), (11, 750), (12, 300), (101, NEW)]);
    // The first column of a split screen: the tree stays full width.
    let tree = screen(&[]);
    let first = applied(
        &tree,
        LayoutOpKind::MoveTabToColumn {
            tab: 7,
            anchor: 5,
            after_column: None,
            width_permille: NEW,
            new_pane: 100,
            new_column: 101,
            base_column: 102,
        },
    );
    assert_eq!(widths(&first), vec![(102, 1000), (101, NEW)]);
}

#[test]
fn a_dragged_tab_whose_column_closes_resizes_no_other_column() {
    // Column 12's pane holds one tab; dragging it out removes that column,
    // which is not a resize.
    let mut state = screen(&[500, 750, 300]);
    state.panes.insert(22, vec![32]);
    state.tabs.remove(&42);
    let next = applied(
        &state,
        LayoutOpKind::MoveTabToColumn {
            tab: 32,
            anchor: 20,
            after_column: Some(10),
            width_permille: NEW,
            new_pane: 100,
            new_column: 101,
            base_column: 102,
        },
    );
    assert_eq!(widths(&next), vec![(10, 500), (101, NEW), (11, 750)]);
}

#[test]
fn the_check_reports_each_resized_column() {
    let before = screen(&[500, 750, 300]);
    let mut after = applied(&before, insert(21, false));
    after.workspaces[0].screens[0].columns[0].width_permille = 333;
    after.workspaces[0].screens[0].columns[1].width_permille = 500;
    assert_eq!(
        resized_columns(&before, &after, 21),
        BTreeSet::from([
            Violation::ColumnResized { column: 10, screen: 2, before: 500, after: 333 },
            Violation::ColumnResized { column: 11, screen: 2, before: 750, after: 500 },
        ])
    );
    // A split tree that became a strip column narrower than the viewport.
    let tree = screen(&[]);
    let mut shrunk = applied(&tree, insert(3, false));
    shrunk.workspaces[0].screens[0].columns[0].width_permille = 333;
    assert_eq!(
        resized_screen_columns(&tree.workspaces[0].screens[0], &shrunk.workspaces[0].screens[0]),
        vec![Violation::ColumnResized { column: 102, screen: 2, before: 1000, after: 333 }]
    );
}

#[test]
fn a_new_column_out_of_range_or_on_a_used_id_is_rejected() {
    let state = screen(&[500, 750]);
    let mut kind = insert(20, false);
    if let LayoutOpKind::InsertColumn { width_permille, .. } = &mut kind {
        *width_permille = 50;
    }
    assert_eq!(apply(&state, &LayoutOp { key: "k".into(), kind }), Err(Reject::InvalidWidth(50)));
    let mut kind = insert(20, false);
    if let LayoutOpKind::InsertColumn { new_column, .. } = &mut kind {
        *new_column = 11;
    }
    assert_eq!(apply(&state, &LayoutOp { key: "k".into(), kind }), Err(Reject::IdInUse(11)));
    assert_eq!(
        apply(&state, &LayoutOp { key: "k".into(), kind: insert(99, false) }),
        Err(Reject::UnknownPane(99))
    );
}

/// The layout fuzzer's R3b finding (feat acfd69382dc, job
/// f2f3083bac80ab71101d03ac): Cmd-N, Ctrl-` (a second terminal tab in the
/// workspace's one pane), then New Column. The old column was 872 pt and
/// became 291 pt, a third: the app's fixed width rule shrank a lone
/// full-width column to 1 - 2/3. In the model the workspace's split tree
/// stays the full-width column (1000) beside the new 2/3 column.
#[test]
fn new_column_after_a_new_workspace_and_a_terminal_keeps_the_first_column_full_width() {
    let mut state = LayoutState::default();
    state.tabs.insert(4, tab(4));
    state.tabs.insert(5, tab(5));
    state.panes.insert(3, vec![4, 5]);
    state.workspaces.push(Workspace {
        id: 1,
        screens: vec![Screen {
            id: 2,
            columns: vec![Column::single(0, vec![3])],
            columns_active: false,
        }],
    });
    let next = applied(&state, insert(3, false));
    assert_eq!(widths(&next), vec![(102, 1000), (101, NEW)]);
}

/// Only the screen that gets the new column is checked: a tab moved out of
/// another screen may close its column there, and that screen's close
/// sizing is not a create resizing a column (review of #29176).
#[test]
fn a_column_resized_on_another_screen_is_not_a_create_resize() {
    let mut state = screen(&[500, 750]);
    // A second workspace (7), screen 8, with one strip column 30 of pane 31.
    state.tabs.insert(32, tab(32));
    state.panes.insert(31, vec![32]);
    state.workspaces.push(Workspace {
        id: 7,
        screens: vec![Screen {
            id: 8,
            columns: vec![Column::sized(30, vec![31], 600), Column::sized(33, vec![34], 400)],
            columns_active: true,
        }],
    });
    state.tabs.insert(35, tab(35));
    state.panes.insert(34, vec![35]);
    let mut after = applied(&state, insert(21, false));
    // The other screen's column changed width (its close sizing in the store).
    after.workspaces[1].screens[0].columns[0].width_permille = 1000;
    assert!(resized_columns(&state, &after, 21).is_empty());
    // The same change on the anchor's screen is a create resize.
    assert!(!resized_columns(&state, &after, 31).is_empty());
}
