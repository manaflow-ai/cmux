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
fn move_tab_reorders_moves_and_collapses_the_emptied_pane() {
    // Workspace 1, screen 2, one tree column: pane 3 [4, 5], pane 6 [7].
    let (state, _) = build(&[vec![vec![vec![2, 1]]]]);
    assert!(check_state(&state).is_empty());

    // Own position: both insertion indexes around the tab are no-ops.
    for index in [1, 2] {
        let (next, events) =
            apply(&state, &op("own", LayoutOpKind::MoveTab { tab: 5, pane: 3, index })).unwrap();
        assert!(events.is_empty());
        assert_eq!(next.panes, state.panes);
    }
    let (next, _) =
        apply(&state, &op("front", LayoutOpKind::MoveTab { tab: 5, pane: 3, index: 0 })).unwrap();
    assert_eq!(tabs_of(&next, 3), vec![5, 4]);

    // Moving pane 6's only tab removes pane 6.
    let (next, events) =
        apply(&state, &op("in", LayoutOpKind::MoveTab { tab: 7, pane: 3, index: 1 })).unwrap();
    assert_eq!(tabs_of(&next, 3), vec![4, 7, 5]);
    assert!(!next.panes.contains_key(&6));
    assert!(events.contains(&LayoutEvent::PaneRemoved { pane: 6 }));
    assert_eq!(next.workspaces[0].screens[0].columns[0].panes, vec![3]);

    assert_eq!(
        apply(&state, &op("x", LayoutOpKind::MoveTab { tab: 99, pane: 3, index: 0 })),
        Err(Reject::UnknownTab(99))
    );
    assert_eq!(
        apply(&state, &op("x", LayoutOpKind::MoveTab { tab: 4, pane: 99, index: 0 })),
        Err(Reject::UnknownPane(99))
    );
}

