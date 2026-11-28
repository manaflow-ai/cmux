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
/// or stretch: a half-pixel difference is a different frame. At most right/down/nearest-divider sizes and the restore.
pub fn plan(request: Request) -> Vec<Size> {
    if !request.parked.valid() {
        return vec![];
    }
    let mut sizes = Vec::with_capacity(4);
    for size in request.splits.into_iter().take(3) {
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
#[path = "new_tab_prefetch_tests.rs"]
mod tests;
