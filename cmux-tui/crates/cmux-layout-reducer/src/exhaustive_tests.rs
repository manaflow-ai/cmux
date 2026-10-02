//! Exhaustive bounded check: every valid layout with at most 3 tabs, 3
//! panes and 2 workspaces, crossed with every op whose arguments range over
//! every id of the layout plus one unknown id, must keep the invariants.
//! Kani could not prove this (see `proofs.rs`); this enumerates the same
//! small bound directly.
//!
//! Layouts are canonical: ids come from one counter in layout order
//! (workspace, screen, column, pane, tabs), so two layouts that differ only
//! by a renaming of ids are enumerated once. Op arguments still range over
//! every id, so renaming loses no case.

use super::*;
use std::io::Write as _;

/// A screen: tree (one column, id 0) or niri columns, each a list of panes
/// given by their tab counts.
#[derive(Clone, Debug)]
struct ScreenShape {
    niri: bool,
    columns: Vec<Vec<usize>>,
}

type Shape = Vec<Vec<ScreenShape>>;

/// Every way to cut `items` into consecutive non-empty parts.
fn splits<T: Clone>(items: &[T]) -> Vec<Vec<Vec<T>>> {
    let n = items.len();
    let mut out = Vec::new();
    // Bit i set means a cut after item i.
    for mask in 0u32..(1 << n.saturating_sub(1)) {
        let mut parts = Vec::new();
        let mut current = Vec::new();
        for (index, item) in items.iter().enumerate() {
            current.push(item.clone());
            if index + 1 < n && mask & (1 << index) != 0 {
                parts.push(std::mem::take(&mut current));
            }
        }
        parts.push(current);
        out.push(parts);
    }
    out
}

/// Every list of screens holding `panes` in order.
fn screens_of(panes: &[usize]) -> Vec<Vec<ScreenShape>> {
    if panes.is_empty() {
        return vec![Vec::new()];
    }
    let mut out = Vec::new();
    for screens in splits(panes) {
        let mut combos: Vec<Vec<ScreenShape>> = vec![Vec::new()];
        for screen in &screens {
            let mut options = vec![ScreenShape { niri: false, columns: vec![screen.clone()] }];
            for columns in splits(screen) {
                options.push(ScreenShape { niri: true, columns });
            }
            combos = combos
                .iter()
                .flat_map(|prefix| {
                    options.iter().map(move |option| {
                        let mut next = prefix.clone();
                        next.push(option.clone());
                        next
                    })
                })
                .collect();
        }
        out.extend(combos);
    }
    out
}

/// Every canonical shape within the bounds that has at least one tab.
fn shapes() -> Vec<Shape> {
    let mut pane_lists = Vec::new();
    for count in 1..=3usize {
        let mut list = vec![1usize; count];
        loop {
            if list.iter().sum::<usize>() <= 3 {
                pane_lists.push(list.clone());
            }
            // Odometer over tab counts 1..=3.
            let mut position = 0;
            while position < count && list[position] == 3 {
                list[position] = 1;
                position += 1;
            }
            if position == count {
                break;
            }
            list[position] += 1;
        }
    }
    let mut out = Vec::new();
    for panes in &pane_lists {
        for screens in screens_of(panes) {
            out.push(vec![screens]);
        }
        for cut in 0..=panes.len() {
            for first in screens_of(&panes[..cut]) {
                for second in screens_of(&panes[cut..]) {
                    out.push(vec![first.clone(), second]);
                }
            }
        }
    }
    out
}

