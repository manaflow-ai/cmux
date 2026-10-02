//! Row ops (plans/cmux-next/rows.md): unit tests and a property test that
//! mixes them with moves and closes. `PROPTEST_CASES` sets the case count.

use super::*;
use proptest::prelude::*;

/// One workspace (1), one screen (2), columns of panes with one tab each.
/// Ids: column ids from 10, panes from 100, tabs from 1000.
fn columns(layout: &[usize]) -> LayoutState {
    let mut state = LayoutState::default();
    let mut built = Vec::new();
    let (mut pane, mut tab) = (100, 1000);
    for (index, count) in layout.iter().enumerate() {
        let mut panes = Vec::new();
        for _ in 0..*count {
            state.panes.insert(pane, vec![tab]);
            state.tabs.insert(tab, TabContent { runtime: tab, terminal: None, dead: false });
            panes.push(pane);
            pane += 1;
            tab += 1;
        }
        built.push(Column::single(if layout.len() > 1 { 10 + index as u64 } else { 0 }, panes));
    }
    let screen = Screen { id: 2, columns: built, columns_active: layout.len() > 1 };
    state.workspaces.push(Workspace { id: 1, screens: vec![screen] });
    state
}

fn op(key: &str, kind: LayoutOpKind) -> LayoutOp {
    LayoutOp { key: key.to_string(), kind }
}

fn new_tab(tab: TabId) -> NewTab {
    NewTab { tab, content: TabContent { runtime: tab, terminal: None, dead: false } }
}

fn insert_row(after: PaneId, new_row: RowId, new_pane: PaneId, tab: TabId) -> LayoutOpKind {
    LayoutOpKind::InsertRow {
        after_pane: after,
        height_permille: 1000,
        new_row,
        new_pane,
        new_tab: new_tab(tab),
        base_column: 50,
        base_row: 60,
    }
}

fn column(state: &LayoutState, index: usize) -> &Column {
    &state.workspaces[0].screens[0].columns[index]
}

#[test]
fn insert_row_opens_columns_mode_and_an_explicit_base_row() {
    let state = columns(&[2]);
    let (next, events) = apply(&state, &op("a", insert_row(100, 70, 200, 2000))).unwrap();
    let c = column(&next, 0);
    assert!(next.workspaces[0].screens[0].columns_active);
    assert_eq!(c.id, 50);
    assert_eq!(c.panes, vec![100, 101, 200]);
    assert_eq!(c.rows.iter().map(|r| (r.id, r.len)).collect::<Vec<_>>(), vec![(60, 2), (70, 1)]);
    assert_eq!(next.panes[&200], vec![2000]);
    assert!(events.contains(&LayoutEvent::RowCreated { row: 70, column: 50, index: 1 }));
    assert!(events.contains(&LayoutEvent::TabCreated { tab: 2000, pane: 200 }));
}

#[test]
fn insert_row_rejects_bad_heights_and_used_ids() {
    let state = columns(&[1, 1]);
    let mut bad = insert_row(100, 70, 200, 2000);
    if let LayoutOpKind::InsertRow { height_permille, .. } = &mut bad {
        *height_permille = 99;
    }
    assert_eq!(apply(&state, &op("a", bad)), Err(Reject::InvalidHeight(99)));
    assert_eq!(apply(&state, &op("b", insert_row(100, 70, 101, 2000))), Err(Reject::IdInUse(101)));
}

#[test]
fn closing_a_rows_last_pane_removes_the_row_and_one_row_goes_implicit() {
    let state = columns(&[1, 1]);
    let (state, _) = apply(&state, &op("a", insert_row(100, 70, 200, 2000))).unwrap();
    let (next, events) = apply(&state, &op("b", LayoutOpKind::CloseTab { tab: 2000 })).unwrap();
    assert!(column(&next, 0).rows.is_empty());
    assert!(events.contains(&LayoutEvent::RowRemoved { row: 70 }));
    assert!(events.contains(&LayoutEvent::RowRemoved { row: 60 }));
    assert!(check_state(&next).is_empty());
}

#[test]
fn split_inside_a_row_grows_only_that_row() {
    let state = columns(&[1, 1]);
    let (state, _) = apply(&state, &op("a", insert_row(100, 70, 200, 2000))).unwrap();
    let split = LayoutOpKind::MoveTabToSplit {
        tab: 1001,
        pane: 200,
        edge: Edge::Bottom,
        new_pane: 300,
        respawn: None,
    };
    let (next, _) = apply(&state, &op("b", split)).unwrap();
    assert_eq!(column(&next, 0).panes, vec![100, 200, 300]);
    assert_eq!(column(&next, 0).rows.iter().map(|r| r.len).collect::<Vec<_>>(), vec![1, 2]);
}

fn to_row(
    tab: TabId,
    anchor: PaneId,
    before: bool,
    height: u16,
    respawn: Option<NewTab>,
) -> LayoutOpKind {
    LayoutOpKind::MoveTabToRow {
        tab,
        anchor,
        before,
        height_permille: height,
        new_row: 70,
        new_pane: 200,
        base_column: 50,
        base_row: 60,
        respawn,
    }
}

