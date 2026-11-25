//! Gooey tabs (plans/cmux-next/gooey-tabs.md): the levels and their tunings
//! ([`level`]), the closed-form spring tracks that drive a blob's edges
//! ([`track`]), the selection blob and its smooth unions ([`blob`]), the
//! event plans Core Animation plays ([`plan`]) and the drag-out neck
//! ([`drag`]).
//!
//! The goo springs are not motion tokens: Lawrence's rule that every token is
//! critically damped (build.rs) stays, and these tunings are read only under
//! `appearance.gooeyTabs` `subtle` or `full`.
//!
//! Every function is pure (no globals, no allocation) and never panics: a
//! NaN, an infinity, a negative width or an empty buffer gives a finite,
//! well-formed answer. An outline is always [`GOO_OUTLINE_POINTS`] cubics, so
//! any two of them interpolate and the shade's even-odd path keeps a constant
//! element count.

mod blob;
mod drag;
mod level;
mod plan;
mod track;

pub use blob::*;
pub use drag::*;
pub use level::*;
pub use plan::*;
pub use track::*;

/// Cubic segments per outline.
pub const GOO_OUTLINE_POINTS: usize = 24;
/// Points per outline: the move-to, then (c1, c2, p) per segment.
pub const GOO_OUTLINE_LEN: usize = 73;
/// The most keyframes one plan writes.
pub const GOO_KEYFRAMES_MAX: usize = 120;

/// Coordinates are clamped to this magnitude, so every difference stays finite.
pub(crate) const GOO_COORD_MAX: f64 = 1.0e6;

/// A point in the strip's layer coordinates (flipped: y grows down).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    pub(crate) fn add(self, o: Point) -> Point {
        Point::new(self.x + o.x, self.y + o.y)
    }

    pub(crate) fn sub(self, o: Point) -> Point {
        Point::new(self.x - o.x, self.y - o.y)
    }

    pub(crate) fn scale(self, s: f64) -> Point {
        Point::new(self.x * s, self.y * s)
    }

    pub(crate) fn len(self) -> f64 {
        self.x.hypot(self.y)
    }

    pub(crate) fn lerp(self, o: Point, t: f64) -> Point {
        Point::new(self.x + (o.x - self.x) * t, self.y + (o.y - self.y) * t)
    }
}

/// A closed path of [`GOO_OUTLINE_POINTS`] cubics: `p[0]` is the move-to,
/// then `(c1, c2, end)` per segment; the last segment ends at `p[0]`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Outline {
    pub p: [Point; GOO_OUTLINE_LEN],
}

impl Default for Outline {
    fn default() -> Self {
        Self { p: [Point::default(); GOO_OUTLINE_LEN] }
    }
}

impl Outline {
    /// The segment end points (`p[0]`, `p[3]`, ...), one per cubic.
    pub fn anchors(&self) -> impl Iterator<Item = Point> + '_ {
        self.p.iter().step_by(3).take(GOO_OUTLINE_POINTS).copied()
    }

    /// Point `t` (0...1) of every cubic, `per_segment` samples each, in order.
    pub fn for_each_sample(&self, per_segment: usize, mut f: impl FnMut(Point)) {
        let n = per_segment.max(1) as f64;
        let starts = self.p.iter().step_by(3).take(GOO_OUTLINE_POINTS);
        let c1s = self.p.iter().skip(1).step_by(3);
        let c2s = self.p.iter().skip(2).step_by(3);
        let ends = self.p.iter().skip(3).step_by(3);
        for (((a, b), c), d) in starts.zip(c1s).zip(c2s).zip(ends) {
            for i in 0..per_segment.max(1) {
                f(cubic_at(*a, *b, *c, *d, i as f64 / n));
            }
        }
    }

    /// True when every coordinate is finite.
    pub fn is_finite(&self) -> bool {
        self.p.iter().all(|p| p.x.is_finite() && p.y.is_finite())
    }
}

pub(crate) fn cubic_at(a: Point, b: Point, c: Point, d: Point, t: f64) -> Point {
    let u = 1. - t;
    let (w0, w1, w2, w3) = (u * u * u, 3. * u * u * t, 3. * u * t * t, t * t * t);
    Point::new(a.x * w0 + b.x * w1 + c.x * w2 + d.x * w3, a.y * w0 + b.y * w1 + c.y * w2 + d.y * w3)
}

/// `v` when finite (clamped to the coordinate range), else `fallback`.
pub(crate) fn finite_or(v: f64, fallback: f64) -> f64 {
    if v.is_finite() { v.clamp(-GOO_COORD_MAX, GOO_COORD_MAX) } else { fallback }
}

/// A non-negative finite length (`v`, or 0).
pub(crate) fn length_or_zero(v: f64) -> f64 {
    if v.is_finite() { v.clamp(0., GOO_COORD_MAX) } else { 0. }
}

pub(crate) fn clamp01(v: f64) -> f64 {
    if v.is_finite() { v.clamp(0., 1.) } else { 0. }
}
