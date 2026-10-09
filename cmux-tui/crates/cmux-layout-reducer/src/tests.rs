//! Reducer unit tests and property tests. `PROPTEST_CASES` sets the number
//! of random op sequences (default 256).

use super::*;
use proptest::prelude::*;

/// Workspaces of screens of columns of panes, each a tab count. Ids are
/// assigned from one counter in that order, starting at 1.
fn build(layout: &[Vec<Vec<Vec<usize>>>]) -> (LayoutState, u64) {
    let mut next = 1u64;
    let mut id = || {
        let value = next;
        next += 1;
        value
    };
    let mut state = LayoutState::default();
    for screens in layout {
        let workspace = id();
        let mut built = Vec::new();
        for columns in screens {
            let screen = id();
            let columns_active = columns.len() > 1;
            let mut built_columns = Vec::new();
            for panes in columns {
                let column = if columns_active { id() } else { 0 };
                let mut built_panes = Vec::new();
                for tabs in panes {
                    let pane = id();
                    let mut pane_tabs = Vec::new();
                    for _ in 0..*tabs {
                        let tab = id();
                        state.tabs.insert(
                            tab,
                            TabContent { runtime: tab * 10, terminal: None, dead: false },
                        );
                        pane_tabs.push(tab);
                    }
                    state.panes.insert(pane, pane_tabs);
                    built_panes.push(pane);
                }
                built_columns.push(Column::single(column, built_panes));
            }
            built.push(Screen { id: screen, columns: built_columns, columns_active });
        }
        state.workspaces.push(Workspace { id: workspace, screens: built });
    }
    (state, next)
}

fn op(key: &str, kind: LayoutOpKind) -> LayoutOp {
    LayoutOp { key: key.to_string(), kind }
}

fn tabs_of(state: &LayoutState, pane: PaneId) -> Vec<TabId> {
    state.panes.get(&pane).cloned().unwrap_or_default()
}

#[test]
fn split_and_column_drops_create_a_pane_and_reject_the_own_only_tab() {
    let (state, next_id) = build(&[vec![vec![vec![2, 1]]]]);
    let split = LayoutOpKind::MoveTabToSplit {
        tab: 5,
        pane: 3,
        edge: Edge::Left,
        new_pane: next_id,
        respawn: None,
    };
    let (next, _) = apply(&state, &op("split", split)).unwrap();
    assert_eq!(next.workspaces[0].screens[0].columns[0].panes, vec![next_id, 3, 6]);
    assert_eq!(tabs_of(&next, next_id), vec![5]);

    assert_eq!(
        apply(
            &state,
            &op(
                "own",
                LayoutOpKind::MoveTabToSplit {
                    tab: 7,
                    pane: 6,
                    edge: Edge::Top,
                    new_pane: next_id,
                    respawn: None
                }
            )
        ),
        Err(Reject::OnlyTabSplitOutOfOwnPane)
    );
    assert_eq!(
        apply(
            &state,
            &op(
                "dup",
                LayoutOpKind::MoveTabToSplit {
                    tab: 5,
                    pane: 3,
                    edge: Edge::Top,
                    new_pane: 3,
                    respawn: None
                }
            )
        ),
        Err(Reject::IdInUse(3))
    );

    let column = LayoutOpKind::MoveTabToColumn {
        tab: 7,
        anchor: 3,
        after_column: None,
        width_permille: 500,
        new_pane: next_id,
        new_column: next_id + 1,
        base_column: next_id + 2,
    };
    let (next, _) = apply(&state, &op("column", column)).unwrap();
    let screen = &next.workspaces[0].screens[0];
    assert!(screen.columns_active);
    assert_eq!(
        screen.columns.iter().map(|c| (c.id, c.panes.clone())).collect::<Vec<_>>(),
        vec![(next_id + 2, vec![3]), (next_id + 1, vec![next_id])]
    );
    let unknown = LayoutOpKind::MoveTabToColumn {
        tab: 7,
        anchor: 3,
        after_column: Some(77),
        width_permille: 500,
        new_pane: next_id,
        new_column: next_id + 1,
        base_column: next_id + 2,
    };
    assert_eq!(apply(&state, &op("unknown", unknown)), Err(Reject::UnknownColumn(77)));
}