#[test]
fn moving_a_lone_tab_onto_its_own_rows_boundary_is_a_no_op() {
    let state = columns(&[1, 1]);
    for before in [false, true] {
        let (next, events) =
            apply(&state, &op("a", to_row(1000, 100, before, 1000, None))).unwrap();
        assert_eq!(next, state);
        assert!(events.is_empty());
    }
    // Another height is a real change.
    let (next, _) = apply(&state, &op("b", to_row(1000, 100, false, 500, None))).unwrap();
    assert_ne!(next, state);
}

#[test]
fn moving_a_tab_into_a_new_row_of_another_column() {
    let state = columns(&[2, 1]);
    let (next, _) = apply(&state, &op("a", to_row(1000, 102, true, 400, None))).unwrap();
    assert_eq!(column(&next, 0).panes, vec![101]);
    assert_eq!(column(&next, 1).panes, vec![200, 102]);
    assert_eq!(
        column(&next, 1).rows.iter().map(|r| (r.id, r.height_permille)).collect::<Vec<_>>(),
        vec![(70, 400), (60, 1000)]
    );
    assert_eq!(next.panes[&200], vec![1000]);
}

#[test]
fn respawn_keeps_a_new_tab_in_the_source_and_is_never_a_no_op() {
    let state = columns(&[1, 1]);
    let (next, _) =
        apply(&state, &op("a", to_row(1000, 100, false, 1000, Some(new_tab(2000))))).unwrap();
    assert_eq!(next.panes[&100], vec![2000]);
    assert_eq!(next.panes[&200], vec![1000]);
    let shared = columns(&[1, 1]);
    let (shared, _) =
        apply(&shared, &op("b", LayoutOpKind::MoveTab { tab: 1001, pane: 100, index: 1 })).unwrap();
    assert_eq!(
        apply(&shared, &op("c", to_row(1000, 100, false, 1000, Some(new_tab(2000))))),
        Err(Reject::RespawnNotNeeded)
    );
}

#[test]
fn set_row_heights_needs_the_exact_row_set_and_fit_sums_to_1000() {
    let state = columns(&[1, 1]);
    let (state, _) = apply(&state, &op("a", insert_row(100, 70, 200, 2000))).unwrap();
    let stale = LayoutOpKind::SetRowHeights { column: 10, heights: vec![(60, 500)], fit: false };
    assert_eq!(apply(&state, &op("b", stale)), Err(Reject::RowSetMismatch(10)));
    let unfit =
        LayoutOpKind::SetRowHeights { column: 10, heights: vec![(60, 500), (70, 400)], fit: true };
    assert_eq!(apply(&state, &op("c", unfit)), Err(Reject::FitSum(900)));
    let fit =
        LayoutOpKind::SetRowHeights { column: 10, heights: vec![(60, 600), (70, 400)], fit: true };
    let (next, events) = apply(&state, &op("d", fit)).unwrap();
    assert_eq!(events, vec![LayoutEvent::RowsResized { column: 10 }]);
    assert_eq!(
        column(&next, 0).rows.iter().map(|r| r.height_permille).collect::<Vec<_>>(),
        vec![600, 400]
    );
}

#[test]
fn flatten_rows_keeps_every_pane_and_tab() {
    let state = columns(&[1, 1]);
    let (state, _) = apply(&state, &op("a", insert_row(100, 70, 200, 2000))).unwrap();
    let (next, events) = apply(&state, &op("b", LayoutOpKind::FlattenRows { column: 10 })).unwrap();
    assert!(column(&next, 0).rows.is_empty());
    assert_eq!(column(&next, 0).panes, vec![100, 200]);
    assert_eq!(next.tabs, state.tabs);
    assert_eq!(events.len(), 2);
}

#[test]
fn a_row_id_is_never_reused() {
    let state = columns(&[1, 1]);
    let (state, _) = apply(&state, &op("a", insert_row(100, 70, 200, 2000))).unwrap();
    assert_eq!(apply(&state, &op("b", insert_row(101, 70, 201, 2001))), Err(Reject::IdInUse(70)));
}

#[test]
fn the_checker_reports_a_broken_partition() {
    let mut state = columns(&[2, 1]);
    state.workspaces[0].screens[0].columns[0].rows =
        vec![Row { id: 70, height_permille: 1000, len: 2 }];
    assert!(check_state(&state).contains(&Violation::RowLayout { column: 10 }));
}

#[derive(Debug, Clone)]
enum Step {
    Insert { after: usize, height: u16 },
    ToRow { tab: usize, anchor: usize, before: bool, height: u16, respawn: bool },
    Heights { column: usize, height: u16, fit: bool },
    Flatten { column: usize },
    Split { tab: usize, pane: usize },
    Move { tab: usize, pane: usize },
    Close { tab: usize },
}

