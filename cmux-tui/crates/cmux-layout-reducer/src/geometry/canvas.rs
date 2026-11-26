//! A screen shown as a canvas (Swift `CmuxNextLayout/Canvas`, plans/cmux-next/canvas-layout.md): the
//! camera and its springs, the arrange commands, a pane drag, the move and resize handles, where a
//! joining pane goes, and the canvas value that holds each pane's frame and the stacking order.
//! Every function is pure; the Swift view owns the state and draws it.
//!
//! An edge-only touch (two rects that share an edge and no area) counts as overlapping through
//! [`Rect::intersection`]; Swift's `CGRect.intersects` is the check this mirrors, and step B confirms
//! the touching case. The vectors keep every pair apart or overlapping.

use super::edge_motion::{Spring, SpringValue};
use super::{Point, Rect, Size, swift_max, swift_min};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::BTreeMap;

/// `CanvasScreen.gap`: space the canvas keeps between panes it places or packs, in canvas points.
pub const GAP: f64 = 16.;
/// `CanvasScreen.defaultPaneSize`: a pane placed with no pane to copy the size of.
pub const DEFAULT_PANE_SIZE: Size = Size { width: 720., height: 450. };
/// `CanvasCamera.zoomRange`.
pub const ZOOM_MIN: f64 = 0.1;
/// `CanvasCamera.zoomRange`.
pub const ZOOM_MAX: f64 = 3.;
/// `CanvasCamera.zoomStep`: one Zoom In or Zoom Out step.
pub const ZOOM_STEP: f64 = 1.25;

/// `CanvasCamera`: the canvas point at the center of the viewport and the zoom (screen points per
/// canvas point, inside the zoom range).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct Camera {
    pub center: Point,
    pub zoom: f64,
}

impl Default for Camera {
    fn default() -> Self {
        Self { center: Point::default(), zoom: 1. }
    }
}

impl Camera {
    /// `init(center:zoom:)`: the zoom clamped to the range; a non-finite one is 1.
    pub fn new(center: Point, zoom: f64) -> Self {
        Self { center, zoom: clamped(zoom) }
    }

    /// `visibleRect(viewport:)`: the canvas rect a viewport of `viewport` screen points shows.
    pub fn visible_rect(&self, viewport: Size) -> Rect {
        let (width, height) = (viewport.width / self.zoom, viewport.height / self.zoom);
        Rect::new(self.center.x - width / 2., self.center.y - height / 2., width, height)
    }

    /// `zoomed(to:around:)`: the camera at `zoom` (clamped) with the canvas point `anchor` where it
    /// showed before; the center stays without one.
    pub fn zoomed_to(&self, zoom: f64, anchor: Option<Point>) -> Self {
        let next = clamped(zoom);
        let Some(anchor) = anchor else {
            return Self::new(self.center, next);
        };
        let keep = self.zoom / next;
        Self::new(
            Point::new(
                anchor.x - (anchor.x - self.center.x) * keep,
                anchor.y - (anchor.y - self.center.y) * keep,
            ),
            next,
        )
    }

    /// `zoomed(by:around:)`: [`Self::zoomed_to`] at this zoom times `factor`.
    pub fn zoomed_by(&self, factor: f64, anchor: Option<Point>) -> Self {
        self.zoomed_to(self.zoom * factor, anchor)
    }

    /// `panned(byScreenDelta:)`: the canvas follows a pointer that moved `delta` screen points.
    pub fn panned(&self, delta: Size) -> Self {
        Self::new(
            Point::new(
                self.center.x - delta.width / self.zoom,
                self.center.y - delta.height / self.zoom,
            ),
            self.zoom,
        )
    }