#[test]
fn checkers_report_each_broken_invariant() {
    let (state, _) = build(&[vec![vec![vec![2, 1]]]]);
    let mut lost = state.clone();
    lost.panes.get_mut(&3).unwrap().retain(|tab| *tab != 5);
    let violations = introduced_violations(&state, &lost, &BTreeSet::new());
    assert!(violations.contains(&Violation::TabWithoutPane { tab: 5 }));
    lost.tabs.remove(&5);
    assert_eq!(
        introduced_violations(&state, &lost, &BTreeSet::new()),
        BTreeSet::from([Violation::TabLost { tab: 5 }])
    );
    assert!(introduced_violations(&state, &lost, &BTreeSet::from([5])).is_empty());

    let mut twice = state.clone();
    twice.panes.get_mut(&6).unwrap().push(4);
    assert!(check_state(&twice).contains(&Violation::TabPlacedTwice { tab: 4 }));

    let mut empty = state.clone();
    empty.panes.get_mut(&6).unwrap().clear();
    empty.panes.get_mut(&3).unwrap().push(7);
    assert_eq!(check_state(&empty), BTreeSet::from([Violation::EmptyPane { pane: 6 }]));
    // A violation the state already had is not blamed on the next change.
    assert!(introduced_violations(&empty, &empty, &BTreeSet::new()).is_empty());

    let mut orphan = state.clone();
    orphan.workspaces[0].screens[0].columns[0].panes.retain(|pane| *pane != 6);
    assert!(check_state(&orphan).contains(&Violation::PaneOutsideLayout { pane: 6 }));
    let mut changed = state.clone();
    changed.tabs.get_mut(&4).unwrap().runtime = 1;
    assert_eq!(
        check_conservation(&state, &changed, &BTreeSet::new()),
        BTreeSet::from([Violation::TabContentChanged { tab: 4 }])
    );

    let (moved, _) =
        apply(&state, &op("m", LayoutOpKind::MoveTab { tab: 4, pane: 6, index: 0 })).unwrap();
    assert_eq!(
        placement_mismatches(&moved, &state),
        vec![
            PlacementMismatch::Placement {
                tab: 4,
                model: Some(Placement { workspace: 1, screen: 2, pane: 6, index: 0 }),
                live: Some(Placement { workspace: 1, screen: 2, pane: 3, index: 0 }),
            },
            PlacementMismatch::Placement {
                tab: 5,
                model: Some(Placement { workspace: 1, screen: 2, pane: 3, index: 0 }),
                live: Some(Placement { workspace: 1, screen: 2, pane: 3, index: 1 }),
            },
            PlacementMismatch::Placement {
                tab: 7,
                model: Some(Placement { workspace: 1, screen: 2, pane: 6, index: 1 }),
                live: Some(Placement { workspace: 1, screen: 2, pane: 6, index: 0 }),
            },
        ]
    );
}

/// A random op: entity picks are taken modulo the live counts, and keys come
/// from a small pool so replays and key conflicts happen.
#[derive(Debug, Clone)]
enum Step {
    MoveTab {
        tab: usize,
        pane: usize,
        index: usize,
    },
    Split {
        tab: usize,
        pane: usize,
        edge: Edge,
        respawn: bool,
    },
    Column {
        tab: usize,
        pane: usize,
        after: Option<usize>,
    },
    NewWorkspace {
        tab: usize,
        index: Option<usize>,
    },
    ToWorkspace {
        tab: usize,
        workspace: usize,
    },
    Close {
        tab: usize,
    },
    RuntimeExited {
        tab: usize,
    },
    /// Apply the previous op again with its key.
    Replay,
    /// A stale or invented id.
    Unknown {
        tab: bool,
    },
}

fn edge() -> impl Strategy<Value = Edge> {
    prop_oneof![Just(Edge::Left), Just(Edge::Right), Just(Edge::Top), Just(Edge::Bottom)]
}

