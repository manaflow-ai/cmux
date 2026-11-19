//! The exact tiling rule of a screen (F2), checked at each commit of a layout.
//!
//! A commit is one placement of a screen: every rectangle the window shows at once. Its tiled
//! rectangles (the panes and the chrome between them: dividers) must cover the viewport exactly,
//! with no gap, no overlap and nothing outside, and every edge must lie on a device pixel at the
//! commit's scale. A floating rectangle (a floating pane, a popup) is above the tiled set and no
//! part of the tiling; it must be inside the viewport.
//!
//! [`Checker::check`] decides the rule in time linear in the number of rectangles (a parity table of
//! their corners), with no allocation once its buffers have grown: the tiled rectangles cover the
//! viewport exactly if and only if their areas add up to the viewport's area and every corner
//! point occurs an even number of times among their corners, except the viewport's own four,
//! which occur an odd number of times. (Proof: a rectangle's indicator modulo 2 is the sum of the
//! four quadrant indicators at its corners, and quadrant indicators are independent over GF(2).
//! So the corner condition makes the cover count odd inside the viewport and even outside it.
//! Odd is at least 1, so the area condition leaves it exactly 1 inside and 0 outside.) Only a
//! commit that breaks the rule pays for [`Checker::explain`], which names an overlapping pair or
//! the uncovered area.
//!
//! [`commit`] is the hook a producer calls with each state it makes. In a debug or test build a
//! broken rule fails loudly (a debug assertion); in a release build the commit is counted
//! ([`stats`]) and nothing panics. The rule and its check are ported from the frame engine's
//! `check` (rules F2 and its floating part, cmux-fp ARCHITECTURE sections 1 and 7).

use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};

/// How far an edge, in device pixels, may be from a whole pixel and still be on it: the float
/// error of a point value times a scale such as 1.5, many orders below a visible fraction.
pub const PIXEL_EPSILON: f64 = 1e-6;

/// A rectangle in points, as the layout makes it (`CGRect`: origin and size, top-left origin).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct RectPt {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl RectPt {
    pub const fn new(x: f64, y: f64, w: f64, h: f64) -> RectPt {
        RectPt { x, y, w, h }
    }

    /// The rect as the screen places a frame that may be between pixels (a spring's frame, a frame
    /// under a camera offset): each edge on its own to the nearest device pixel, a tie up (Swift
    /// `CGRect.pixelEdges` in `ScreenContentView+Motion`). Two rects that share an edge share it
    /// after, and a rect whose edges are whole pixels apart keeps its size under any shift.
    pub fn pixel_edges(self, scale: f64) -> RectPt {
        if scale <= 0.0 {
            return self;
        }
        let edge = |value: f64| (value * scale + 0.5).floor() / scale;
        // `CGRect.minX` and `maxX` standardize: a negative width counts from the other edge.
        let (min_x, max_x) = (self.x.min(self.x + self.w), self.x.max(self.x + self.w));
        let (min_y, max_y) = (self.y.min(self.y + self.h), self.y.max(self.y + self.h));
        let (x0, x1) = (edge(min_x), edge(max_x));
        let (y0, y1) = (edge(min_y), edge(max_y));
        RectPt { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    }
}

/// A rectangle in whole device pixels.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct RectPx {
    pub x0: i64,
    pub y0: i64,
    pub x1: i64,
    pub y1: i64,
}

impl RectPx {
    pub fn is_empty(&self) -> bool {
        self.x1 <= self.x0 || self.y1 <= self.y0
    }

    pub fn area(&self) -> u128 {
        if self.is_empty() {
            return 0;
        }
        (self.x1 - self.x0) as u128 * (self.y1 - self.y0) as u128
    }

    fn overlaps(&self, other: &RectPx) -> bool {
        self.x0 < other.x1 && other.x0 < self.x1 && self.y0 < other.y1 && other.y0 < self.y1
    }

    fn within(&self, w: i64, h: i64) -> bool {
        self.x0 >= 0 && self.y0 >= 0 && self.x1 <= w && self.y1 <= h
    }
}

