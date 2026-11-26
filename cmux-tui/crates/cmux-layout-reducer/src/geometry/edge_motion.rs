//! A drag moves pane and divider edges, never whole frames (Swift `SharedEdgeMotion`, rule D of
//! the frame owner refactor): the edge arithmetic of a frame's springs, what a press catches, how
//! far each edge moves with the drag's value, and whether a pane's size spring could show it under
//! its minimum. The view (`ScreenContentView`) still owns the springs and reads the screen; these
//! are the numbers it computes from them.

use super::screen::{ScreenGeometry, ScreenLayout, ScreenStyle};
use super::split_layout::{self, PointerRatio};
use super::{DockEdge, Rect, Size, SplitAxis};
use crate::shown_resize;
use cmux_motion::{SpringParameters, advance_spring};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Swift `SpringValue`: where a value shows, how fast it moves, where it goes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SpringValue {
    pub value: f64,
    #[serde(default)]
    pub velocity: f64,
    pub target: f64,
}

impl SpringValue {
    pub const fn at(value: f64) -> Self {
        Self { value, velocity: 0., target: value }
    }

    /// `SpringValue.step(_:parameters:)`: the velocity admitted toward the target, then one step
    /// of the cmux-motion spring (`cmux_motion_step`, epsilon 0).
    pub fn step(&mut self, dt: f64, spring: Spring) {
        self.velocity = spring.admitted(self.velocity, self.target - self.value);
        advance_spring(
            &mut self.value,
            &mut self.velocity,
            self.target,
            dt,
            SpringParameters::new(spring.response, spring.damping_fraction),
            0.,
        );
    }

    fn snap_to(&mut self, target: f64) {
        self.target = target;
        self.value = target;
        self.velocity = 0.;
    }
}

/// Swift `SpringParameters` (response and damping fraction).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spring {
    pub response: f64,
    pub damping_fraction: f64,
}

impl Spring {
    fn omega(self) -> f64 {
        2. * std::f64::consts::PI / self.response.max(0.001)
    }

    /// `SpringParameters.admitted(velocity:distance:)`: a velocity that would carry the value past
    /// its target faster than the spring can turn it is cut to what the spring turns.
    pub fn admitted(self, velocity: f64, distance: f64) -> f64 {
        if velocity == 0. {
            return 0.;
        }
        let limit = self.omega() * distance.abs();
        if distance > 0. {
            return velocity.max(0.).min(limit);
        }
        if distance < 0. {
            return velocity.min(0.).max(-limit);
        }
        0.
    }
}

/// Swift `AnimatedFrame`: a frame as five springs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct AnimatedFrame {
    pub x: SpringValue,
    pub y: SpringValue,
    pub width: SpringValue,
    pub height: SpringValue,
    pub alpha: SpringValue,
}

impl AnimatedFrame {
    pub fn new(rect: Rect) -> Self {
        Self {
            x: SpringValue::at(rect.min_x()),
            y: SpringValue::at(rect.min_y()),
            width: SpringValue::at(rect.width()),
            height: SpringValue::at(rect.height()),
            alpha: SpringValue::at(1.),
        }
    }

    pub fn target_rect(&self) -> Rect {
        Rect { x: self.x.target, y: self.y.target, w: self.width.target, h: self.height.target }
    }

    fn set_target(&mut self, rect: Rect) {
        self.x.target = rect.min_x();
        self.y.target = rect.min_y();
        self.width.target = rect.width();
        self.height.target = rect.height();
    }
}

/// `SharedEdgeMotion.Edges`: one axis of a frame as its two edges.
#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Edges {
    pub low: f64,
    pub low_speed: f64,
    pub low_target: f64,
    pub high: f64,
    pub high_speed: f64,
    pub high_target: f64,
}

impl Edges {
    pub fn new(start: SpringValue, extent: SpringValue) -> Self {
        Self {
            low: start.value,
            low_speed: start.velocity,
            low_target: start.target,
            high: start.value + extent.value,
            high_speed: start.velocity + extent.velocity,
            high_target: start.target + extent.target,
        }
    }

