//! Idle New Tab frame preparation: one renderer, exact target sizes, then restore Cmd-T's size.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

impl Size {
    fn valid(self) -> bool {
        self.width.is_finite() && self.height.is_finite() && self.width > 0.0 && self.height > 0.0
    }
}

#[derive(Deserialize)]
pub struct Request {
    pub parked: Size,
    pub splits: Vec<Size>,
    pub cached: Vec<Size>,
}

/// Geometry comes from the same split prediction as the drop preview. Never approximate, round,
/// or stretch: a half-pixel difference is a different frame. At most right/down and the restore.
pub fn plan(request: Request) -> Vec<Size> {
    if !request.parked.valid() {
        return vec![];
    }
    let mut sizes = Vec::with_capacity(3);
    for size in request.splits.into_iter().take(2) {
        if size.valid()
            && size != request.parked
            && !request.cached.contains(&size)
            && !sizes.contains(&size)
        {
            sizes.push(size);
        }
    }
    if !sizes.is_empty() {
        sizes.push(request.parked);
    }
    sizes
}

#[cfg(test)]
mod tests {
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
    fn new_tab_prefetch_cached_sizes_do_no_work() {
        let full = size(900.0, 600.0);
        let split = size(449.5, 600.0);
        assert!(
            plan(Request { parked: full, splits: vec![split], cached: vec![split] }).is_empty()
        );
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
}