/// One commit of a screen: its viewport in points, its scale (device pixels per point) and its
/// rectangles in the viewport's coordinates.
#[derive(Clone, Copy, Debug)]
pub struct Frame<'a> {
    pub width: f64,
    pub height: f64,
    pub scale: f64,
    /// The panes and the chrome that tiles with them.
    pub tiled: &'a [RectPt],
    /// Rectangles above the tiled set.
    pub floating: &'a [RectPt],
}

/// Which list a rectangle of a [`Fault`] is in.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Set {
    Tiled,
    Floating,
}

/// A broken rule: the first one the check meets.
#[derive(Clone, Debug, PartialEq)]
pub enum Fault {
    /// The scale is not a finite positive number.
    Scale(f64),
    /// The viewport is not a whole number of device pixels, or is not finite.
    Viewport { width_px: f64, height_px: f64 },
    /// A value of a rectangle is not finite, or its size is negative.
    Malformed { set: Set, index: usize },
    /// An edge of a rectangle is not on a device pixel (`edge_px` is where it is).
    OffPixel { set: Set, index: usize, edge_px: f64 },
    /// A rectangle reaches outside the viewport.
    Outside { set: Set, index: usize },
    /// Two tiled rectangles overlap.
    Overlap { a: usize, b: usize },
    /// Part of the viewport has no tiled rectangle: this many device pixels.
    Gap { pixels: u128 },
    /// The cover is not exact and the explanation found neither an overlap nor a gap. It cannot
    /// happen (the corner condition is exact); a fault of the check itself would show as this.
    Inexact,
}

impl Fault {
    /// A short stable name for a metric.
    pub fn kind(&self) -> &'static str {
        match self {
            Fault::Scale(_) => "scale",
            Fault::Viewport { .. } => "viewport",
            Fault::Malformed { .. } => "malformed",
            Fault::OffPixel { .. } => "off_pixel",
            Fault::Outside { .. } => "outside",
            Fault::Overlap { .. } => "overlap",
            Fault::Gap { .. } => "gap",
            Fault::Inexact => "inexact",
        }
    }
}

impl fmt::Display for Fault {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Fault::Scale(scale) => write!(f, "scale {scale} is not a positive number"),
            Fault::Viewport { width_px, height_px } => {
                write!(f, "viewport {width_px}x{height_px} px is not whole device pixels")
            }
            Fault::Malformed { set, index } => write!(f, "{set:?} rect {index} is not finite"),
            Fault::OffPixel { set, index, edge_px } => {
                write!(f, "{set:?} rect {index} has an edge at {edge_px} px, off the pixel grid")
            }
            Fault::Outside { set, index } => write!(f, "{set:?} rect {index} reaches outside"),
            Fault::Overlap { a, b } => write!(f, "tiled rects {a} and {b} overlap"),
            Fault::Gap { pixels } => write!(f, "{pixels} device pixels have no tiled rect"),
            Fault::Inexact => write!(f, "the cover is not exact"),
        }
    }
}

/// The F2 check with its buffers, reused from commit to commit.
#[derive(Clone, Debug, Default)]
pub struct Checker {
    px: Vec<RectPx>,
    /// The parity of each corner point (an open-addressing table at most half full). A slot is of this
    /// check when its `generation` is the check's, so a check clears nothing.
    slots: Vec<Slot>,
    generation: u32,
    odd: usize,
}

#[derive(Clone, Copy, Debug, Default)]
struct Slot {
    x: i64,
    y: i64,
    /// The check that wrote it (0: none).
    generation: u32,
    odd: bool,
}

/// An edge in device pixels, or where it is when it is off the grid.
fn to_px(value: f64, scale: f64) -> Result<i64, f64> {
    let px = value * scale;
    let whole = px.round();
    if (px - whole).abs() <= PIXEL_EPSILON && whole.abs() < 1e15 {
        Ok(whole as i64)
    } else {
        Err(px)
    }
}