    /// Writes the edges back as a start and an extent (same targets).
    pub fn write(&self, start: &mut SpringValue, extent: &mut SpringValue) {
        (start.value, start.velocity, start.target) = (self.low, self.low_speed, self.low_target);
        (extent.value, extent.velocity, extent.target) = (
            self.high - self.low,
            self.high_speed - self.low_speed,
            self.high_target - self.low_target,
        );
    }
}

/// `SharedEdgeMotion.place(_:at:keepsShown:)`: sets `frame`'s target during a pointer gesture
/// that does not animate. The press's pass (`keeps_shown`) keeps where every component shows and
/// its velocity; every other pass moves each component by as much as its target. A retargeted
/// frame turns opaque at once.
pub fn place(frame: &mut AnimatedFrame, target: Rect, keeps_shown: bool) {
    let retargeted = frame.target_rect() != target;
    if keeps_shown {
        frame.set_target(target);
    } else {
        shift(&mut frame.x, target.min_x());
        shift(&mut frame.y, target.min_y());
        shift(&mut frame.width, target.width());
        shift(&mut frame.height, target.height());
    }
    if retargeted {
        frame.alpha.snap_to(1.);
    } else {
        frame.alpha.target = 1.;
    }
}

/// `SharedEdgeMotion.shift`: retargets `value` and moves it by as much as its target moved, its
/// velocity kept; at rest it lands on the new target exactly.
fn shift(value: &mut SpringValue, target: f64) {
    let delta = target - value.target;
    if delta == 0. {
        return;
    }
    let resting = value.velocity == 0. && value.value == value.target;
    value.target = target;
    value.value = if resting { target } else { value.value + delta };
}

/// `SharedEdgeMotion.MovedEdges`: the edges a layout change moved for one frame. A frame with no
/// target before is new and moved none.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MovedEdges {
    pub min_x: bool,
    pub max_x: bool,
    pub min_y: bool,
    pub max_y: bool,
}

impl MovedEdges {
    pub fn new(before: Option<Rect>, after: Rect) -> Self {
        let Some(before) = before else { return Self::default() };
        Self {
            min_x: before.min_x() != after.min_x(),
            max_x: before.max_x() != after.max_x(),
            min_y: before.min_y() != after.min_y(),
            max_y: before.max_y() != after.max_y(),
        }
    }

    pub fn any(&self) -> bool {
        self.min_x || self.max_x || self.min_y || self.max_y
    }
}

/// `SharedEdgeMotion.seed`: a release fling starts every edge the release moved with `rate` (a
/// fraction of its travel per second); an edge it did not move keeps its spring's velocity.
pub fn seed(frame: &mut AnimatedFrame, moved: MovedEdges, rate: f64) {
    if !moved.any() {
        return;
    }
    seed_axis(&mut frame.x, &mut frame.width, moved.min_x, moved.max_x, rate);
    seed_axis(&mut frame.y, &mut frame.height, moved.min_y, moved.max_y, rate);
}

fn seed_axis(start: &mut SpringValue, extent: &mut SpringValue, low: bool, high: bool, rate: f64) {
    if !low && !high {
        return;
    }
    let mut edges = Edges::new(*start, *extent);
    if low {
        edges.low_speed = (edges.low_target - edges.low) * rate;
    }
    if high {
        edges.high_speed = (edges.high_target - edges.high) * rate;
    }
    edges.write(start, extent);
}

/// `DividerHandleView.Kind`: the line a press grabs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum HandleKind {
    Split { id: String },
    ColumnEdge { id: String },
    RowEdge { column: String, upper: String },
}

/// `SharedEdgeMotion.ShownPixels`: where the screen draws a value along the axis (the view
/// offset `shift` between the geometry and the view, and the backing scale).
#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
pub struct ShownPixels {
    #[serde(default)]
    pub shift: f64,
    pub scale: f64,
}

