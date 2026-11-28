//! The screen viewer's pure core, shared by the Mac and iOS apps
//! (`Packages/Shared/CmuxScreenKit`): the trackpad gesture, pointer
//! acceleration and click snapping, Follow mode's camera framing, the
//! scroll view's fit, centre, clamp, paging and cursor-follow math, the
//! streamed cursor's placement and shape cache, the session's reconnect
//! policy and the trackpad hint's pose. The Swift views keep their
//! recognizers and drawing and ask this core what to do.
//!
//! No I/O; every function that needs time takes it as an argument (seconds,
//! any one clock). Geometry is `f64` points, origin top left, as UIKit and
//! AppKit's flipped views use it.

pub mod cursor;
#[cfg(feature = "c-abi")]
pub mod ffi;
pub mod framing;
pub mod hint;
pub mod reconnect;
pub mod trackpad;
pub mod viewport;

/// A point (`CGPoint`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A size (`CGSize`).
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// A rectangle (`CGRect`) with a non-negative size.
#[repr(C)]
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }
}

impl Size {
    pub const fn new(width: f64, height: f64) -> Self {
        Self { width, height }
    }
}

impl Rect {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0, 0.0);

    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub const fn from_size(size: Size) -> Self {
        Self::new(0.0, 0.0, size.width, size.height)
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    pub fn size(&self) -> Size {
        Size::new(self.width, self.height)
    }

    /// The overlap of two rectangles; `None` where they do not overlap
    /// with a positive area (`CGRect.intersection` null or empty).
    pub fn intersection(&self, other: &Self) -> Option<Self> {
        let x = self.x.max(other.x);
        let y = self.y.max(other.y);
        let width = self.max_x().min(other.max_x()) - x;
        let height = self.max_y().min(other.max_y()) - y;
        (width > 0.0 && height > 0.0).then(|| Self::new(x, y, width, height))
    }
}