    /// `revealing(_:viewport:margin:)`: the least move that shows `rect` whole, `margin` screen
    /// points inside the viewport edges; an axis that shows it already stays.
    pub fn revealing(&self, rect: Rect, viewport: Size, margin: f64) -> Self {
        let visible = self.visible_rect(viewport);
        let inset = margin / self.zoom;
        let x = reveal(rect.min_x(), rect.max_x(), inset, visible.min_x(), visible.width());
        let y = reveal(rect.min_y(), rect.max_y(), inset, visible.min_y(), visible.height());
        Self::new(Point::new(x + visible.width() / 2., y + visible.height() / 2.), self.zoom)
    }

    /// `fitting(_:viewport:padding:)`: shows all of `content` with `padding` screen points around
    /// it, never closer than zoom 1.
    pub fn fitting(&self, content: Rect, viewport: Size, padding: f64) -> Self {
        let width = viewport.width - padding * 2.;
        let height = viewport.height - padding * 2.;
        let center = Point::new(content.mid_x(), content.mid_y());
        if content.width() > 0. && content.height() > 0. && width > 0. && height > 0. {
            return Self::new(
                center,
                swift_min(swift_min(1., width / content.width()), height / content.height()),
            );
        }
        Self::new(center, swift_min(self.zoom, 1.))
    }
}

fn clamped(zoom: f64) -> f64 {
    if !zoom.is_finite() {
        return 1.;
    }
    swift_min(swift_max(zoom, ZOOM_MIN), ZOOM_MAX)
}

/// `CanvasCamera.reveal`: the origin on one axis that shows `lower...upper`.
fn reveal(lower: f64, upper: f64, margin: f64, origin: f64, length: f64) -> f64 {
    if lower >= origin && upper <= origin + length {
        return origin;
    }
    let (padded_min, padded_max) = (lower - margin, upper + margin);
    let next = if padded_max - padded_min >= length || padded_min < origin {
        padded_min
    } else {
        padded_max - length
    };
    // A rect that fits without its margin still shows whole; the margin shrinks instead.
    // NaN parity with Swift: `guard upper - lower <= length` turns a NaN span away too.
    match (upper - lower).partial_cmp(&length) {
        Some(Ordering::Less | Ordering::Equal) => swift_min(swift_max(next, upper - length), lower),
        _ => next,
    }
}

/// `CanvasCameraMotion`: the camera shown now, on springs toward its target.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct CameraMotion {
    pub x: SpringValue,
    pub y: SpringValue,
    pub zoom: SpringValue,
}

impl Default for CameraMotion {
    fn default() -> Self {
        Self { x: SpringValue::at(0.), y: SpringValue::at(0.), zoom: SpringValue::at(1.) }
    }
}

impl CameraMotion {
    /// `shown`: the camera shown this frame (its zoom clamped as a camera clamps).
    pub fn shown(&self) -> Camera {
        Camera::new(Point::new(self.x.value, self.y.value), self.zoom.value)
    }

    /// `target`: the camera it moves to.
    pub fn target(&self) -> Camera {
        Camera::new(Point::new(self.x.target, self.y.target), self.zoom.target)
    }

    /// `isMoving`.
    pub fn is_moving(&self) -> bool {
        [self.x, self.y, self.zoom].iter().any(|s| s.value != s.target || s.velocity != 0.)
    }

    /// `retarget(_:animated:)`: moves toward `camera`, or shows it at once.
    pub fn retarget(&mut self, camera: Camera, animated: bool) {
        self.x.target = camera.center.x;
        self.y.target = camera.center.y;
        self.zoom.target = camera.zoom;
        if !animated {
            self.snap();
        }
    }

    /// `snap()`: shows the target at once.
    pub fn snap(&mut self) {
        for s in [&mut self.x, &mut self.y, &mut self.zoom] {
            s.value = s.target;
            s.velocity = 0.;
        }
    }

    /// `advance(_:parameters:)`: true while it still moves.
    pub fn advance(&mut self, dt: f64, spring: Spring) -> bool {
        let a = self.x.advance(dt, spring, 0.25);
        let b = self.y.advance(dt, spring, 0.25);
        let c = self.zoom.advance(dt, spring, 0.0005);
        a || b || c
    }
}