fn step() -> impl Strategy<Value = Step> {
    prop_oneof![
        (any::<usize>(), 90u16..=1010).prop_map(|(after, height)| Step::Insert { after, height }),
        (any::<usize>(), any::<usize>(), any::<bool>(), 90u16..=1010, any::<bool>()).prop_map(
            |(tab, anchor, before, height, respawn)| Step::ToRow {
                tab,
                anchor,
                before,
                height,
                respawn
            }
        ),
        (any::<usize>(), 90u16..=1010, any::<bool>())
            .prop_map(|(column, height, fit)| Step::Heights { column, height, fit }),
        any::<usize>().prop_map(|column| Step::Flatten { column }),
        (any::<usize>(), any::<usize>()).prop_map(|(tab, pane)| Step::Split { tab, pane }),
        (any::<usize>(), any::<usize>()).prop_map(|(tab, pane)| Step::Move { tab, pane }),
        any::<usize>().prop_map(|tab| Step::Close { tab }),
    ]
}

fn pick<T: Copy>(items: &[T], index: usize) -> Option<T> {
    (!items.is_empty()).then(|| items[index % items.len()])
}

/// A concrete op for `step` against `state`, with ids from `next`.
fn concrete(state: &LayoutState, step: &Step, next: &mut u64) -> Option<LayoutOpKind> {
    let mut fresh = || {
        *next += 1;
        *next
    };
    let tabs: Vec<TabId> = state.tabs.keys().copied().collect();
    let panes: Vec<PaneId> = state.panes.keys().copied().collect();
    let columns: Vec<&Column> =
        state.workspaces.iter().flat_map(|w| &w.screens).flat_map(|s| &s.columns).collect();
    Some(match step {
        Step::Insert { after, height } => LayoutOpKind::InsertRow {
            after_pane: pick(&panes, *after)?,
            height_permille: *height,
            new_row: fresh(),
            new_pane: fresh(),
            new_tab: new_tab(fresh()),
            base_column: fresh(),
            base_row: fresh(),
        },
        Step::ToRow { tab, anchor, before, height, respawn } => LayoutOpKind::MoveTabToRow {
            tab: pick(&tabs, *tab)?,
            anchor: pick(&panes, *anchor)?,
            before: *before,
            height_permille: *height,
            new_row: fresh(),
            new_pane: fresh(),
            base_column: fresh(),
            base_row: fresh(),
            respawn: respawn.then(|| new_tab(fresh())),
        },
        Step::Heights { column, height, fit } => {
            let c = pick(&columns, *column)?;
            let heights = c.rows.iter().map(|row| (row.id, *height)).collect();
            LayoutOpKind::SetRowHeights { column: c.id, heights, fit: *fit }
        }
        Step::Flatten { column } => {
            LayoutOpKind::FlattenRows { column: pick(&columns, *column)?.id }
        }
        Step::Split { tab, pane } => LayoutOpKind::MoveTabToSplit {
            tab: pick(&tabs, *tab)?,
            pane: pick(&panes, *pane)?,
            edge: Edge::Bottom,
            new_pane: fresh(),
            respawn: None,
        },
        Step::Move { tab, pane } => {
            LayoutOpKind::MoveTab { tab: pick(&tabs, *tab)?, pane: pick(&panes, *pane)?, index: 0 }
        }
        Step::Close { tab } => LayoutOpKind::CloseTab { tab: pick(&tabs, *tab)? },
    })
}

fn cases() -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|value| value.parse().ok()).unwrap_or(256)
}

proptest! {
    #![proptest_config(ProptestConfig { cases: cases(), ..ProptestConfig::default() })]

    /// Row ops mixed with splits, moves and closes: no op result ever breaks
    /// I1-I3 or R1/R2/R4 (the reducer would reject it with
    /// `Reject::Invariant`), a rejected op changes nothing, only explicit
    /// creations add tabs, and a replayed key changes nothing.
    #[test]
    fn row_ops_keep_every_invariant(layout in proptest::collection::vec(1usize..=3, 1..=3), steps in proptest::collection::vec(step(), 1..30)) {
        let mut state = columns(&layout);
        let mut ledger = Ledger::default();
        let mut next = 10_000;
        for (index, step) in steps.iter().enumerate() {
            let Some(kind) = concrete(&state, step, &mut next) else { continue };
            let key = format!("k{index}");
            match apply_once(&state, &ledger, &op(&key, kind.clone())) {
                Ok((after, ledger_after, _)) => {
                    prop_assert!(check_state(&after).is_empty(), "{:?} broke {:?}", kind, check_state(&after));
                    prop_assert!(check_conservation_creating(&state, &after, &kind.closed_tabs(), &kind.created_tabs()).is_empty());
                    let (replayed, _, events) = apply_once(&after, &ledger_after, &op(&key, kind.clone())).unwrap();
                    prop_assert_eq!(&replayed, &after);
                    prop_assert!(events.is_empty());
                    state = after;
                    ledger = ledger_after;
                }
                Err(Reject::Invariant(violations)) => prop_assert!(false, "{:?} produced {:?}", kind, violations),
                Err(_) => {}
            }
        }
    }
}
