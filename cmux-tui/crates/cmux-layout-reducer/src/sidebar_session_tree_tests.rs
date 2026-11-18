use super::*;
use proptest::prelude::*;

fn row(id: &str, parent: Option<&str>, state: State) -> Row {
    Row { id: id.to_owned(), parent: parent.map(str::to_owned), state }
}

fn ids(request: &Request) -> Vec<(String, u32)> {
    respond(request)
        .rows
        .iter()
        .map(|drawn| (request.rows[drawn.index].id.clone(), drawn.depth))
        .collect()
}

fn pairs(list: &[(&str, u32)]) -> Vec<(String, u32)> {
    list.iter().map(|(id, depth)| ((*id).to_owned(), *depth)).collect()
}

/// a > (b > d, c), e; the list's order puts children before and after their parents.
fn sample() -> Vec<Row> {
    vec![
        row("d", Some("b"), State::Failed),
        row("a", None, State::Idle),
        row("e", None, State::Done),
        row("b", Some("a"), State::Running),
        row("c", Some("a"), State::Idle),
    ]
}

#[test]
fn children_draw_under_their_parent_in_list_order_at_any_depth() {
    let request = Request { rows: sample(), expanded_by_default: true, ..Request::default() };
    assert_eq!(ids(&request), pairs(&[("a", 0), ("b", 1), ("d", 2), ("c", 1), ("e", 0)]));
    let drawn = respond(&request).rows;
    assert_eq!(drawn[0].fold, Some(Fold::Expanded));
    assert_eq!(drawn[1].fold, Some(Fold::Expanded));
    assert_eq!(drawn[2].fold, None, "a leaf has no chevron");
    assert_eq!(drawn[0].mark, State::Idle, "an open parent shows its own state");
}

#[test]
fn a_folded_parent_rolls_up_its_hidden_sessions_to_its_mark() {
    let request = Request { rows: sample(), ..Request::default() };
    let drawn = respond(&request).rows;
    assert_eq!(ids(&request), pairs(&[("a", 0), ("e", 0)]));
    assert_eq!(drawn[0].fold, Some(Fold::Collapsed));
    assert_eq!(drawn[0].mark, State::Failed, "failed beats running");
    assert_eq!(drawn[0].roll_up, Some(RollUp { needs_input: 0, failed: 1, running: 1, hidden: 3 }));
    // Needs input beats both.
    let mut rows = sample();
    rows[4].state = State::NeedsInput;
    let drawn = respond(&Request { rows, ..Request::default() }).rows;
    assert_eq!(drawn[0].mark, State::NeedsInput);
    // A done or idle child never raises the mark.
    let rows = vec![row("p", None, State::Idle), row("k", Some("p"), State::Done)];
    let drawn = respond(&Request { rows, ..Request::default() }).rows;
    assert_eq!(drawn[0].mark, State::Idle);
    assert_eq!(drawn[0].roll_up.map(|r| r.hidden), Some(1));
}

#[test]
fn the_persons_folds_win_over_the_default() {
    let opened = Request { rows: sample(), expanded: vec!["a".into()], ..Request::default() };
    assert_eq!(ids(&opened), pairs(&[("a", 0), ("b", 1), ("c", 1), ("e", 0)]), "b stays folded");
    let folded = Request {
        rows: sample(),
        collapsed: vec!["b".into()],
        expanded_by_default: true,
        ..Request::default()
    };
    assert_eq!(ids(&folded), pairs(&[("a", 0), ("b", 1), ("c", 1), ("e", 0)]));
    let filtering = Request { rows: sample(), filtering: true, ..Request::default() };
    assert_eq!(ids(&filtering).len(), 5, "a filter opens every fold");
}

#[test]
fn a_missing_parent_a_cycle_or_a_repeated_id_leaves_a_root() {
    let rows = vec![
        row("x", Some("gone"), State::Idle),
        row("p", Some("q"), State::Idle),
        row("q", Some("p"), State::Idle),
        row("self", Some("self"), State::Idle),
        row("dup", None, State::Idle),
        row("dup", Some("x"), State::Idle),
        row("under", Some("q"), State::Idle),
    ];
    let request = Request { rows, expanded_by_default: true, ..Request::default() };
    let drawn = ids(&request);
    assert_eq!(drawn.len(), 7, "every row draws once: {drawn:?}");
    assert!(drawn.iter().all(|(_, depth)| *depth == 0), "{drawn:?}");
}