impl ShownPixels {
    /// `edge(_:)`: the device pixel the screen draws `value` on, rounded as Core Animation
    /// rounds a layer edge.
    pub fn edge(&self, value: f64) -> f64 {
        if !(self.scale > 0.) {
            return value;
        }
        ((value + self.shift) * self.scale + 0.5).floor() / self.scale - self.shift
    }
}

/// `SharedEdgeMotion.Hold`: the line as its spring shows it, the pixel it is drawn on, and
/// whether it moves.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hold {
    pub value: f64,
    pub drawn: f64,
    pub velocity: f64,
    pub moves: bool,
}

impl Hold {
    pub fn new(line: f64, spring: SpringValue, shown: ShownPixels) -> Self {
        let value = line + spring.value - spring.target;
        Self {
            value,
            drawn: shown.edge(value),
            velocity: spring.velocity,
            moves: (spring.value - spring.target).abs() > 0.001 || spring.velocity.abs() > 0.001,
        }
    }
}

/// `SharedEdgeMotion.restLine`: where the layout rests the dragged line along `axis` (`None`
/// for a row edge or a line the geometry lacks).
pub fn rest_line(kind: &HandleKind, axis: SplitAxis, geometry: &ScreenGeometry) -> Option<f64> {
    match kind {
        HandleKind::Split { id } => {
            let divider = geometry.dividers.iter().find(|divider| &divider.id == id)?;
            Some(if axis == SplitAxis::Horizontal {
                divider.frame.min_x()
            } else {
                divider.frame.min_y()
            })
        }
        HandleKind::ColumnEdge { id } => {
            let frame = geometry.columns.get(id)?;
            Some(column_line(dock_edge(geometry, id), frame).0)
        }
        HandleKind::RowEdge { .. } => None,
    }
}

fn dock_edge(geometry: &ScreenGeometry, column: &str) -> Option<DockEdge> {
    geometry.column_edges.iter().find(|edge| edge.column == column).and_then(|edge| edge.dock_edge)
}

/// A column edge's dragged line, its anchor across the column, and which way the column's
/// extent grows from it.
fn column_line(edge: Option<DockEdge>, frame: &Rect) -> (f64, f64, f64) {
    match edge {
        Some(DockEdge::Right) => (frame.min_x(), frame.max_x(), -1.),
        Some(DockEdge::Top) => (frame.max_y(), frame.min_y(), 1.),
        Some(DockEdge::Bottom) => (frame.min_y(), frame.max_y(), -1.),
        Some(DockEdge::Left) | None => (frame.max_x(), frame.min_x(), 1.),
    }
}

/// `DividerDragValue`: what a drag sets.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum DragValue {
    Ratio { id: String, value: f64 },
    Width { id: String, value: f64 },
}

/// `Caught.valueAt`: the drag's value for an extent from the anchor's rest place.
#[derive(Clone, Debug, PartialEq)]
pub enum ValueAt {
    Ratio { id: String, container: Rect, axis: SplitAxis, minimum_a: f64, minimum_b: f64 },
    Width { id: String, sign: f64, minimum: f64, viewport: f64, gap: f64 },
}

/// `SharedEdgeMotion.Caught`: what a press catches.
#[derive(Clone, Debug, PartialEq)]
pub struct Caught {
    pub value: DragValue,
    pub value_at: ValueAt,
    pub base: f64,
    pub axis: SplitAxis,
    /// The line's velocity, negated: added to the line, it stops it.
    pub speed_change: f64,
    /// The drawn place less the line's value: added to the line, it puts it on its pixel.
    pub place_change: f64,
    pub held: f64,
    /// The line moves: the press holds it.
    pub catches: bool,
}