fn step() -> impl Strategy<Value = Step> {
    let pick = 0..64usize;
    let index = prop_oneof![4 => 0..8usize, 1 => Just(usize::MAX)];
    prop_oneof![
        4 => (pick.clone(), pick.clone(), index)
            .prop_map(|(tab, pane, index)| Step::MoveTab { tab, pane, index }),
        3 => (pick.clone(), pick.clone(), edge(), any::<bool>())
            .prop_map(|(tab, pane, edge, respawn)| Step::Split { tab, pane, edge, respawn }),
        2 => (pick.clone(), pick.clone(), prop::option::of(pick.clone()))
            .prop_map(|(tab, pane, after)| Step::Column { tab, pane, after }),
        1 => (pick.clone(), prop::option::of(0..4usize))
            .prop_map(|(tab, index)| Step::NewWorkspace { tab, index }),
        2 => (pick.clone(), pick.clone())
            .prop_map(|(tab, workspace)| Step::ToWorkspace { tab, workspace }),
        1 => pick.clone().prop_map(|tab| Step::Close { tab }),
        1 => pick.prop_map(|tab| Step::RuntimeExited { tab }),
        1 => Just(Step::Replay),
        1 => any::<bool>().prop_map(|tab| Step::Unknown { tab }),
    ]
}

fn layout() -> impl Strategy<Value = Vec<Vec<Vec<Vec<usize>>>>> {
    let column = prop::collection::vec(1..=3usize, 1..=2);
    let screen = prop::collection::vec(column, 1..=2);
    let workspace = prop::collection::vec(screen, 1..=2);
    prop::collection::vec(workspace, 1..=3)
}

fn pick<T: Copy>(items: &[T], index: usize) -> Option<T> {
    (!items.is_empty()).then(|| items[index % items.len()])
}

/// Turn a step into an op on `state`. `None` when the layout has no tab.
fn concrete(
    state: &LayoutState,
    step: &Step,
    next_id: &mut u64,
    previous: &Option<LayoutOp>,
    key: String,
) -> Option<LayoutOp> {
    let tabs = placements(state).into_keys().collect::<Vec<_>>();
    let panes = state.panes.keys().copied().collect::<Vec<_>>();
    let workspaces = state.workspaces.iter().map(|w| w.id).collect::<Vec<_>>();
    let mut fresh = || {
        let id = *next_id;
        *next_id += 1;
        id
    };
    let tab = |index: usize| pick(&tabs, index);
    let pane = |index: usize| pick(&panes, index);
    let kind = match step {
        Step::Replay => return previous.clone(),
        Step::MoveTab { tab: t, pane: p, index } => {
            LayoutOpKind::MoveTab { tab: tab(*t)?, pane: pane(*p)?, index: *index }
        }
        Step::Split { tab: t, pane: p, edge, respawn } => {
            let tab = tab(*t)?;
            // A respawn targets the tab's own pane (the only place it is
            // valid), so the property test reaches it often.
            let pane = if *respawn { state.pane_of(tab)? } else { pane(*p)? };
            let new_pane = fresh();
            let respawn = respawn.then(|| {
                let id = fresh();
                NewTab {
                    tab: id,
                    content: TabContent { runtime: id * 10, terminal: None, dead: false },
                }
            });
            LayoutOpKind::MoveTabToSplit { tab, pane, edge: *edge, new_pane, respawn }
        }
        Step::Column { tab: t, pane: p, after } => {
            let anchor = pane(*p)?;
            let columns = state
                .workspaces
                .iter()
                .flat_map(|w| &w.screens)
                .find(|s| s.columns.iter().any(|c| c.panes.contains(&anchor)))
                .filter(|s| s.columns_active)
                .map(|s| s.columns.iter().map(|c| c.id).collect::<Vec<_>>())
                .unwrap_or_default();
            LayoutOpKind::MoveTabToColumn {
                tab: tab(*t)?,
                anchor,
                after_column: after.map(|a| pick(&columns, a).unwrap_or(u64::MAX)),
                width_permille: 500,
                new_pane: fresh(),
                new_column: fresh(),
                base_column: fresh(),
            }
        }
        Step::NewWorkspace { tab: t, index } => LayoutOpKind::MoveTabToNewWorkspace {
            tab: tab(*t)?,
            index: *index,
            new_workspace: fresh(),
            new_screen: fresh(),
            new_pane: fresh(),
        },
        Step::ToWorkspace { tab: t, workspace } => {
            let workspace = pick(&workspaces, *workspace)?;
            // Any pane of that workspace (the caller's focus choice), or a
            // pane elsewhere when the pick lands outside it.
            let pane = state
                .workspaces
                .iter()
                .find(|candidate| candidate.id == workspace)
                .and_then(|candidate| candidate.screens.first())
                .and_then(|screen| screen.columns.first())
                .and_then(|column| column.panes.get(*t % column.panes.len()))
                .copied()
                .or_else(|| pane(*t));
            LayoutOpKind::MoveTabToWorkspace {
                tab: tab(*t)?,
                workspace,
                pane,
                new_screen: fresh(),
                new_pane: fresh(),
            }
        }
        Step::Close { tab: t } => LayoutOpKind::CloseTab { tab: tab(*t)? },
        Step::RuntimeExited { tab: t } => {
            LayoutOpKind::RuntimeExited { runtime: state.tabs[&tab(*t)?].runtime }
        }
        Step::Unknown { tab: true } => LayoutOpKind::CloseTab { tab: u64::MAX },
        Step::Unknown { tab: false } => {
            LayoutOpKind::MoveTab { tab: tab(0)?, pane: u64::MAX, index: 0 }
        }
    };
    Some(LayoutOp { key, kind })
}