#[test]
fn a_long_chain_draws_without_recursion() {
    let rows: Vec<Row> = (0..50_000)
        .map(|i| Row {
            id: format!("n{i}"),
            parent: (i > 0).then(|| format!("n{}", i - 1)),
            state: State::Idle,
        })
        .collect();
    let drawn = respond(&Request { rows, expanded_by_default: true, ..Request::default() }).rows;
    assert_eq!(drawn.len(), 50_000);
    assert_eq!(drawn.last().map(|d| d.depth), Some(49_999));
}

#[test]
fn a_fold_keeps_only_the_side_that_differs_from_the_default() {
    let flip =
        |expanded: &[&str], collapsed: &[&str], default: bool, id: &str, open: Option<bool>| {
            fold(&FoldRequest {
                expanded: expanded.iter().map(|s| (*s).to_owned()).collect(),
                collapsed: collapsed.iter().map(|s| (*s).to_owned()).collect(),
                expanded_by_default: default,
                id: id.to_owned(),
                open,
                parents: vec![],
            })
        };
    let opened = flip(&[], &[], false, "a", None);
    assert_eq!(
        (opened.expanded, opened.collapsed, opened.open),
        (vec!["a".to_owned()], vec![], true)
    );
    let back = flip(&["a"], &[], false, "a", None);
    assert_eq!((back.expanded.len(), back.collapsed.len(), back.open), (0, 0, false));
    let folded = flip(&[], &[], true, "a", Some(false));
    assert_eq!(folded.collapsed, vec!["a".to_owned()]);
    let already = flip(&["a"], &[], false, "a", Some(true));
    assert_eq!(
        (already.expanded, already.open),
        (vec!["a".to_owned()], true),
        "Right on an open row"
    );
    let pruned = fold(&FoldRequest {
        expanded: vec!["gone".into(), "kept".into()],
        id: "a".into(),
        parents: vec!["a".into(), "kept".into()],
        ..FoldRequest::default()
    });
    assert_eq!(pruned.expanded, vec!["a".to_owned(), "kept".to_owned()]);
}

fn arbitrary_rows() -> impl Strategy<Value = Vec<Row>> {
    (1usize..24).prop_flat_map(|n| {
        proptest::collection::vec((proptest::option::of(0usize..n + 2), 0u8..5), n).prop_map(
            move |specs| {
                specs
                    .into_iter()
                    .enumerate()
                    .map(|(i, (parent, state))| Row {
                        id: format!("r{i}"),
                        parent: parent.map(|p| format!("r{p}")),
                        state: [
                            State::Idle,
                            State::Done,
                            State::Running,
                            State::Failed,
                            State::NeedsInput,
                        ][usize::from(state)],
                    })
                    .collect()
            },
        )
    })
}

proptest! {
    /// No shift: toggling any parent's fold leaves every row above it where it was, and the rows
    /// after its subtree in the same order at the same depth; only its own subtree comes or goes.
    #[test]
    fn a_fold_never_moves_a_row_outside_its_subtree(rows in arbitrary_rows(), pick in 0usize..24,
                                                    default in any::<bool>()) {
        let base = Request { rows: rows.clone(), expanded_by_default: default, ..Request::default() };
        let before = respond(&base).rows;
        let parents: Vec<&DrawnRow> = before.iter().filter(|d| d.fold.is_some()).collect();
        prop_assume!(!parents.is_empty());
        let target = parents[pick % parents.len()];
        let id = rows[target.index].id.clone();
        let toggled = fold(&FoldRequest { id: id.clone(), expanded_by_default: default, ..FoldRequest::default() });
        let after = respond(&Request { expanded: toggled.expanded, collapsed: toggled.collapsed, ..base.clone() }).rows;
        let at = before.iter().position(|d| d.index == target.index).unwrap();
        prop_assert_eq!(&before[..=at].iter().map(|d| (d.index, d.depth)).collect::<Vec<_>>(),
                        &after[..=at].iter().map(|d| (d.index, d.depth)).collect::<Vec<_>>());
        let past = |drawn: &[DrawnRow]| -> Vec<(usize, u32)> {
            drawn[at + 1..].iter().skip_while(|d| d.depth > target.depth).map(|d| (d.index, d.depth)).collect()
        };
        prop_assert_eq!(past(&before), past(&after));
        // Every row draws at most once, and every row draws when every fold is open.
        let open = respond(&Request { filtering: true, ..base }).rows;
        let mut seen: Vec<usize> = open.iter().map(|d| d.index).collect();
        seen.sort_unstable();
        prop_assert_eq!(seen, (0..rows.len()).collect::<Vec<_>>());
    }
}