impl Caught {
    /// `valueAt(extent)`.
    pub fn value_at(&self, extent: f64, style: &ScreenStyle) -> DragValue {
        match &self.value_at {
            ValueAt::Ratio { id, container, axis, minimum_a, minimum_b } => DragValue::Ratio {
                id: id.clone(),
                value: split_layout::ratio_for_pointer(
                    self.base + extent,
                    *container,
                    *axis,
                    &style.split(),
                    &PointerRatio {
                        grab_offset: 0.,
                        minimum_a: Some(*minimum_a),
                        minimum_b: Some(*minimum_b),
                        snaps: vec![],
                        snap_distance: 0.,
                    },
                ),
            },
            ValueAt::Width { id, sign, minimum, viewport, gap } => DragValue::Width {
                id: id.clone(),
                value: shown_resize::fraction((extent * sign).max(*minimum), *viewport, *gap),
            },
        }
    }
}

/// What the view reads for a press beside the geometry: the line's handle spring along the axis,
/// how the screen draws that axis, and its bounds.
pub struct PressScreen<'a> {
    pub geometry: &'a ScreenGeometry,
    pub layout: &'a ScreenLayout,
    pub style: &'a ScreenStyle,
    pub bounds: Size,
}

/// `SharedEdgeMotion.caught`: what a press on `kind` catches, given the handle frame's spring
/// along the line's axis (`handle(axis)`) and how the screen draws that axis (`shown(axis)`, with
/// whether a view offset that places the line moves). `None` is `.cannotCatch`.
pub fn press(
    kind: &HandleKind,
    screen: &PressScreen,
    handle: &AnimatedFrame,
    shown: impl Fn(SplitAxis) -> (ShownPixels, bool),
) -> Option<Caught> {
    let geometry = screen.geometry;
    match kind {
        HandleKind::Split { id } => {
            let divider = geometry.dividers.iter().find(|divider| &divider.id == id)?;
            let horizontal = divider.axis == SplitAxis::Horizontal;
            let base =
                if horizontal { divider.container.min_x() } else { divider.container.min_y() };
            let line = if horizontal { divider.frame.min_x() } else { divider.frame.min_y() };
            let (pixels, moves) = shown(divider.axis);
            if moves {
                return None;
            }
            let hold = Hold::new(line, if horizontal { handle.x } else { handle.y }, pixels);
            let mut caught = Caught {
                value: DragValue::Ratio { id: id.clone(), value: 0. },
                value_at: ValueAt::Ratio {
                    id: id.clone(),
                    container: divider.container,
                    axis: divider.axis,
                    minimum_a: divider.minimum_a,
                    minimum_b: divider.minimum_b,
                },
                base,
                axis: divider.axis,
                speed_change: -hold.velocity,
                place_change: hold.drawn - hold.value,
                held: hold.drawn,
                catches: hold.moves,
            };
            caught.value = caught.value_at(hold.drawn - base, screen.style);
            Some(caught)
        }
        HandleKind::ColumnEdge { id } => {
            let frame = geometry.columns.get(id)?;
            let column = match screen.layout {
                ScreenLayout::Columns(columns) => columns.iter().find(|column| &column.id == id),
                ScreenLayout::Splits(_) => None,
            }?;
            let edge = dock_edge(geometry, id);
            let band = edge.is_some_and(DockEdge::is_band);
            let axis = if band { SplitAxis::Vertical } else { SplitAxis::Horizontal };
            let (line, base, sign) = column_line(edge, frame);
            let (pixels, moves) = shown(axis);
            if moves {
                return None;
            }
            let hold = Hold::new(line, if band { handle.y } else { handle.x }, pixels);
            let size = column.minimum_size(screen.style);
            let minimum = if band { size.height } else { size.width };
            let viewport = match edge {
                None => geometry.strip_width,
                Some(DockEdge::Top | DockEdge::Bottom) => screen.bounds.height,
                Some(DockEdge::Left | DockEdge::Right) => screen.bounds.width,
            };
            let mut caught = Caught {
                value: DragValue::Width { id: id.clone(), value: 0. },
                value_at: ValueAt::Width {
                    id: id.clone(),
                    sign,
                    minimum,
                    viewport,
                    gap: screen.style.chrome().strip_gap(),
                },
                base,
                axis,
                speed_change: -hold.velocity,
                place_change: hold.drawn - hold.value,
                held: hold.drawn,
                catches: hold.moves,
            };
            caught.value = caught.value_at(hold.drawn - base, screen.style);
            Some(caught)
        }
        HandleKind::RowEdge { .. } => None,
    }
}