fn proptest_cases() -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|cases| cases.parse().ok()).unwrap_or(256)
}

proptest! {
    #![proptest_config(ProptestConfig {
        cases: proptest_cases(),
        failure_persistence: None,
        ..ProptestConfig::default()
    })]

    #[test]
    fn random_op_sequences_keep_invariants(
        layout in layout(),
        steps in prop::collection::vec((step(), 0..12u8), 1..=30),
    ) {
        let (mut state, mut next_id) = build(&layout);
        let mut ledger = Ledger::default();
        prop_assert!(check_state(&state).is_empty());
        let mut previous: Option<LayoutOp> = None;
        for (step, key) in &steps {
            let Some(op) = concrete(&state, step, &mut next_id, &previous, format!("k{key}"))
            else {
                continue;
            };
            let replayed = ledger.get(&op.key).is_some();
            match apply_once(&state, &ledger, &op) {
                Ok((next, next_ledger, events)) => {
                    // I1-I3 hold absolutely: every generated layout starts clean.
                    prop_assert!(check_state(&next).is_empty(), "{:?}", check_state(&next));
                    // I1: only the op's explicit creations appear (none on a replay).
                    let created = if replayed { BTreeSet::new() } else { op.kind.created_tabs() };
                    let conservation =
                        check_conservation_creating(&state, &next, &op.kind.closed_tabs(), &created);
                    prop_assert!(conservation.is_empty(), "{conservation:?}");
                    // A respawning split keeps the source pane, holding the fresh tab.
                    if let (false, LayoutOpKind::MoveTabToSplit { pane, respawn: Some(respawn), .. }) = (replayed, &op.kind) {
                        prop_assert_eq!(next.panes.get(pane), Some(&vec![respawn.tab]));
                    }
                    // I5: a replay changes nothing and reports nothing.
                    if replayed {
                        prop_assert_eq!(&next, &state);
                        prop_assert!(events.is_empty());
                    }
                    let (again, _, again_events) = apply_once(&next, &next_ledger, &op).unwrap();
                    prop_assert_eq!(&again, &next);
                    prop_assert!(again_events.is_empty());
                    // A runtime's death changes no tab set, pane or workspace.
                    if matches!(op.kind, LayoutOpKind::RuntimeExited { .. }) {
                        prop_assert_eq!(&next.panes, &state.panes);
                        prop_assert_eq!(&next.workspaces, &state.workspaces);
                        prop_assert_eq!(
                            next.tabs.keys().collect::<Vec<_>>(),
                            state.tabs.keys().collect::<Vec<_>>()
                        );
                    }
                    state = next;
                    ledger = next_ledger;
                    previous = Some(op);
                }
                Err(Reject::Invariant(violations)) => {
                    prop_assert!(false, "the reducer produced a broken state: {violations:?}");
                }
                // `apply_once` borrows the state, so a rejection cannot
                // change it.
                Err(_) => {}
            }
        }
    }
}
