use super::{pane_changes, single_relocation};
use crate::mux::TreeDeltaKind::{TabAdded, TabChanged};
use std::collections::HashSet;

#[test]
fn one_relocation_is_found_in_either_direction_and_two_are_not() {
    assert_eq!(single_relocation(&[1, 2, 3], &[2, 3, 1]), Some(1));
    assert_eq!(single_relocation(&[1, 2, 3], &[3, 1, 2]), Some(3));
    assert_eq!(single_relocation(&[1, 2, 3, 4], &[2, 1, 4, 3]), None);
}

#[test]
fn arrivals_are_added_or_adopted_and_a_pane_that_gains_and_loses_resyncs() {
    let known = HashSet::from([1, 2, 3, 9]);
    assert_eq!(
        pane_changes(&[1, 2], &[7, 1, 9, 2], &known),
        Some(vec![(TabAdded, 7), (TabChanged, 9)])
    );
    assert_eq!(pane_changes(&[1, 2, 3], &[1, 3], &known), Some(Vec::new()));
    assert_eq!(pane_changes(&[1, 2], &[1, 9], &known), None);
    assert_eq!(pane_changes(&[1, 2, 3], &[2, 1, 3, 7], &known), None);
}