/// `SharedEdgeMotion.probeStep`: how far to either side of the line's rest place the probes
/// lay the screen out.
pub const PROBE_STEP: f64 = 8.;

/// `SharedEdgeMotion.Influence`: how far each edge moves when the drag's value moves the line by
/// `line_move` (a probe layout against the caught one).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Influence<'a> {
    pub caught: &'a ScreenGeometry,
    pub probe: &'a ScreenGeometry,
    pub axis: SplitAxis,
    pub line_move: f64,
}

impl<'a> Influence<'a> {
    /// `None` when the line is missing from either layout or moves less than a point.
    pub fn new(
        kind: &HandleKind,
        caught: &'a ScreenGeometry,
        probe: &'a ScreenGeometry,
        axis: SplitAxis,
    ) -> Option<Self> {
        let from = Self::target(kind, caught)?;
        let to = Self::target(kind, probe)?;
        let line_move = if axis == SplitAxis::Horizontal {
            to.min_x() - from.min_x()
        } else {
            to.min_y() - from.min_y()
        };
        (line_move.abs() >= 1.).then_some(Self { caught, probe, axis, line_move })
    }

    /// How far a frame's low and high edges move per point of line move.
    pub fn fractions(&self, from: Option<Rect>, to: Option<Rect>) -> Option<(f64, f64)> {
        let (from, to) = (from?, to?);
        Some(if self.axis == SplitAxis::Horizontal {
            (
                (to.min_x() - from.min_x()) / self.line_move,
                (to.max_x() - from.max_x()) / self.line_move,
            )
        } else {
            (
                (to.min_y() - from.min_y()) / self.line_move,
                (to.max_y() - from.max_y()) / self.line_move,
            )
        })
    }

    /// An edge that moves with the line as one.
    pub fn rigid(fraction: f64) -> bool {
        (fraction - 1.).abs() < 0.000_001
    }

    /// The line's hit frame in `geometry`.
    pub fn target(kind: &HandleKind, geometry: &ScreenGeometry) -> Option<Rect> {
        match kind {
            HandleKind::Split { id } => {
                geometry.dividers.iter().find(|divider| &divider.id == id).map(|d| d.hit_frame)
            }
            HandleKind::ColumnEdge { id } => {
                geometry.column_edges.iter().find(|edge| &edge.column == id).map(|e| e.hit_frame)
            }
            HandleKind::RowEdge { column, upper } => geometry
                .row_edges
                .iter()
                .find(|edge| &edge.column == column && &edge.upper == upper)
                .map(|edge| edge.hit_frame),
        }
    }

    /// `apply`: each edge gets the change of speed in proportion to its fraction; the place
    /// change (under a pixel) goes only to the edges that move with the line as one.
    pub fn apply(
        &self,
        speed_change: f64,
        place_change: f64,
        frame: &mut AnimatedFrame,
        from: Option<Rect>,
        to: Option<Rect>,
    ) {
        let Some((low, high)) = self.fractions(from, to) else { return };
        if low == 0. && high == 0. {
            return;
        }
        let rigid = |fraction: f64| if Self::rigid(fraction) { 1. } else { 0. };
        let change = |edges: &mut Edges| {
            (edges.low_speed, edges.high_speed) =
                (edges.low_speed + speed_change * low, edges.high_speed + speed_change * high);
            (edges.low, edges.high) =
                (edges.low + place_change * rigid(low), edges.high + place_change * rigid(high));
        };
        if self.axis == SplitAxis::Horizontal {
            let mut edges = Edges::new(frame.x, frame.width);
            change(&mut edges);
            edges.write(&mut frame.x, &mut frame.width);
        } else {
            let mut edges = Edges::new(frame.y, frame.height);
            change(&mut edges);
            edges.write(&mut frame.y, &mut frame.height);
        }
    }
}