/// Build `shape` with ids from 1; `content` gives each tab's runtime and
/// dead flag by tab order. Returns the state and the first unused id.
fn build(shape: &Shape, content: &dyn Fn(usize) -> (u64, bool)) -> (LayoutState, u64) {
    let mut next = 1u64;
    let mut id = || {
        next += 1;
        next - 1
    };
    let mut state = LayoutState::default();
    let mut tab_index = 0;
    for screens in shape {
        let workspace = id();
        let mut built = Vec::new();
        for screen_shape in screens {
            let screen = id();
            let mut columns = Vec::new();
            for panes in &screen_shape.columns {
                let column = if screen_shape.niri { id() } else { 0 };
                let mut built_panes = Vec::new();
                for tabs in panes {
                    let pane = id();
                    let mut pane_tabs = Vec::new();
                    for _ in 0..*tabs {
                        let tab = id();
                        let (runtime, dead) = content(tab_index);
                        tab_index += 1;
                        state.tabs.insert(tab, TabContent { runtime, terminal: None, dead });
                        pane_tabs.push(tab);
                    }
                    state.panes.insert(pane, pane_tabs);
                    built_panes.push(pane);
                }
                columns.push(Column { id: column, panes: built_panes });
            }
            built.push(Screen { id: screen, columns, columns_active: screen_shape.niri });
        }
        state.workspaces.push(Workspace { id: workspace, screens: built });
    }
    (state, next)
}

/// Sets of ids for new entities: all fresh, then each slot replaced by an
/// id in use (1, the first workspace).
fn new_id_sets(next: u64) -> Vec<[u64; 3]> {
    let fresh = [next + 1, next + 2, next + 3];
    let mut sets = vec![fresh];
    for slot in 0..3 {
        let mut set = fresh;
        set[slot] = 1;
        sets.push(set);
    }
    sets
}

/// Every op on a layout whose first unused id is `next`.
fn ops(next: u64) -> Vec<LayoutOpKind> {
    let ids = 0..=next;
    let optional = || std::iter::once(None).chain((0..=next).map(Some));
    let mut out = Vec::new();
    for tab in ids.clone() {
        out.push(LayoutOpKind::CloseTab { tab });
        for pane in ids.clone() {
            for index in 0..=4 {
                out.push(LayoutOpKind::MoveTab { tab, pane, index });
            }
            for edge in [Edge::Left, Edge::Right, Edge::Top, Edge::Bottom] {
                for [new_pane, _, _] in new_id_sets(next) {
                    out.push(LayoutOpKind::MoveTabToSplit { tab, pane, edge, new_pane });
                }
            }
            let fresh = new_id_sets(next)[0];
            for width_permille in [99, 1001] {
                out.push(LayoutOpKind::MoveTabToColumn {
                    tab,
                    anchor: pane,
                    after_column: None,
                    width_permille,
                    new_pane: fresh[0],
                    new_column: fresh[1],
                    base_column: fresh[2],
                });
            }
            for after_column in optional() {
                for [new_pane, new_column, base_column] in new_id_sets(next) {
                    out.push(LayoutOpKind::MoveTabToColumn {
                        tab,
                        anchor: pane,
                        after_column,
                        width_permille: 500,
                        new_pane,
                        new_column,
                        base_column,
                    });
                }
            }
        }
        for index in [None, Some(0), Some(1), Some(2)] {
            for [new_workspace, new_screen, new_pane] in new_id_sets(next) {
                out.push(LayoutOpKind::MoveTabToNewWorkspace {
                    tab,
                    index,
                    new_workspace,
                    new_screen,
                    new_pane,
                });
            }
        }
        for workspace in ids.clone() {
            for pane in optional() {
                for [new_screen, new_pane, _] in new_id_sets(next) {
                    out.push(LayoutOpKind::MoveTabToWorkspace {
                        tab,
                        workspace,
                        pane,
                        new_screen,
                        new_pane,
                    });
                }
            }
        }
    }
    for runtime in 0..=2 {
        out.push(LayoutOpKind::RuntimeExited { runtime });
    }
    out
}

fn keyed(kind: LayoutOpKind) -> LayoutOp {
    LayoutOp { key: String::from("k"), kind }
}

