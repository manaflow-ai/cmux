//! Kani proof harnesses (`cargo kani -p cmux-layout-reducer`).
//!
//! STATUS (Kani 0.68.0, 2026-10-02): NOT FEASIBLE. No harness here finishes.
//! Even `one_tab::runtime_exit_changes_no_placement` (one tab, one pane, a
//! concrete layout) timed out at 7 minutes with unwind 8 and at 8 minutes
//! with unwind 3 on a 32 vCPU Testbox. Symbolic execution cannot refute
//! the internal-node paths of `BTreeMap` and `BTreeSet` (`LayoutState`,
//! `check_state`'s violation set, `placements`), so every insert unrolls
//! node splitting and parent-link loops. Proving these properties needs
//! a reducer state without B-trees (for example sorted `Vec`s) or a later
//! Kani. Until then the exhaustive check in `exhaustive_tests.rs` (every
//! layout within these bounds) and the proptest in `tests.rs` are the
//! evidence.
//!
//! Each harness fixes one layout shape (workspaces, screens, columns,
//! panes and tab counts), makes every tab's content symbolic, applies one
//! op whose kind and arguments are symbolic, and proves the invariants of
//! plans/cmux-next/OWNERSHIP-PRINCIPLES.md for that step. Kani also proves
//! that the step never panics (no failed `expect`, bad index or overflow),
//! and its unwinding assertions prove the loop bounds cover every path.
//!
//! Why shapes are fixed: a generator that also makes the shape symbolic
//! (which panes exist, which pane holds which tab) puts symbolic keys into
//! every `BTreeMap` operation, and Kani did not finish symbolic execution
//! of a single such harness in 20 minutes (3 tabs, 3 panes, 2 workspaces).
//! With the shape fixed, map structure stays concrete and the op is fully
//! symbolic. The shapes cover a single tab, tab strips, tree splits, scrolling
//! columns, two workspaces, and a workspace without screens; the proptest
//! in `tests.rs` covers larger random states and op sequences.
//!
//! Op arguments that name existing entities range over every id of the
//! shape plus one unknown id. Ids for new entities are fresh; the separate
//! `in_use_ids_keep_invariants` harnesses make one of them range over every
//! id in use. Tab content identity is the symbolic `runtime`;
//! `terminal` stays `None`.

use super::*;