/// `SharedEdgeMotion.mayShowNegativeSize`: whether a pane's size spring, with the press's speed
/// change (and a clamp's leftover spring taken off), could show it more than a point under its
/// rest size less `minimum`.
#[allow(clippy::too_many_arguments)]
pub fn may_show_negative_size(
    frames: &BTreeMap<String, AnimatedFrame>,
    targets: Option<&BTreeMap<String, Rect>>,
    influence: Option<&Influence>,
    speed_change: f64,
    clamp_leftover: f64,
    minimum: Size,
    spring: Spring,
) -> bool {
    let horizontal = influence.map(|i| i.axis) != Some(SplitAxis::Vertical);
    for (pane, frame) in frames {
        let target =
            targets.and_then(|t| t.get(pane).copied()).unwrap_or_else(|| frame.target_rect());
        let mut width = Edges::new(frame.x, frame.width);
        let mut height = Edges::new(frame.y, frame.height);
        (width.low_target, width.high_target) = (target.min_x(), target.max_x());
        (height.low_target, height.high_target) = (target.min_y(), target.max_y());
        let share = influence
            .and_then(|i| {
                i.fractions(i.caught.panes.get(pane).copied(), i.probe.panes.get(pane).copied())
            })
            .unwrap_or((0., 0.));
        let moved = if horizontal { &mut width } else { &mut height };
        (moved.low_speed, moved.high_speed) =
            (moved.low_speed + speed_change * share.0, moved.high_speed + speed_change * share.1);
        if lowest(&width, spring) < 1. - minimum.width
            || lowest(&height, spring) < 1. - minimum.height
        {
            return true;
        }
        if clamp_leftover.abs() <= 0.001 {
            continue;
        }
        let mut released = if horizontal { width } else { height };
        (released.low, released.high) =
            (released.low - share.0 * clamp_leftover, released.high - share.1 * clamp_leftover);
        let floor = 1. - if horizontal { minimum.width } else { minimum.height };
        if lowest(&released, spring) < floor {
            return true;
        }
    }
    false
}

/// `SharedEdgeMotion.lowest`: how far under its rest extent the span between two edge springs
/// gets on its way to rest (0 or less; 0 for edges at rest).
pub fn lowest(edges: &Edges, spring: Spring) -> f64 {
    let mut low =
        SpringValue { value: edges.low, velocity: edges.low_speed, target: edges.low_target };
    let mut high =
        SpringValue { value: edges.high, velocity: edges.high_speed, target: edges.high_target };
    let rest = edges.high_target - edges.low_target;
    let start = (edges.high - edges.low) - rest;
    if low.value == low.target
        && high.value == high.target
        && low.velocity == 0.
        && high.velocity == 0.
    {
        return 0.;
    }
    let dt = spring.response.max(0.05) / 40.;
    let mut lowest = start.min(0.);
    for _ in 0..400 {
        low.step(dt, spring);
        high.step(dt, spring);
        lowest = lowest.min((high.value - low.value) - rest);
        if [low, high].iter().all(|s| (s.value - s.target).abs() < 0.25 && s.velocity.abs() < 2.) {
            break;
        }
    }
    lowest
}

/// One divider's mouse area (Swift `LayoutMouseArea`'s id and rect).
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct MouseArea {
    pub id: String,
    pub rect: Rect,
}

/// `DividerMouseCatchers.update`: the areas that get a catcher panel, those a page window over
/// the layout covers, none while the layout is inactive or its window hidden.
pub fn wanted_catchers<'a>(
    areas: &'a [MouseArea],
    pages: &[Rect],
    active: bool,
    visible: bool,
) -> Vec<&'a MouseArea> {
    if !(active && visible) {
        return vec![];
    }
    areas
        .iter()
        .filter(|area| pages.iter().any(|page| page.intersection(&area.rect).is_some()))
        .collect()
}