/// I1 (stated without the crate's checker), I2 and I3, no reliance on the
/// `Reject::Invariant` safety net, and I5 for every applied op.
fn check_op(state: &LayoutState, op: &LayoutOp) -> bool {
    let after = match apply(state, op) {
        Ok((after, _)) => after,
        Err(Reject::Invariant(violations)) => {
            panic!("valid state reached the invariant check: {op:?} on {state:?}: {violations:?}")
        }
        Err(_) => return false,
    };
    assert!(check_state(&after).is_empty(), "{op:?} on {state:?} broke I2/I3: {after:?}");
    match op.kind {
        LayoutOpKind::CloseTab { tab } => {
            assert!(!after.tabs.contains_key(&tab), "{op:?} kept its tab");
            assert_eq!(after.tabs.len() + 1, state.tabs.len(), "{op:?} on {state:?}");
            for (id, content) in &after.tabs {
                assert_eq!(state.tabs.get(id), Some(content), "{op:?} on {state:?}");
            }
        }
        LayoutOpKind::RuntimeExited { .. } => {
            assert_eq!(after.tabs.len(), state.tabs.len());
            for (id, content) in &after.tabs {
                assert!(state.tabs[id].same_identity(content), "{op:?} on {state:?}");
            }
        }
        _ => assert_eq!(after.tabs, state.tabs, "{op:?} on {state:?} changed the tabs"),
    }

    // I5: a replay is a no-op, and the key for another op is a conflict.
    let (once, ledger, _) = apply_once(state, &Ledger::default(), op).expect("applied above");
    assert_eq!(once, after);
    assert_eq!(apply_once(&once, &ledger, op), Ok((once.clone(), ledger.clone(), Vec::new())));
    let other = keyed(LayoutOpKind::RuntimeExited { runtime: u64::MAX });
    assert_eq!(
        apply_once(&once, &ledger, &other),
        Err(Reject::IdempotencyConflict(op.key.clone()))
    );
    true
}

/// Invariant 3: a runtime exit keeps every placement and marks exactly that
/// runtime's tabs dead.
fn check_runtime_exit(state: &LayoutState) {
    for runtime in 0..=2 {
        let (after, _) = apply(state, &keyed(LayoutOpKind::RuntimeExited { runtime }))
            .expect("a runtime exit is never rejected");
        assert_eq!(after.workspaces, state.workspaces);
        assert_eq!(after.panes, state.panes);
        assert_eq!(placements(&after), placements(state));
        for (id, content) in &after.tabs {
            let old = &state.tabs[id];
            assert!(old.same_identity(content));
            assert_eq!(content.dead, old.dead || old.runtime == runtime, "{state:?}");
        }
    }
}

/// I4: a move onto the tab's own place is `Ok` with no events and no change.
fn check_own_place(state: &LayoutState) {
    for (pane, tabs) in &state.panes {
        for (old, tab) in tabs.iter().enumerate() {
            for index in [old, old + 1] {
                let op = keyed(LayoutOpKind::MoveTab { tab: *tab, pane: *pane, index });
                let (after, events) = apply(state, &op).expect("own-place move");
                assert!(events.is_empty(), "{op:?} on {state:?}");
                assert_eq!(&after, state, "{op:?}");
            }
        }
    }
}

#[test]
fn exhaustive_small_layouts_keep_invariants() {
    let started = std::time::Instant::now();
    let shapes = shapes();
    let (mut layouts, mut cases, mut applied) = (0usize, 0usize, 0usize);
    for shape in &shapes {
        // Shared and distinct runtimes; every tab alive.
        let (state, next) = build(shape, &|index| (index as u64 % 2, false));
        assert!(check_state(&state).is_empty(), "{shape:?}");
        layouts += 1;
        check_own_place(&state);
        for kind in ops(next) {
            cases += 1;
            applied += usize::from(check_op(&state, &keyed(kind)));
        }
        // Invariant 3 over every runtime assignment and dead flag.
        let tab_count = state.tabs.len();
        for runtimes in 0u32..(1 << tab_count) {
            for first_dead in [false, true] {
                let content =
                    |index: usize| (u64::from(runtimes >> index & 1), first_dead && index == 0);
                let (state, _) = build(shape, &content);
                check_runtime_exit(&state);
                cases += 3;
            }
        }
    }
    // Bypass the test harness's output capture so the count reaches CI logs.
    let _ = writeln!(
        std::io::stderr(),
        "exhaustive layout check: {layouts} layouts, {cases} cases, {applied} applied, {:.1}s",
        started.elapsed().as_secs_f64()
    );
    assert_eq!(layouts, shapes.len());
    assert!(layouts > 100 && applied > 0);
}