/// `CanvasArrangement`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Arrangement {
    AlignLeft,
    AlignRight,
    AlignTop,
    AlignBottom,
    EqualizeWidths,
    EqualizeHeights,
    DistributeHorizontally,
    DistributeVertically,
    Tidy,
}

type Pane<'a> = (&'a String, Rect);

/// `CanvasArranger.frames(_:in:reference:)`: the frames `command` gives the panes it moves.
/// `reference` is the pane whose width or height the equalize commands copy; without one, the
/// widest or tallest. Empty for fewer than two panes, or when nothing moves.
pub fn arranged(
    command: Arrangement,
    frames: &BTreeMap<String, Rect>,
    reference: Option<&str>,
    gap: f64,
) -> BTreeMap<String, Rect> {
    // A BTreeMap walks in id order, as the Swift sorts by id.
    let panes: Vec<Pane> = frames.iter().map(|(id, frame)| (id, *frame)).collect();
    if panes.len() < 2 {
        return BTreeMap::new();
    }
    let changed = |transform: &dyn Fn(Rect) -> Rect| {
        let mut result = BTreeMap::new();
        for (id, frame) in &panes {
            let next = transform(*frame);
            if next != *frame {
                result.insert((*id).clone(), next);
            }
        }
        result
    };
    let reference = reference.and_then(|id| frames.get(id));
    match command {
        Arrangement::AlignLeft => {
            let x = seq_min(panes.iter().map(|p| p.1.min_x()));
            changed(&|f| Rect::new(x, f.min_y(), f.width(), f.height()))
        }
        Arrangement::AlignRight => {
            let x = seq_max(panes.iter().map(|p| p.1.max_x()));
            changed(&|f| Rect::new(x - f.width(), f.min_y(), f.width(), f.height()))
        }
        Arrangement::AlignTop => {
            let y = seq_min(panes.iter().map(|p| p.1.min_y()));
            changed(&|f| Rect::new(f.min_x(), y, f.width(), f.height()))
        }
        Arrangement::AlignBottom => {
            let y = seq_max(panes.iter().map(|p| p.1.max_y()));
            changed(&|f| Rect::new(f.min_x(), y - f.height(), f.width(), f.height()))
        }
        Arrangement::EqualizeWidths => {
            let width = reference
                .map(Rect::width)
                .unwrap_or_else(|| seq_max(panes.iter().map(|p| p.1.width())));
            changed(&|f| Rect::new(f.min_x(), f.min_y(), width, f.height()))
        }
        Arrangement::EqualizeHeights => {
            let height = reference
                .map(Rect::height)
                .unwrap_or_else(|| seq_max(panes.iter().map(|p| p.1.height())));
            changed(&|f| Rect::new(f.min_x(), f.min_y(), f.width(), height))
        }
        Arrangement::DistributeHorizontally => distributed(&panes, true, gap),
        Arrangement::DistributeVertically => distributed(&panes, false, gap),
        Arrangement::Tidy => tidied(&panes, gap),
    }
}

/// `Sequence.min()` over a non-empty sequence: a later value replaces the result when it is less.
fn seq_min(values: impl Iterator<Item = f64>) -> f64 {
    values
        .fold(None, |acc: Option<f64>, v| Some(acc.map_or(v, |m| if v < m { v } else { m })))
        .unwrap_or(0.)
}

/// `Sequence.max()` over a non-empty sequence: a later value replaces the result when it is greater.
fn seq_max(values: impl Iterator<Item = f64>) -> f64 {
    values
        .fold(None, |acc: Option<f64>, v| Some(acc.map_or(v, |m| if v > m { v } else { m })))
        .unwrap_or(0.)
}

/// An ordering from a Swift `areInIncreasingOrder` predicate.
fn order_by(less: impl Fn(&Pane, &Pane) -> bool) -> impl Fn(&Pane, &Pane) -> Ordering {
    move |a, b| {
        if less(a, b) {
            Ordering::Less
        } else if less(b, a) {
            Ordering::Greater
        } else {
            Ordering::Equal
        }
    }
}