/// User requirement 2026-10-02: a pane's only tab dropped on one of its own
/// pane's edges splits the pane, and a fresh tab of the same kind takes its
/// place (the respawn, created by the same op).
#[test]
fn a_split_with_respawn_moves_the_only_tab_and_keeps_a_fresh_one() {
    let (state, next_id) = build(&[vec![vec![vec![2, 1]]]]);
    let fresh = NewTab {
        tab: next_id + 1,
        content: TabContent { runtime: 999, terminal: None, dead: false },
    };
    let split = LayoutOpKind::MoveTabToSplit {
        tab: 7,
        pane: 6,
        edge: Edge::Right,
        new_pane: next_id,
        respawn: Some(fresh.clone()),
    };
    let (next, events) = apply(&state, &op("respawn", split.clone())).unwrap();
    assert_eq!(tabs_of(&next, 6), vec![next_id + 1]);
    assert_eq!(tabs_of(&next, next_id), vec![7]);
    assert_eq!(next.workspaces[0].screens[0].columns[0].panes, vec![3, 6, next_id]);
    assert_eq!(next.tabs[&(next_id + 1)], fresh.content);
    assert!(events.contains(&LayoutEvent::TabCreated { tab: next_id + 1, pane: 6 }));
    assert_eq!(split.created_tabs(), BTreeSet::from([next_id + 1]));

    // A respawn is only for the pane's only tab, split out of its own pane.
    let not_alone = LayoutOpKind::MoveTabToSplit {
        tab: 4,
        pane: 3,
        edge: Edge::Left,
        new_pane: next_id,
        respawn: Some(fresh.clone()),
    };
    assert_eq!(apply(&state, &op("x", not_alone)), Err(Reject::RespawnNotNeeded));
    let other_pane = LayoutOpKind::MoveTabToSplit {
        tab: 7,
        pane: 3,
        edge: Edge::Left,
        new_pane: next_id,
        respawn: Some(fresh.clone()),
    };
    assert_eq!(apply(&state, &op("y", other_pane)), Err(Reject::RespawnNotNeeded));
    // The fresh tab's id must be unused.
    let reused = LayoutOpKind::MoveTabToSplit {
        tab: 7,
        pane: 6,
        edge: Edge::Left,
        new_pane: next_id,
        respawn: Some(NewTab { tab: 4, content: fresh.content }),
    };
    assert_eq!(apply(&state, &op("z", reused)), Err(Reject::IdInUse(4)));
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
fn workspace_moves_and_close_keep_every_other_tab() {
    // Workspace 1 (screen 2: pane 3 [4, 5]); workspace 6 (screen 7: pane 8 [9]).
    let (state, next_id) = build(&[vec![vec![vec![2]]], vec![vec![vec![1]]]]);
    let tear = LayoutOpKind::MoveTabToNewWorkspace {
        tab: 9,
        index: Some(0),
        new_workspace: next_id,
        new_screen: next_id + 1,
        new_pane: next_id + 2,
    };
    let (next, _) = apply(&state, &op("tear", tear)).unwrap();
    assert_eq!(next.workspaces[0].id, next_id);
    // The source workspace keeps no screen; the model does not close it.
    assert!(next.workspaces[2].screens.is_empty());
    let back = LayoutOpKind::MoveTabToWorkspace {
        tab: 4,
        workspace: 6,
        pane: None,
        new_screen: next_id + 3,
        new_pane: next_id + 4,
    };
    let (back_state, _) = apply(&next, &op("back", back)).unwrap();
    assert_eq!(tabs_of(&back_state, next_id + 4), vec![4]);
    let to_existing = |pane| LayoutOpKind::MoveTabToWorkspace {
        tab: 5,
        workspace: next_id,
        pane,
        new_screen: 0,
        new_pane: 0,
    };
    let (joined, _) = apply(&next, &op("join", to_existing(Some(next_id + 2)))).unwrap();
    assert_eq!(tabs_of(&joined, next_id + 2), vec![9, 5]);
    // A workspace with screens needs a destination pane inside it.
    for pane in [None, Some(3)] {
        assert_eq!(
            apply(&next, &op("join", to_existing(pane))),
            Err(Reject::PaneNotInWorkspace { pane, workspace: next_id })
        );
    }

    let (closed, events) = apply(&state, &op("close", LayoutOpKind::CloseTab { tab: 9 })).unwrap();
    assert!(!closed.tabs.contains_key(&9));
    assert!(closed.workspaces[1].screens.is_empty());
    assert!(events.contains(&LayoutEvent::ScreenRemoved { screen: 7 }));
}

#[test]
fn replays_have_no_effect_and_conflicting_keys_are_rejected() {
    let (state, _) = build(&[vec![vec![vec![2, 1]]]]);
    let kind = LayoutOpKind::MoveTab { tab: 7, pane: 3, index: 0 };
    let (once, ledger, events) =
        apply_once(&state, &Ledger::default(), &op("k", kind.clone())).unwrap();
    assert!(!events.is_empty());
    let (twice, ledger_twice, events) = apply_once(&once, &ledger, &op("k", kind)).unwrap();
    assert!(events.is_empty());
    assert_eq!(twice, once);
    assert_eq!(ledger_twice, ledger);
    assert_eq!(
        apply_once(&once, &ledger, &op("k", LayoutOpKind::CloseTab { tab: 4 })),
        Err(Reject::IdempotencyConflict("k".to_string()))
    );
}

#[test]
fn runtime_exit_marks_tabs_dead_and_keeps_the_layout() {
    let (state, _) = build(&[vec![vec![vec![1]]]]);
    // Tab 4 has runtime 40.
    let (next, events) =
        apply(&state, &op("exit", LayoutOpKind::RuntimeExited { runtime: 40 })).unwrap();
    assert_eq!(events, vec![LayoutEvent::TabDied { tab: 4 }]);
    assert!(next.tabs[&4].dead);
    assert_eq!(next.panes, state.panes);
    assert_eq!(next.workspaces, state.workspaces);
    let (unknown, events) =
        apply(&state, &op("exit", LayoutOpKind::RuntimeExited { runtime: 1 })).unwrap();
    assert!(events.is_empty());
    assert_eq!(unknown, state);
    let invalid = LayoutOpKind::MoveTabToColumn {
        tab: 4,
        anchor: 3,
        after_column: None,
        width_permille: 99,
        new_pane: 10,
        new_column: 11,
        base_column: 12,
    };
    assert_eq!(apply(&state, &op("w", invalid)), Err(Reject::InvalidWidth(99)));
}

/// User decision 2026-10-02: a dead tab restarts in place. The tab keeps its
/// id and placement and shows the new content; a live tab is rejected, and
/// so is a restart to dead content; a replay with the key is a no-op.
#[test]
fn restart_gives_a_dead_tab_new_content_in_place() {
    let (state, _) = build(&[vec![vec![vec![2]]]]);
    let fresh = TabContent { runtime: 99, terminal: Some("term_new".into()), dead: false };
    let restart = LayoutOpKind::RestartTab { tab: 4, content: fresh.clone() };
    assert_eq!(apply(&state, &op("r", restart.clone())), Err(Reject::TabNotDead(4)));

    let (dead, _) =
        apply(&state, &op("exit", LayoutOpKind::RuntimeExited { runtime: 40 })).unwrap();
    let (restarted, events) = apply(&dead, &op("r", restart.clone())).unwrap();
    assert_eq!(events, vec![LayoutEvent::TabRestarted { tab: 4 }]);
    assert_eq!(restarted.tabs[&4], fresh);
    assert_eq!(restarted.panes, dead.panes);
    assert_eq!(placements(&restarted), placements(&dead));
    assert_eq!(restarted.tabs[&5], dead.tabs[&5]);
    assert!(introduced_violations_for(&dead, &restarted, &restart).is_empty());
    // Without the op's restart allowance the same change is a content change.
    assert_eq!(
        check_conservation(&dead, &restarted, &BTreeSet::new()),
        BTreeSet::from([Violation::TabContentChanged { tab: 4 }])
    );

    let mut dead_content = fresh.clone();
    dead_content.dead = true;
    assert_eq!(
        apply(&dead, &op("d", LayoutOpKind::RestartTab { tab: 4, content: dead_content })),
        Err(Reject::RestartContentDead(4))
    );
    assert_eq!(
        apply(&dead, &op("u", LayoutOpKind::RestartTab { tab: 77, content: fresh.clone() })),
        Err(Reject::UnknownTab(77))
    );

    // A kept tab whose runtime is gone has no content; a restart gives it some.
    let mut kept = dead.clone();
    kept.tabs.remove(&4);
    let (from_kept, _) = apply(&kept, &op("k", restart.clone())).unwrap();
    assert_eq!(from_kept.tabs[&4], fresh);
    assert!(check_state(&from_kept).is_empty());

    // I5: the same key replays.
    let (once, ledger, _) =
        apply_once(&dead, &Ledger::default(), &op("r", restart.clone())).unwrap();
    assert_eq!(
        apply_once(&once, &ledger, &op("r", restart)),
        Ok((once.clone(), ledger, Vec::new()))
    );
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
    Restart {
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
        1 => pick.clone().prop_map(|tab| Step::RuntimeExited { tab }),
        1 => pick.prop_map(|tab| Step::Restart { tab }),
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
        Step::Restart { tab: t } => {
            let id = fresh();
            LayoutOpKind::RestartTab {
                tab: tab(*t)?,
                content: TabContent { runtime: id * 10, terminal: None, dead: false },
            }
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
                    let restarted =
                        if replayed { BTreeSet::new() } else { op.kind.restarted_tabs() };
                    let conservation = check_conservation_restarting(
                        &state,
                        &next,
                        &op.kind.closed_tabs(),
                        &created,
                        &restarted,
                    );
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
                    // A restart keeps the tab set and every placement and
                    // changes only the restarted tab, which was dead.
                    if let (false, LayoutOpKind::RestartTab { tab, content }) = (replayed, &op.kind) {
                        prop_assert!(state.tabs[tab].dead);
                        prop_assert_eq!(&next.tabs[tab], content);
                        prop_assert_eq!(placements(&next), placements(&state));
                        prop_assert_eq!(
                            next.tabs.keys().collect::<Vec<_>>(),
                            state.tabs.keys().collect::<Vec<_>>()
                        );
                    }
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