/// Workspaces of screens of columns of panes, each a tab count. Ids come
/// from one counter in that order, starting at 1, like the daemon's. A
/// screen with more than one column has scrolling columns. Returns the state and
/// the first unused id.
fn shape(layout: &[&[&[&[usize]]]]) -> (LayoutState, u64) {
    let mut next = 1u64;
    let mut state = LayoutState::default();
    for screens in layout {
        let workspace = next;
        next += 1;
        let mut built = Vec::new();
        for columns in screens.iter() {
            let screen = next;
            next += 1;
            let columns_active = columns.len() > 1;
            let mut built_columns = Vec::new();
            for panes in columns.iter() {
                let column = if columns_active {
                    next += 1;
                    next - 1
                } else {
                    0
                };
                let mut built_panes = Vec::new();
                for tabs in panes.iter() {
                    let pane = next;
                    next += 1;
                    let mut pane_tabs = Vec::new();
                    for _ in 0..*tabs {
                        let tab = next;
                        next += 1;
                        let runtime = kani::any_where(|value: &u64| *value <= 1);
                        state
                            .tabs
                            .insert(tab, TabContent { runtime, terminal: None, dead: kani::any() });
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

fn any_below(bound: usize) -> usize {
    kani::any_where(|value: &usize| *value < bound)
}

/// Any id of the shape, or the unknown id `next`.
fn any_known(next: u64) -> u64 {
    kani::any_where(|value: &u64| *value <= next)
}

fn any_edge() -> Edge {
    match any_below(4) {
        0 => Edge::Left,
        1 => Edge::Right,
        2 => Edge::Top,
        _ => Edge::Bottom,
    }
}

fn any_option(next: u64) -> Option<u64> {
    if kani::any() { Some(any_known(next)) } else { None }
}

/// Any op on a shape whose first unused id is `next`. New entities get the
/// ids `fresh[0..3]`.
fn any_kind(next: u64, fresh: [u64; 3]) -> LayoutOpKind {
    match any_below(7) {
        0 => LayoutOpKind::MoveTab {
            tab: any_known(next),
            pane: any_known(next),
            index: any_below(4),
        },
        1 => LayoutOpKind::MoveTabToSplit {
            tab: any_known(next),
            pane: any_known(next),
            edge: any_edge(),
            new_pane: fresh[0],
            respawn: None,
        },
        2 => LayoutOpKind::MoveTabToColumn {
            tab: any_known(next),
            anchor: any_known(next),
            after_column: any_option(next),
            width_permille: kani::any(),
            new_pane: fresh[0],
            new_column: fresh[1],
            base_column: fresh[2],
        },
        3 => LayoutOpKind::MoveTabToNewWorkspace {
            tab: any_known(next),
            index: if kani::any() { Some(any_below(3)) } else { None },
            new_workspace: fresh[0],
            new_screen: fresh[1],
            new_pane: fresh[2],
        },
        4 => LayoutOpKind::MoveTabToWorkspace {
            tab: any_known(next),
            workspace: any_known(next),
            pane: any_option(next),
            new_screen: fresh[0],
            new_pane: fresh[1],
        },
        5 => LayoutOpKind::CloseTab { tab: any_known(next) },
        _ => LayoutOpKind::RuntimeExited { runtime: kani::any_where(|value: &u64| *value <= 2) },
    }
}

fn keyed(kind: LayoutOpKind) -> LayoutOp {
    LayoutOp { key: String::from("k"), kind }
}

/// I1, I2 and I3 for any op on `state`, and that the reducer never needs
/// its own invariant check: a valid state and any op give `Ok` or a
/// precondition reject, never [`Reject::Invariant`].
fn check_step(state: &LayoutState, next: u64, fresh: [u64; 3]) {
    assert!(check_state(state).is_empty());
    let op = keyed(any_kind(next, fresh));
    match apply(state, &op) {
        Ok((after, _)) => {
            // I2 and I3 on the result.
            assert!(check_state(&after).is_empty());
            // I1, stated without the crate's checker.
            match op.kind {
                LayoutOpKind::CloseTab { tab } => {
                    assert!(state.tabs.contains_key(&tab));
                    assert!(!after.tabs.contains_key(&tab));
                    assert_eq!(after.tabs.len() + 1, state.tabs.len());
                    for (id, content) in &after.tabs {
                        assert_eq!(state.tabs.get(id), Some(content));
                    }
                }
                LayoutOpKind::RuntimeExited { .. } => {
                    assert_eq!(after.tabs.len(), state.tabs.len());
                    for (id, content) in &after.tabs {
                        assert!(state.tabs.get(id).is_some_and(|old| old.same_identity(content)));
                    }
                }
                _ => assert_eq!(after.tabs, state.tabs),
            }
        }
        Err(reject) => assert!(!matches!(reject, Reject::Invariant(_))),
    }
}

/// [`check_step`] where one id for a new entity is already in use, so the
/// reducer's fresh-id checks are on the proved paths too.
fn check_in_use_ids(state: &LayoutState, next: u64) {
    let used = kani::any_where(|value: &u64| (1..next).contains(value));
    let mut fresh = [next + 1, next + 2, next + 3];
    fresh[any_below(3)] = used;
    check_step(state, next, fresh);
}

/// Invariant 3: a runtime's death changes no placement and removes no tab,
/// pane, screen or workspace; it marks exactly that runtime's tabs dead.
fn check_runtime_exit(state: &LayoutState) {
    let runtime = kani::any_where(|value: &u64| *value <= 2);
    let (after, _) = apply(state, &keyed(LayoutOpKind::RuntimeExited { runtime }))
        // crash-allow: Kani harness (cfg(kani), never in a build); a panic is the proof failure
        .expect("a runtime exit is never rejected");
    assert_eq!(after.workspaces, state.workspaces);
    assert_eq!(after.panes, state.panes);
    assert_eq!(placements(&after), placements(state));
    assert_eq!(after.tabs.len(), state.tabs.len());
    for (id, content) in &after.tabs {
        let old = &state.tabs[id];
        assert!(old.same_identity(content));
        assert_eq!(content.dead, old.dead || old.runtime == runtime);
    }
}

/// I4: moving a tab onto its own position is `Ok` with no events and no
/// change.
fn check_own_position(state: &LayoutState, next: u64) {
    let tab = any_known(next);
    kani::assume(state.tabs.contains_key(&tab));
    // crash-allow: Kani harness (cfg(kani), never in a build); a panic is the proof failure
    let pane = state.pane_of(tab).expect("valid state places every tab");
    // crash-allow: Kani harness (cfg(kani), never in a build); a panic is the proof failure
    let old = state.panes[&pane].iter().position(|t| *t == tab).expect("tab in its pane");
    let index = old + any_below(2);
    let (after, events) =
        // crash-allow: Kani harness (cfg(kani), never in a build); a panic is the proof failure
        apply(state, &keyed(LayoutOpKind::MoveTab { tab, pane, index })).expect("own move");
    assert!(events.is_empty());
    assert_eq!(&after, state);
}

/// I5: replaying an applied op with the same key has no further effect, and
/// reusing the key for another op is a conflict that changes nothing. A
/// rejected op returns no ledger, so by type it records nothing.
fn check_replay(state: &LayoutState, next: u64) {
    let op = keyed(any_kind(next, [next + 1, next + 2, next + 3]));
    let ledger = Ledger::default();
    if let Ok((after, after_ledger, _)) = apply_once(state, &ledger, &op) {
        assert_eq!(
            apply_once(&after, &after_ledger, &op),
            Ok((after.clone(), after_ledger.clone(), Vec::new()))
        );
        let other = keyed(LayoutOpKind::CloseTab { tab: any_known(next) });
        if other.kind != op.kind {
            assert_eq!(
                apply_once(&after, &after_ledger, &other),
                Err(Reject::IdempotencyConflict(op.key.clone()))
            );
        }
    }
}

/// One proof module per shape, with one harness per property.
macro_rules! shape_proofs {
    ($($name:ident => $layout:expr;)*) => {$(
        mod $name {
            use super::*;

            #[kani::proof]
            #[kani::unwind(8)]
            #[kani::solver(cadical)]
            fn step_keeps_invariants() {
                let (state, next) = shape($layout);
                check_step(&state, next, [next + 1, next + 2, next + 3]);
            }

            #[kani::proof]
            #[kani::unwind(8)]
            #[kani::solver(cadical)]
            fn in_use_ids_keep_invariants() {
                let (state, next) = shape($layout);
                check_in_use_ids(&state, next);
            }

            #[kani::proof]
            #[kani::unwind(8)]
            #[kani::solver(cadical)]
            fn runtime_exit_changes_no_placement() {
                let (state, _) = shape($layout);
                check_runtime_exit(&state);
            }

            #[kani::proof]
            #[kani::unwind(8)]
            #[kani::solver(cadical)]
            fn own_position_move_is_a_no_op() {
                let (state, next) = shape($layout);
                check_own_position(&state, next);
            }

            #[kani::proof]
            #[kani::unwind(8)]
            #[kani::solver(cadical)]
            fn replay_with_same_key_is_a_no_op() {
                let (state, next) = shape($layout);
                check_replay(&state, next);
            }
        }
    )*};
}

shape_proofs! {
    // One workspace, one tree screen.
    one_tab => &[&[&[&[1]]]];
    strip_of_two => &[&[&[&[2]]]];
    split_one_one => &[&[&[&[1, 1]]]];
    split_two_one => &[&[&[&[2, 1]]]];
    // Scrolling columns.
    columns_one_one => &[&[&[&[1], &[1]]]];
    columns_split_and_one => &[&[&[&[1, 1], &[1]]]];
    // Two workspaces.
    second_workspace_empty => &[&[&[&[2]]], &[]];
    two_workspaces => &[&[&[&[1]]], &[&[&[2]]]];
    columns_and_workspace => &[&[&[&[1], &[1]]], &[&[&[1]]]];
}