fn distributed(panes: &[Pane], horizontally: bool, gap: f64) -> BTreeMap<String, Rect> {
    let start = |f: &Rect| if horizontally { f.min_x() } else { f.min_y() };
    let mut sorted = panes.to_vec();
    sorted.sort_by(order_by(|a, b| {
        let (l, r) = (start(&a.1), start(&b.1));
        if l != r { l < r } else { a.0 < b.0 }
    }));
    let mut result = BTreeMap::new();
    let Some(first) = sorted.first() else {
        return result;
    };
    let mut cursor = if horizontally { first.1.max_x() } else { first.1.max_y() };
    for (id, frame) in sorted.iter().skip(1) {
        let mut next = *frame;
        if horizontally {
            next.x = cursor + gap;
            cursor = next.max_x();
        } else {
            next.y = cursor + gap;
            cursor = next.max_y();
        }
        if next != *frame {
            result.insert((*id).clone(), next);
        }
    }
    result
}

fn tidied(panes: &[Pane], gap: f64) -> BTreeMap<String, Rect> {
    let origin_x = seq_min(panes.iter().map(|p| p.1.min_x()));
    let origin_y = seq_min(panes.iter().map(|p| p.1.min_y()));
    // A pane joins the current row while its center is above the row's bottom edge.
    let mut sorted = panes.to_vec();
    sorted.sort_by(order_by(|a, b| {
        let (ay, by) = (a.1.mid_y(), b.1.mid_y());
        if ay != by {
            return ay < by;
        }
        let (ax, bx) = (a.1.mid_x(), b.1.mid_x());
        if ax != bx {
            return ax < bx;
        }
        a.0 < b.0
    }));
    let mut rows: Vec<Vec<Pane>> = vec![];
    let mut row_bottom = f64::NEG_INFINITY;
    for pane in sorted {
        if rows.is_empty() || pane.1.mid_y() >= row_bottom {
            row_bottom = pane.1.max_y();
            rows.push(vec![pane]);
        } else {
            row_bottom = swift_max(row_bottom, pane.1.max_y());
            rows.last_mut().expect("a row").push(pane);
        }
    }
    let mut result = BTreeMap::new();
    let mut y = origin_y;
    for mut row in rows {
        row.sort_by(order_by(|a, b| {
            let (ax, bx) = (a.1.mid_x(), b.1.mid_x());
            if ax != bx { ax < bx } else { a.0 < b.0 }
        }));
        let (mut x, mut height) = (origin_x, 0.);
        for (id, frame) in row {
            let next = Rect::new(x, y, frame.width(), frame.height());
            if next != frame {
                result.insert(id.clone(), next);
            }
            x = next.max_x() + gap;
            height = swift_max(height, next.height());
        }
        y += height + gap;
    }
    result
}

/// `CanvasResizeEdges`: left 1, right 2, top 4 (the smaller y), bottom 8. Empty moves the pane.
pub mod resize_edges {
    pub const LEFT: u8 = 1;
    pub const RIGHT: u8 = 2;
    pub const TOP: u8 = 4;
    pub const BOTTOM: u8 = 8;
}

/// `CanvasPaneDrag.frame(translation:)`: the frame of a pane dragged from `start` by `translation`
/// canvas points, moving `edges` (none moves the pane); a resize stops at `minimum`.
pub fn dragged_frame(start: Rect, edges: u8, minimum: Size, translation: Size) -> Rect {
    use resize_edges::*;
    if edges == 0 {
        return start.offset_by(translation.width, translation.height);
    }
    let (mut min_x, mut max_x) = (start.min_x(), start.max_x());
    let (mut min_y, mut max_y) = (start.min_y(), start.max_y());
    if edges & LEFT != 0 {
        min_x = swift_min(start.min_x() + translation.width, max_x - minimum.width);
    }
    if edges & RIGHT != 0 {
        max_x = swift_max(start.max_x() + translation.width, min_x + minimum.width);
    }
    if edges & TOP != 0 {
        min_y = swift_min(start.min_y() + translation.height, max_y - minimum.height);
    }
    if edges & BOTTOM != 0 {
        max_y = swift_max(start.max_y() + translation.height, min_y + minimum.height);
    }
    Rect::new(min_x, min_y, max_x - min_x, max_y - min_y)
}

