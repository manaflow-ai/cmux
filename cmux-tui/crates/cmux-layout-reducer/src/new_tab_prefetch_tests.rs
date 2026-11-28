use super::*;
fn size(width: f64, height: f64) -> Size {
    Size { width, height }
}
#[test]
fn new_tab_prefetch_preserves_exact_split_sizes_and_restores_full_page() {
    let full = size(999.5, 700.0);
    let right = size(331.5, 700.0); // an even chain, not half the focused pane
    let down = size(999.5, 332.5); // split chrome is already removed
    assert_eq!(
        plan(Request { parked: full, splits: vec![right, down], cached: vec![full] }),
        vec![right, down, full]
    );
}
#[test]
fn new_tab_prefetch_keeps_nearest_divider_and_bounds_extra_targets() {
    let full = size(999.5, 700.0);
    let right = size(499.25, 700.0);
    let down = size(999.5, 349.5);
    let divider = size(332.5, 700.0);
    let extra = size(200.0, 300.0);
    assert_eq!(
        plan(Request { parked: full, splits: vec![right, down, divider, extra], cached: vec![] }),
        vec![right, down, divider, full]
    );
}
#[test]
fn new_tab_prefetch_cached_sizes_do_no_work() {
    let full = size(900.0, 600.0);
    let split = size(449.5, 600.0);
    assert!(plan(Request { parked: full, splits: vec![split], cached: vec![split] }).is_empty());
}
#[test]
fn new_tab_prefetch_deduplicates_and_rejects_invalid_geometry() {
    let full = size(900.0, 600.0);
    let split = size(449.5, 600.0);
    assert_eq!(
        plan(Request { parked: full, splits: vec![split, split], cached: vec![] }),
        vec![split, full]
    );
    assert!(
        plan(Request {
            parked: full,
            splits: vec![size(0.0, 20.0), size(f64::NAN, 20.0)],
            cached: vec![]
        })
        .is_empty()
    );
}
#[test]
fn new_tab_prefetch_does_not_reuse_a_nearby_size() {
    let full = size(900.0, 600.0);
    let split = size(449.5, 600.0);
    assert_eq!(
        plan(Request { parked: full, splits: vec![split], cached: vec![size(450.0, 600.0)] }),
        vec![split, full]
    );
}