fn rect_px(rect: &RectPt, scale: f64, set: Set, index: usize) -> Result<RectPx, Fault> {
    let RectPt { x, y, w, h } = *rect;
    if !(x.is_finite() && y.is_finite() && w.is_finite() && h.is_finite()) || w < 0.0 || h < 0.0 {
        return Err(Fault::Malformed { set, index });
    }
    let edge =
        |value: f64| to_px(value, scale).map_err(|edge_px| Fault::OffPixel { set, index, edge_px });
    // The edges as `CGRect` gives them (`minX`, `maxX`): a right edge is x plus width.
    Ok(RectPx { x0: edge(x)?, y0: edge(y)?, x1: edge(x + w)?, y1: edge(y + h)? })
}

impl Checker {
    pub fn new() -> Checker {
        Checker::default()
    }

    /// Whether `frame` obeys F2, or the first fault found.
    pub fn check(&mut self, frame: &Frame<'_>) -> Result<(), Fault> {
        let scale = frame.scale;
        if !(scale.is_finite() && scale > 0.0) {
            return Err(Fault::Scale(scale));
        }
        let viewport = (to_px(frame.width, scale), to_px(frame.height, scale));
        let (Ok(w), Ok(h)) = viewport else {
            return Err(Fault::Viewport {
                width_px: frame.width * scale,
                height_px: frame.height * scale,
            });
        };
        if w < 0 || h < 0 {
            return Err(Fault::Viewport {
                width_px: frame.width * scale,
                height_px: frame.height * scale,
            });
        }
        for (index, rect) in frame.floating.iter().enumerate() {
            let RectPt { x, y, w: rw, h: rh } = *rect;
            if !(x.is_finite() && y.is_finite() && rw.is_finite() && rh.is_finite())
                || rw < 0.0
                || rh < 0.0
            {
                return Err(Fault::Malformed { set: Set::Floating, index });
            }
            // Inside, measured in device pixels with the same slack as an edge.
            let slack = PIXEL_EPSILON;
            if x * scale < -slack
                || y * scale < -slack
                || (x + rw) * scale > w as f64 + slack
                || (y + rh) * scale > h as f64 + slack
            {
                return Err(Fault::Outside { set: Set::Floating, index });
            }
        }
        self.px.clear();
        let slots = (frame.tiled.len() * 8).next_power_of_two().max(16);
        if self.slots.len() < slots || self.generation == u32::MAX {
            self.slots.clear();
            self.slots.resize(slots, Slot::default());
            self.generation = 0;
        }
        self.generation += 1;
        self.odd = 0;
        let mut area: u128 = 0;
        for (index, rect) in frame.tiled.iter().enumerate() {
            let px = rect_px(rect, scale, Set::Tiled, index)?;
            if px.is_empty() {
                // A rect of no area owns no pixel; it neither covers nor overlaps.
                self.px.push(px);
                continue;
            }
            if !px.within(w, h) {
                return Err(Fault::Outside { set: Set::Tiled, index });
            }
            area += px.area();
            self.px.push(px);
            for (x, y) in [(px.x0, px.y0), (px.x1, px.y0), (px.x0, px.y1), (px.x1, px.y1)] {
                self.toggle(x, y);
            }
        }
        let full = w as u128 * h as u128;
        if area == full && self.corners_are_the_viewports(w, h) {
            return Ok(());
        }
        Err(self.explain(w, h, area))
    }

