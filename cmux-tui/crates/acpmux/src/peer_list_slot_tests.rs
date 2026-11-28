use super::*;

#[test]
fn instances_hold_their_own_lists_and_only_their_newest_marker_takes_rows() {
    let a = ListSlot::default();
    let b = ListSlot::default();
    let old = a.hold(vec![Arc::from("old")]);
    let other = b.hold(vec![Arc::from("other")]);
    let new = a.hold(vec![Arc::from("new")]);
    assert!(a.take(old).is_none());
    assert_eq!(a.take(new), Some(vec![Arc::from("new")]));
    assert_eq!(b.take(other), Some(vec![Arc::from("other")]));
    assert!(a.take(new).is_none());
}
