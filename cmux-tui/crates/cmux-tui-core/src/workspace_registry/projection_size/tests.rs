use super::*;

#[test]
fn the_half_bound_warning_fires_once_when_the_size_crosses_it() {
    let half = MAX_PROJECTION_BYTES / 2;
    assert!(crosses_half_of_the_bound(None, half + 1));
    assert!(crosses_half_of_the_bound(Some(half), half + 1));
    assert!(!crosses_half_of_the_bound(Some(half + 1), half + 2));
    assert!(!crosses_half_of_the_bound(Some(10), half));
}