/// A handle under a point: the pane and the edges it moves (0: the move band).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Handle {
    pub pane: String,
    pub edges: u8,
}

/// `CanvasHandles.hit(_:)`: the handle under `point`, a band `thickness` canvas points wide around
/// each pane; none over a pane or the empty canvas. The front pane takes the point first.
pub fn handle_hit(canvas: &CanvasScreen, thickness: f64, point: Point) -> Option<Handle> {
    use resize_edges::*;
    for pane in canvas.order.iter().rev() {
        let Some(frame) = canvas.frames.get(pane) else { continue };
        if frame.contains(point) {
            return None;
        }
        if !frame.inset_by(-thickness, -thickness).is_some_and(|band| band.contains(point)) {
            continue;
        }
        let mut edges = 0;
        if point.x < frame.min_x() {
            edges |= LEFT;
        }
        if point.x >= frame.max_x() {
            edges |= RIGHT;
        }
        if point.y >= frame.max_y() {
            edges |= BOTTOM;
        }
        // Above the pane: its move band, except at the corners, which resize.
        if point.y < frame.min_y() && edges != 0 {
            edges |= TOP;
        }
        return Some(Handle { pane: pane.clone(), edges });
    }
    None
}

/// `CGRect.union` of two standardized rects.
fn union(a: Rect, b: Rect) -> Rect {
    let (x0, y0) = (a.min_x().min(b.min_x()), a.min_y().min(b.min_y()));
    let (x1, y1) = (a.max_x().max(b.max_x()), a.max_y().max(b.max_y()));
    Rect::new(x0, y0, x1 - x0, y1 - y0)
}

/// `CanvasPlacer.frame(size:near:avoiding:)`: a frame of `size` near `anchor` that overlaps none of
/// `existing`, even within the gap: beside the anchor (right, below, left, above), else the first
/// free slot of an 8 x 16 grid right of it, else right of everything.
pub fn placed_frame(size: Size, anchor: Option<Rect>, existing: &[Rect], gap: f64) -> Rect {
    let Some((first, rest)) = existing.split_first() else {
        let origin = anchor.map_or(Point::default(), |a| Point::new(a.x, a.y));
        return Rect::new(origin.x, origin.y, size.width, size.height);
    };
    let content = rest.iter().fold(*first, |acc, rect| union(acc, *rect));
    let base = anchor.unwrap_or(content);
    let (w, h) = (size.width, size.height);
    let beside = [
        Rect::new(base.max_x() + gap, base.min_y(), w, h),
        Rect::new(base.min_x(), base.max_y() + gap, w, h),
        Rect::new(base.min_x() - gap - w, base.min_y(), w, h),
        Rect::new(base.min_x(), base.min_y() - gap - h, w, h),
    ];
    if let Some(free) = beside.into_iter().find(|c| is_free(*c, existing, gap)) {
        return free;
    }
    for row in 0..8 {
        for column in 0..16 {
            let candidate = Rect::new(
                base.max_x() + gap + f64::from(column) * (w + gap),
                base.min_y() + f64::from(row) * (h + gap),
                w,
                h,
            );
            if is_free(candidate, existing, gap) {
                return candidate;
            }
        }
    }
    Rect::new(content.max_x() + gap, content.min_y(), w, h)
}

