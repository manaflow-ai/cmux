use super::*;

fn all_flags() -> Vec<Option<ColumnDock>> {
    let mut flags = vec![None];
    for edge in DockEdge::ALL {
        for mode in [DockMode::Docked, DockMode::Overlay] {
            flags.push(Some(ColumnDock::new(edge, mode)));
        }
    }
    flags
}

/// Every flag assignment of `count` columns, consistent or not.
fn assignments(count: usize) -> Vec<Vec<Option<ColumnDock>>> {
    (0..count).fold(vec![Vec::new()], |prefixes, _| {
        prefixes
            .into_iter()
            .flat_map(|prefix| {
                all_flags().into_iter().map(move |flag| {
                    let mut next = prefix.clone();
                    next.push(flag);
                    next
                })
            })
            .collect()
    })
}

/// Checks one op from one consistent state; returns whether it was
/// accepted.
fn check_op(flags: &[Option<ColumnDock>], index: usize, dock: Option<ColumnDock>) -> bool {
    let replaced = |candidate: usize| {
        candidate != index
            && dock.zip(flags[candidate]).is_some_and(|(set, held)| set.edge == held.edge)
    };
    let scrolls_after = |candidate: usize| {
        if candidate == index {
            dock.is_none()
        } else {
            flags[candidate].is_none() || replaced(candidate)
        }
    };
    let Ok(next) = reduce_column_dock(flags, index, dock) else {
        assert_eq!(
            reduce_column_dock(flags, index, dock),
            Err(ColumnDockError::LastScrollingColumn)
        );
        assert!(!(0..flags.len()).any(scrolls_after), "{flags:?} {index} {dock:?}");
        return false;
    };
    assert_eq!(next.len(), flags.len());
    assert!(dock_flags_are_consistent(&next), "{flags:?} -> {next:?}");
    assert!(next.iter().any(Option::is_none), "one column must scroll");
    assert_eq!(next[index], dock);
    for candidate in (0..flags.len()).filter(|candidate| *candidate != index) {
        let expected = if replaced(candidate) { None } else { flags[candidate] };
        assert_eq!(next[candidate], expected, "{flags:?} {index} {dock:?}");
    }
    let replayed = reduce_column_dock(&next, index, dock).unwrap();
    assert_eq!(replayed, next, "replaying an op changes nothing");
    true
}

/// Exhaustive check of the reducer for screens of up to five columns:
/// from every consistent state, every op either yields a consistent
/// state that differs only where the op says, or is rejected exactly
/// when no scrolling column would remain. Replaying an accepted op is a
/// no-op.
#[test]
fn dock_column_reducer_keeps_invariants_for_every_state_and_op() {
    let (mut accepted, mut rejected) = (0, 0);
    for count in 1..=5 {
        let states = assignments(count);
        for flags in states.iter().filter(|flags| dock_flags_are_consistent(flags)) {
            for index in 0..count {
                for dock in all_flags() {
                    if check_op(flags, index, dock) {
                        accepted += 1;
                    } else {
                        rejected += 1;
                    }
                }
            }
        }
    }
    // Derived by counting, independently of the reducer (4 edges x 2
    // modes = 8 flags, 9 ops per column). Rejected = the target column is
    // the only scrolling one and the other n-1 hold distinct edges other
    // than the new one: sum 8*n*P(3,n-1)*2^(n-1) = 8+96+576+1536+0 = 2216.
    // Consistent states with n columns: 1 + sum_k C(n,k)*P(4,k)*2^k for
    // 1 <= k < n = 1, 17, 169, 1089, 4361; ops = sum states*n*9 = 240327;
    // accepted = 240327 - 2216 = 238111.
    assert_eq!((accepted, rejected), (238111, 2216), "every state and op was checked");
}

#[test]
fn dock_column_reducer_rejects_an_index_outside_the_screen() {
    assert_eq!(
        reduce_column_dock(&[None, None], 2, None),
        Err(ColumnDockError::NoSuchColumn { index: 2 })
    );
}

#[test]
fn dock_column_normalization_restores_invariants_after_any_removal() {
    let column = |dock| LayoutColumn { dock, ..LayoutColumn::new(1, 0.5, Node::Leaf(1), None) };
    for count in 0..=4 {
        for flags in assignments(count) {
            let mut columns = flags.iter().copied().map(column).collect::<Vec<_>>();
            crate::model::normalize_dock_columns(&mut columns);
            assert!(dock_columns_are_consistent(&columns), "{flags:?}");
            for (before, after) in flags.iter().zip(&columns) {
                assert!(after.dock.is_none() || after.dock == *before);
            }
        }
    }
}
