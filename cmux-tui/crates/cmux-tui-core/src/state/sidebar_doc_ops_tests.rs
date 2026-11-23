use super::*;

/// Unpin moves a pinned tree, closed members and all, back into its machine
/// section; the close that follows removes them and the groups they empty,
/// as closing the last workspace does there (a283, pinning-DESIGN.md).
#[test]
fn unpin_and_reset_close_what_is_not_open() {
    assert!(returns_closed_items(&[Op::Reset]));
    assert!(returns_closed_items(&[Op::Unpin { items: vec!["g".into()] }]));
    assert!(!returns_closed_items(&[Op::Pin { items: vec!["g".into()] }]));
}
