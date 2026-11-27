//! CoreGraphics' rect and point arithmetic, as the Swift it replaces used it
//! (`CGRect` with a top left origin, `CGRect.null` as `None`).

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Size {
    pub w: f64,
    pub h: f64,
}

/// A rect with non-negative size (as `CGRect.standardized`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> Self {
        Self { x, y, w, h }
    }
    pub fn min_x(&self) -> f64 {
        self.x.min(self.x + self.w)
    }
    pub fn min_y(&self) -> f64 {
        self.y.min(self.y + self.h)
    }
    pub fn max_x(&self) -> f64 {
        self.x.max(self.x + self.w)
    }
    pub fn max_y(&self) -> f64 {
        self.y.max(self.y + self.h)
    }
    pub fn width(&self) -> f64 {
        self.w.abs()
    }
    pub fn height(&self) -> f64 {
        self.h.abs()
    }
    pub fn mid_x(&self) -> f64 {
        (self.min_x() + self.max_x()) / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        (self.min_y() + self.max_y()) / 2.0
    }
    /// `CGRect.isEmpty`: zero width or height.
    pub fn is_empty(&self) -> bool {
        self.w == 0.0 || self.h == 0.0
    }
    /// `CGRect.contains(_ point:)`: min edges inclusive, max edges exclusive.
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.min_x() && p.x < self.max_x() && p.y >= self.min_y() && p.y < self.max_y()
    }
    /// `CGRect.insetBy(dx:dy:)`; `None` when it inverts (CGRect.null).
    pub fn inset(&self, dx: f64, dy: f64) -> Option<Rect> {
        let w = self.width() - 2.0 * dx;
        let h = self.height() - 2.0 * dy;
        if w < 0.0 || h < 0.0 {
            return None;
        }
        Some(Rect::new(self.min_x() + dx, self.min_y() + dy, w, h))
    }
    /// `CGRect.intersection`; `None` when they do not meet (CGRect.null).
    /// Touching edges give an empty rect, as CoreGraphics does.
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let left = self.min_x().max(other.min_x());
        let right = self.max_x().min(other.max_x());
        let top = self.min_y().max(other.min_y());
        let bottom = self.max_y().min(other.max_y());
        if right < left || bottom < top {
            return None;
        }
        Some(Rect::new(left, top, right - left, bottom - top))
    }
    /// `CGRect.intersects`: a non-empty intersection.
    pub fn intersects(&self, other: &Rect) -> bool {
        self.intersection(other).is_some_and(|r| !r.is_empty())
    }
    /// `CGRect.union`.
    pub fn union(&self, other: &Rect) -> Rect {
        let left = self.min_x().min(other.min_x());
        let top = self.min_y().min(other.min_y());
        let right = self.max_x().max(other.max_x());
        let bottom = self.max_y().max(other.max_y());
        Rect::new(left, top, right - left, bottom - top)
    }
}

#[cfg(test)]
#[path = "geometry_tests.rs"]
mod tests;