    /// Toggles the parity of corner point `(x, y)` in the table: open addressing, a slot is never
    /// freed within one check, and `odd` counts the points seen an odd number of times.
    fn toggle(&mut self, x: i64, y: i64) {
        let (mask, generation) = (self.slots.len() - 1, self.generation);
        let hash = (x as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
            ^ (y as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F);
        let mut i = (hash ^ (hash >> 29)) as usize & mask;
        loop {
            let Some(slot) = self.slots.get_mut(i) else { return };
            if slot.generation != generation {
                *slot = Slot { x, y, generation, odd: true };
                self.odd += 1;
                return;
            }
            if slot.x == x && slot.y == y {
                slot.odd = !slot.odd;
                if slot.odd {
                    self.odd += 1;
                } else {
                    self.odd -= 1;
                }
                return;
            }
            i = (i + 1) & mask;
        }
    }

    fn is_odd(&self, x: i64, y: i64) -> bool {
        let (mask, generation) = (self.slots.len() - 1, self.generation);
        let hash = (x as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15)
            ^ (y as u64).wrapping_mul(0xC2B2_AE3D_27D4_EB4F);
        let mut i = (hash ^ (hash >> 29)) as usize & mask;
        while let Some(slot) = self.slots.get(i) {
            if slot.generation != generation {
                return false;
            }
            if slot.x == x && slot.y == y {
                return slot.odd;
            }
            i = (i + 1) & mask;
        }
        false
    }

    /// The corner condition: the viewport's four corners an odd number of times, every other point
    /// an even number of times.
    fn corners_are_the_viewports(&self, w: i64, h: i64) -> bool {
        if w == 0 || h == 0 {
            return self.odd == 0;
        }
        self.odd == 4 && [(0, 0), (0, h), (w, 0), (w, h)].iter().all(|&(x, y)| self.is_odd(x, y))
    }

    /// Why a cover that is not exact is not: an overlapping pair, else the uncovered area. Runs
    /// only for a commit that breaks the rule.
    fn explain(&self, w: i64, h: i64, area: u128) -> Fault {
        for (a, ra) in self.px.iter().enumerate() {
            if ra.is_empty() {
                continue;
            }
            for (b, rb) in self.px.iter().enumerate().skip(a + 1) {
                if !rb.is_empty() && ra.overlaps(rb) {
                    return Fault::Overlap { a, b };
                }
            }
        }
        let full = w as u128 * h as u128;
        if area < full {
            return Fault::Gap { pixels: full - area };
        }
        Fault::Inexact
    }
}

static COMMITS: AtomicU64 = AtomicU64::new(0);
static FAULTS: AtomicU64 = AtomicU64::new(0);
static OFF_PIXEL: AtomicU64 = AtomicU64::new(0);
static OVERLAP: AtomicU64 = AtomicU64::new(0);
static GAP: AtomicU64 = AtomicU64::new(0);
static OUTSIDE: AtomicU64 = AtomicU64::new(0);

/// What [`commit`] counted in this process.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Stats {
    /// Commits checked.
    pub commits: u64,
    /// Commits that broke F2, and of them by the first fault's kind.
    pub faults: u64,
    pub off_pixel: u64,
    pub overlap: u64,
    pub gap: u64,
    pub outside: u64,
}

/// The process's counts of checked and faulty commits (the release metric).
pub fn stats() -> Stats {
    Stats {
        commits: COMMITS.load(Ordering::Relaxed),
        faults: FAULTS.load(Ordering::Relaxed),
        off_pixel: OFF_PIXEL.load(Ordering::Relaxed),
        overlap: OVERLAP.load(Ordering::Relaxed),
        gap: GAP.load(Ordering::Relaxed),
        outside: OUTSIDE.load(Ordering::Relaxed),
    }
}

/// Checks one commit of a producer and counts it. A fault fails a debug or test build loudly
/// (debug assertion) and is counted in a release build, which never panics here.
pub fn commit(checker: &mut Checker, frame: &Frame<'_>) -> Result<(), Fault> {
    COMMITS.fetch_add(1, Ordering::Relaxed);
    let result = checker.check(frame);
    if let Err(fault) = &result {
        FAULTS.fetch_add(1, Ordering::Relaxed);
        let counter = match fault {
            Fault::OffPixel { .. } => Some(&OFF_PIXEL),
            Fault::Overlap { .. } => Some(&OVERLAP),
            Fault::Gap { .. } => Some(&GAP),
            Fault::Outside { .. } => Some(&OUTSIDE),
            _ => None,
        };
        if let Some(counter) = counter {
            counter.fetch_add(1, Ordering::Relaxed);
        }
    }
    debug_assert!(
        result.is_ok(),
        "F2 exact tiling broken at a layout commit: {result:?} ({frame:?})"
    );
    result
}

#[cfg(test)]
#[path = "tiling_tests.rs"]
mod tests;