/// What a scroll's routing found under the pointer (Swift `ScrollTargets`, read as facts).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ScrollFacts {
    /// A row stack that scrolls vertically.
    pub rows: bool,
    /// A scroll area that can move toward the left (direction 1, a negative delta x).
    pub area_forward: bool,
    /// A scroll area that can move toward the right (direction -1).
    pub area_back: bool,
    /// A column strip.
    pub columns: bool,
    pub columns_take_either_axis: bool,
    pub claims_whole_gesture: bool,
}

/// Where a scroll goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ScrollRoute {
    /// The row stack, one notch (direction 1 is down the stack).
    Rows { direction: i8 },
    /// The scroll area, one notch.
    Area { direction: i8 },
    /// The column strip, one notch.
    Columns { direction: i8 },
    /// A notch the layout claims with nothing to move its way: kept, the pane never scrolls.
    Claimed,
    /// The pane under the pointer gets it.
    PassThrough,
}

/// `LayoutRootView.routeScrollEvent`, a discrete wheel notch (no phase): which layout part takes
/// it, decided per notch.
pub fn notch_route(dx: f64, dy: f64, facts: ScrollFacts) -> ScrollRoute {
    let vertical = dy.abs() > dx.abs();
    let horizontal = dx.abs() > dy.abs();
    if vertical && facts.rows {
        return ScrollRoute::Rows { direction: if dy < 0. { 1 } else { -1 } };
    }
    if horizontal {
        let direction = if dx < 0. { 1 } else { -1 };
        if (direction == 1 && facts.area_forward) || (direction == -1 && facts.area_back) {
            return ScrollRoute::Area { direction };
        }
    }
    if facts.columns && (horizontal || (vertical && facts.columns_take_either_axis)) {
        let delta = if horizontal { dx } else { dy };
        return ScrollRoute::Columns { direction: if delta < 0. { 1 } else { -1 } };
    }
    if facts.claims_whole_gesture {
        return ScrollRoute::Claimed;
    }
    ScrollRoute::PassThrough
}

/// What an undecided gesture's event decides (Swift `ScrollLock` after `.undecided`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum GestureLock {
    /// Still undecided: the event moved nothing. `forwards`: the pane sees it (false for a
    /// gesture the layout claims whole).
    Undecided {
        forwards: bool,
    },
    /// The gesture ended before it moved: idle again.
    Ended {
        forwards: bool,
        consume_momentum: bool,
    },
    Area,
    Horizontal {
        vertical_deltas: bool,
    },
    Vertical,
    Claimed,
    PassThrough,
}

/// `LayoutRootView.routeScrollEvent`, an undecided gesture's event: innermost first, an area that
/// can move in the gesture's first direction owns it, then the strip, then the rows.
pub fn undecided_lock(dx: f64, dy: f64, ended: bool, facts: ScrollFacts) -> GestureLock {
    let (adx, ady) = (dx.abs(), dy.abs());
    let forwards = !facts.claims_whole_gesture;
    if ended {
        return GestureLock::Ended { forwards, consume_momentum: facts.claims_whole_gesture };
    }
    if !(adx + ady > 0.) {
        return GestureLock::Undecided { forwards };
    }
    let area = if dx < 0. { facts.area_forward } else { facts.area_back };
    if adx > ady && area {
        return GestureLock::Area;
    }
    if adx > ady && facts.columns {
        return GestureLock::Horizontal { vertical_deltas: false };
    }
    if ady >= adx && facts.rows {
        return GestureLock::Vertical;
    }
    if ady >= adx && facts.columns_take_either_axis && facts.columns {
        return GestureLock::Horizontal { vertical_deltas: true };
    }
    if facts.claims_whole_gesture {
        return GestureLock::Claimed;
    }
    GestureLock::PassThrough
}
