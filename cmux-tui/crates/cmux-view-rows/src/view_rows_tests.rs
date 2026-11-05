//! The window's messages and the receiver's apply (DESIGN.md section 4.3, invariant I4): every list
//! a window is given reaches its receiver exactly; an edit is minimal and names only what changed;
//! a receiver refuses a gap or an edit that does not fit, and keeps its rows.

use super::*;
use proptest::prelude::*;
use std::collections::{HashMap, HashSet};

fn rows(list: &[(&'static str, u32)]) -> Rows<&'static str, u32> {
    Rows::new(list.iter().copied()).expect("each key once")
}

fn edit(
    removed: Vec<usize>,
    moved: Vec<Move>,
    inserted: Vec<Placed<&'static str, u32>>,
    changed: Vec<Placed<&'static str, u32>>,
    count: usize,
) -> Edit<&'static str, u32> {
    Edit { removed, moved, inserted, changed, count }
}

fn placed(at: usize, key: &'static str, row: u32) -> Placed<&'static str, u32> {
    Placed { at, key, row }
}

#[test]
fn the_first_message_is_a_reset_with_every_row() {
    let mut window = Window::new();
    let list = rows(&[("a", 1), ("b", 2)]);
    assert_eq!(window.next(list.clone()), Some(Diff::Reset { revision: 1, rows: list.clone() }));
    assert_eq!(window.revision(), 1);
    assert_eq!(window.sent(), Some(&list));
}

#[test]
fn the_same_rows_again_send_nothing_and_keep_the_revision() {
    let mut window = Window::new();
    let list = rows(&[("a", 1), ("b", 2)]);
    assert!(window.next(list.clone()).is_some());
    assert_eq!(window.next(list.clone()), None);
    assert_eq!(window.revision(), 1);
    assert_eq!(window.sent(), Some(&list));
}

#[test]
fn a_value_change_is_an_edit_that_names_only_the_changed_row() {
    let mut window = Window::new();
    assert!(window.next(rows(&[("a", 1), ("b", 2), ("c", 3)])).is_some());
    assert_eq!(
        window.next(rows(&[("a", 1), ("b", 20), ("c", 3)])),
        Some(Diff::Edit {
            base: 1,
            revision: 2,
            edit: edit(vec![], vec![], vec![], vec![placed(1, "b", 20)], 3)
        })
    );
}

#[test]
fn a_row_that_changes_places_is_the_only_move() {
    let mut window = Window::new();
    assert!(window.next(rows(&[("x", 0), ("a", 1), ("b", 2), ("c", 3), ("d", 4)])).is_some());
    assert_eq!(
        window.next(rows(&[("a", 1), ("b", 2), ("c", 3), ("d", 4), ("x", 0)])),
        Some(Diff::Edit {
            base: 1,
            revision: 2,
            edit: edit(vec![], vec![Move { from: 0, to: 4 }], vec![], vec![], 5)
        })
    );
    // And back: again one move, not four.
    assert_eq!(
        window.next(rows(&[("x", 0), ("a", 1), ("b", 2), ("c", 3), ("d", 4)])),
        Some(Diff::Edit {
            base: 2,
            revision: 3,
            edit: edit(vec![], vec![Move { from: 4, to: 0 }], vec![], vec![], 5)
        })
    );
}

#[test]
fn removed_and_inserted_rows_name_their_own_indices() {
    let mut window = Window::new();
    assert!(window.next(rows(&[("a", 1), ("b", 2), ("c", 3)])).is_some());
    assert_eq!(
        window.next(rows(&[("a", 1), ("d", 4), ("c", 3)])),
        Some(Diff::Edit {
            base: 1,
            revision: 2,
            edit: edit(vec![1], vec![], vec![placed(1, "d", 4)], vec![], 3)
        })
    );
}

#[test]
fn each_edit_starts_from_the_revision_before_it() {
    let lists: [&[(&'static str, u32)]; 5] =
        [&[("a", 1)], &[("a", 2)], &[("a", 2), ("b", 1)], &[("b", 1)], &[]];
    let mut window = Window::new();
    let mut last = 0;
    for (i, list) in lists.iter().enumerate() {
        match window.next(rows(list)) {
            Some(Diff::Reset { revision, .. }) if i == 0 => {
                assert_eq!(revision, 1);
                last = revision;
            }
            Some(Diff::Edit { base, revision, .. }) if i > 0 => {
                assert_eq!(base, last, "message {i}");
                assert_eq!(revision, last + 1, "message {i}");
                last = revision;
            }
            other => panic!("message {i}: {other:?}"),
        }
    }
    assert_eq!(window.revision(), 5);
}

#[test]
fn after_invalidate_the_next_message_is_a_reset_that_goes_on_counting() {
    let mut window = Window::new();
    assert!(window.next(rows(&[("a", 1)])).is_some());
    assert!(window.next(rows(&[("a", 2)])).is_some());
    window.invalidate();
    assert_eq!(window.sent(), None);
    let list = rows(&[("a", 2)]);
    assert_eq!(window.next(list.clone()), Some(Diff::Reset { revision: 3, rows: list }));
}

#[test]
fn a_window_that_replaces_another_goes_on_from_its_revision() {
    let mut window = Window::starting_after(41);
    let list = rows(&[("a", 1)]);
    assert_eq!(window.next(list.clone()), Some(Diff::Reset { revision: 42, rows: list }));
}

#[test]
fn a_receiver_refuses_an_edit_from_another_revision_and_keeps_its_rows() {
    let change = edit(vec![], vec![], vec![], vec![placed(0, "a", 9)], 1);
    let mut applied = Applied::new();
    assert_eq!(
        applied.apply(Diff::Edit { base: 0, revision: 1, edit: change.clone() }),
        Err(ApplyError::Gap { held: None, base: 0 })
    );
    let list = rows(&[("a", 1)]);
    assert_eq!(applied.apply(Diff::Reset { revision: 5, rows: list.clone() }), Ok(()));
    assert_eq!(
        applied.apply(Diff::Edit { base: 4, revision: 5, edit: change.clone() }),
        Err(ApplyError::Gap { held: Some(5), base: 4 })
    );
    assert_eq!(applied.rows(), &list);
    assert_eq!(applied.revision(), Some(5));
    assert_eq!(applied.apply(Diff::Edit { base: 5, revision: 6, edit: change }), Ok(()));
    assert_eq!(applied.rows(), &rows(&[("a", 9)]));
    assert_eq!(applied.revision(), Some(6));
}

#[test]
fn a_receiver_refuses_an_edit_that_does_not_fit_and_keeps_its_rows() {
    let list = rows(&[("a", 1), ("b", 2)]);
    let cases = [
        (edit(vec![2], vec![], vec![], vec![], 1), Malformed::IndexOutOfRange),
        (edit(vec![0], vec![Move { from: 0, to: 0 }], vec![], vec![], 1), Malformed::BaseRowTwice),
        (
            edit(vec![], vec![Move { from: 1, to: 0 }], vec![placed(0, "c", 3)], vec![], 3),
            Malformed::NewIndexTwice,
        ),
        (edit(vec![], vec![], vec![placed(0, "c", 3)], vec![], 4), Malformed::TooFewRows),
        (edit(vec![], vec![], vec![placed(0, "c", 3)], vec![], 2), Malformed::TooManyRows),
        (edit(vec![], vec![], vec![placed(0, "b", 3)], vec![], 3), Malformed::DuplicateKey),
        (edit(vec![], vec![], vec![], vec![placed(0, "b", 3)], 2), Malformed::KeyMismatch),
        (edit(vec![], vec![], vec![], vec![placed(2, "b", 3)], 2), Malformed::IndexOutOfRange),
        (edit(vec![], vec![], vec![], vec![], 3), Malformed::CountMismatch),
        (edit(vec![1], vec![], vec![], vec![placed(1, "b", 3)], 1), Malformed::IndexOutOfRange),
    ];
    for (change, why) in cases {
        let mut applied = Applied::new();
        assert_eq!(applied.apply(Diff::Reset { revision: 1, rows: list.clone() }), Ok(()));
        assert_eq!(
            applied.apply(Diff::Edit { base: 1, revision: 2, edit: change.clone() }),
            Err(ApplyError::Malformed(why)),
            "{change:?}"
        );
        assert_eq!(applied.rows(), &list, "{change:?}");
        assert_eq!(applied.revision(), Some(1), "{change:?}");
    }
}

/// A count the base rows and the inserted rows cannot fill is refused before anything is allocated
/// for it: a receiver never panics or aborts on an edit, whatever it says (review of #33902).
#[test]
fn a_receiver_refuses_a_count_its_rows_cannot_fill_before_it_allocates_it() {
    let list = rows(&[("a", 1), ("b", 2)]);
    for (change, why) in [
        (edit(vec![0], vec![], vec![], vec![], usize::MAX), Malformed::TooFewRows),
        (edit(vec![], vec![], vec![placed(0, "c", 3)], vec![], usize::MAX), Malformed::TooFewRows),
        (edit(vec![0, 1], vec![], vec![placed(0, "c", 3)], vec![], 0), Malformed::TooManyRows),
    ] {
        let mut applied = Applied::new();
        assert_eq!(applied.apply(Diff::Reset { revision: 1, rows: list.clone() }), Ok(()));
        assert_eq!(
            applied.apply(Diff::Edit { base: 1, revision: 2, edit: change.clone() }),
            Err(ApplyError::Malformed(why)),
            "{change:?}"
        );
        assert_eq!(applied.rows(), &list, "{change:?}");
        assert_eq!(applied.revision(), Some(1), "{change:?}");
    }
}

#[test]
fn rows_refuse_a_key_that_comes_twice() {
    assert_eq!(Rows::new([("a", 1), ("b", 2), ("a", 3)]).err(), Some(DuplicateKey("a")));
    let list = rows(&[("a", 1), ("b", 2)]);
    assert_eq!(list.position(&"b"), Some(1));
    assert_eq!(list.get(&"b"), Some(&2));
    assert_eq!(list.get(&"c"), None);
}

/// A list of unique keys from a small set, with few values, so lists share keys and values often.
fn list() -> impl Strategy<Value = Vec<(u8, u8)>> {
    proptest::collection::vec((0u8..24, 0u8..3), 0..20).prop_map(|pairs| {
        let mut seen = HashSet::new();
        pairs.into_iter().filter(|(key, _)| seen.insert(*key)).collect::<Vec<_>>()
    })
}

/// The length of the longest strictly increasing subsequence, by the quadratic recurrence (an
/// independent check of the window's own O(n log n) one).
fn longest_increasing_length(values: &[usize]) -> usize {
    // ending[i]: the longest strictly increasing subsequence that ends at values[i].
    let mut ending: Vec<usize> = Vec::with_capacity(values.len());
    for (i, value) in values.iter().enumerate() {
        let before = values[..i]
            .iter()
            .zip(&ending)
            .filter(|(earlier, _)| *earlier < value)
            .map(|(_, length)| *length);
        ending.push(before.max().unwrap_or(0) + 1);
    }
    ending.into_iter().max().unwrap_or(0)
}

fn cases() -> u32 {
    std::env::var("PROPTEST_CASES").ok().and_then(|value| value.parse().ok()).unwrap_or(512)
}

proptest! {
    #![proptest_config(ProptestConfig { cases: cases(), ..ProptestConfig::default() })]

    /// Any sequence of lists: after each message the receiver holds exactly the window's list, at
    /// the window's revision.
    #[test]
    fn every_list_reaches_the_receiver_exactly(lists in proptest::collection::vec(list(), 1..10)) {
        let mut window = Window::new();
        let mut applied = Applied::new();
        for list in lists {
            let rows = Rows::new(list).expect("each key once");
            if let Some(diff) = window.next(rows.clone()) {
                prop_assert_eq!(applied.apply(diff), Ok(()));
            }
            prop_assert_eq!(applied.rows(), &rows);
            prop_assert_eq!(applied.revision(), Some(window.revision()));
        }
    }

    /// From any list to any other: no message when they are equal, else one edit that removes
    /// exactly the rows that left, inserts exactly the new ones, names exactly the kept rows whose
    /// value changed, and moves the fewest kept rows (all kept rows minus a longest increasing run
    /// of their new places).
    #[test]
    fn an_edit_is_minimal_and_well_formed(old in list(), new in list()) {
        let mut window = Window::new();
        prop_assert!(window.next(Rows::new(old.clone()).expect("each key once")).is_some());
        let diff = window.next(Rows::new(new.clone()).expect("each key once"));
        if old == new {
            prop_assert_eq!(diff, None);
            return Ok(());
        }
        let edit = match diff {
            Some(Diff::Edit { base: 1, revision: 2, edit }) => edit,
            other => return Err(TestCaseError::fail(format!("not an edit from 1 to 2: {other:?}"))),
        };
        let old_at: HashMap<u8, usize> =
            old.iter().enumerate().map(|(at, (key, _))| (*key, at)).collect();
        let new_at: HashMap<u8, usize> =
            new.iter().enumerate().map(|(at, (key, _))| (*key, at)).collect();
        let removed: Vec<usize> = old
            .iter()
            .enumerate()
            .filter(|(_, (key, _))| !new_at.contains_key(key))
            .map(|(at, _)| at)
            .collect();
        prop_assert_eq!(&edit.removed, &removed);
        let inserted: Vec<Placed<u8, u8>> = new
            .iter()
            .enumerate()
            .filter(|(_, (key, _))| !old_at.contains_key(key))
            .map(|(at, (key, row))| Placed { at, key: *key, row: *row })
            .collect();
        prop_assert_eq!(&edit.inserted, &inserted);
        let changed: Vec<Placed<u8, u8>> = new
            .iter()
            .enumerate()
            .filter(|(_, (key, row))| old_at.get(key).is_some_and(|&from| old[from].1 != *row))
            .map(|(at, (key, row))| Placed { at, key: *key, row: *row })
            .collect();
        prop_assert_eq!(&edit.changed, &changed);
        let kept: Vec<usize> = old.iter().filter_map(|(key, _)| new_at.get(key).copied()).collect();
        prop_assert_eq!(edit.moved.len(), kept.len() - longest_increasing_length(&kept));
        for step in &edit.moved {
            let target = old.get(step.from).and_then(|(key, _)| new_at.get(key)).copied();
            prop_assert_eq!(target, Some(step.to));
        }
        prop_assert!(edit.moved.windows(2).all(|pair| pair[0].to < pair[1].to), "{:?}", edit.moved);
        prop_assert_eq!(edit.count, new.len());
    }
}