fn is_free(candidate: Rect, existing: &[Rect], gap: f64) -> bool {
    // A candidate exactly one gap from a neighbor is free.
    let Some(probe) = candidate.inset_by(-(gap - 0.5), -(gap - 0.5)) else {
        return true;
    };
    !existing.iter().any(|rect| probe.intersection(rect).is_some())
}

/// `CanvasScreen`: each pane's frame in canvas points, the stacking order (back to front) and the
/// camera.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CanvasScreen {
    pub frames: BTreeMap<String, Rect>,
    pub order: Vec<String>,
    #[serde(default)]
    pub camera: Camera,
}

impl CanvasScreen {
    /// `init(frames:order:camera:)`: the known order first, then the other panes by id.
    pub fn new(frames: BTreeMap<String, Rect>, order: Option<Vec<String>>, camera: Camera) -> Self {
        let known: Vec<String> =
            order.unwrap_or_default().into_iter().filter(|id| frames.contains_key(id)).collect();
        let rest: Vec<String> = frames.keys().filter(|id| !known.contains(id)).cloned().collect();
        Self { order: known.into_iter().chain(rest).collect(), frames, camera }
    }

    /// `init(seed:viewport:)`: the frames where they show now, a zoom-1 camera on the viewport's
    /// center.
    pub fn seeded(frames: BTreeMap<String, Rect>, viewport: Size) -> Self {
        let center = Point::new(viewport.width / 2., viewport.height / 2.);
        Self::new(frames, None, Camera::new(center, 1.))
    }

    /// `contentBounds`: the smallest rect around every pane; none for an empty canvas.
    pub fn content_bounds(&self) -> Option<Rect> {
        self.frames.values().fold(None, |acc, frame| Some(acc.map_or(*frame, |b| union(b, *frame))))
    }

    /// `pane(at:)`: the front-most pane whose frame contains `point`.
    pub fn pane_at(&self, point: Point) -> Option<&str> {
        self.order
            .iter()
            .rev()
            .find(|id| self.frames.get(*id).is_some_and(|f| f.contains(point)))
            .map(String::as_str)
    }

    /// `setFrames(_:)`: panes not on the canvas are ignored (`setFrame(_:for:)` is one of these).
    pub fn set_frames(&mut self, updates: &BTreeMap<String, Rect>) {
        for (pane, frame) in updates {
            if let Some(slot) = self.frames.get_mut(pane) {
                *slot = *frame;
            }
        }
    }

    /// `bringToFront(_:)`.
    pub fn bring_to_front(&mut self, pane: &str) {
        let Some(index) = self.order.iter().position(|id| id == pane) else { return };
        if index == self.order.len() - 1 {
            return;
        }
        let id = self.order.remove(index);
        self.order.push(id);
    }

    /// `reconcile(panes:anchor:)`: the canvas holds exactly `panes`; frames of panes not in it drop,
    /// and each pane new to it gets a free frame beside `anchor`, the anchor's size, in front.
    /// Returns whether anything changed.
    pub fn reconcile(&mut self, panes: &[String], anchor: Option<&str>) -> bool {
        let gone: Vec<String> =
            self.frames.keys().filter(|id| !panes.contains(id)).cloned().collect();
        let added: Vec<String> =
            panes.iter().filter(|id| !self.frames.contains_key(*id)).cloned().collect();
        if gone.is_empty() && added.is_empty() {
            return false;
        }
        for pane in &gone {
            self.frames.remove(pane);
        }
        self.order.retain(|id| panes.contains(id));
        let mut near = anchor.and_then(|id| self.frames.get(id)).copied();
        for pane in added {
            let size = near
                .or_else(|| self.order.last().and_then(|id| self.frames.get(id)).copied())
                .map_or(DEFAULT_PANE_SIZE, |r| Size { width: r.w, height: r.h });
            let existing: Vec<Rect> = self.frames.values().copied().collect();
            let frame = placed_frame(size, near, &existing, GAP);
            self.frames.insert(pane.clone(), frame);
            self.order.push(pane);
            near = Some(frame);
        }
        true
    }
}
