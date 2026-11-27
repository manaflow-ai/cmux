//! Where a dragged tab drops on a screen: the pane drop zones, the column
//! gaps, the edge bands that open a dock, and the rects each target's preview
//! fills (plans/cmux-next/drop-zones/DESIGN.md; the Mac app's
//! `DropZoneGeometry`, which this replaces).
//!
//! The caller gives one [`Screen`] per layout (the placed pane cells, the
//! column gap zones, the docked columns, the style's drop numbers) and then
//! asks per pointer move with a point and the target the preview shows now.
//! Every coordinate is flipped (y grows down). Panes and gaps are named by
//! their index in the screen: the caller keeps its own ids and sends the
//! panes in their tie-break order (the app sorts them by pane id).
//!
//! Rect semantics follow CoreGraphics: a rect contains a point on its min
//! edges, not on its max edges, and an empty rect contains nothing.

use serde::{Deserialize, Serialize};

/// A rect in flipped coordinates.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    fn is_empty(&self) -> bool {
        !(self.width > 0.0 && self.height > 0.0)
    }
    /// CGRect.contains(point): min edges in, max edges out.
    pub fn contains(&self, x: f64, y: f64) -> bool {
        !self.is_empty() && x >= self.x && x < self.max_x() && y >= self.y && y < self.max_y()
    }
    /// CGRect.contains(rect): `other` lies inside, edges included.
    fn contains_rect(&self, other: &Rect) -> bool {
        other.x >= self.x
            && other.y >= self.y
            && other.max_x() <= self.max_x()
            && other.max_y() <= self.max_y()
    }
    /// CGRect.insetBy(dx:dy:); `None` for the null rect a too-large inset gives.
    fn inset(&self, dx: f64, dy: f64) -> Option<Rect> {
        let (width, height) = (self.width - dx * 2.0, self.height - dy * 2.0);
        (width >= 0.0 && height >= 0.0).then(|| Rect::new(self.x + dx, self.y + dy, width, height))
    }
    fn offset(&self, dx: f64) -> Rect {
        Rect::new(self.x + dx, self.y, self.width, self.height)
    }
    /// The overlap of two rects, `None` when it is null or empty.
    fn overlap(&self, other: &Rect) -> Option<Rect> {
        let (x, y) = (self.x.max(other.x), self.y.max(other.y));
        let (max_x, max_y) = (self.max_x().min(other.max_x()), self.max_y().min(other.max_y()));
        (max_x > x && max_y > y).then(|| Rect::new(x, y, max_x - x, max_y - y))
    }
    fn distance(&self, x: f64, y: f64) -> f64 {
        let dx = (self.x - x).max(0.0).max(x - self.max_x());
        let dy = (self.y - y).max(0.0).max(y - self.max_y());
        (dx * dx + dy * dy).sqrt()
    }
    fn clamp(&self, x: f64, y: f64) -> (f64, f64) {
        (x.max(self.x).min(self.max_x()), y.max(self.y).min(self.max_y()))
    }
}

/// The region of a pane a dropped tab takes: an edge splits it, the center
/// joins it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Zone {
    Left,
    Right,
    Top,
    Bottom,
    Center,
}

impl Zone {
    const EDGES: [Zone; 4] = [Zone::Left, Zone::Right, Zone::Top, Zone::Bottom];

    /// The dock edge this zone faces (none for the center).
    fn edge(self) -> Option<Edge> {
        match self {
            Zone::Left => Some(Edge::Left),
            Zone::Right => Some(Edge::Right),
            Zone::Top => Some(Edge::Top),
            Zone::Bottom => Some(Edge::Bottom),
            Zone::Center => None,
        }
    }
}

/// A viewport edge a dock holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

impl Edge {
    fn is_band(self) -> bool {
        matches!(self, Edge::Top | Edge::Bottom)
    }
}

/// Where a dragged tab would land. `pane` and `gap` index the screen's
/// panes and gaps; a previous target naming a pane of another screen uses
/// an index past the panes (it matches no pane, its zone still counts).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Target {
    /// Split the pane at the zone's edge, or join it at the center.
    Pane { pane: usize, zone: Zone },
    /// A new column at the gap zone.
    NewColumn { gap: usize },
    /// A new dock at a free viewport edge.
    NewDock { edge: Edge },
}

/// The drop numbers of the layout style.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Style {
    /// An edge band's share of the pane body's extent.
    pub edge_fraction: f64,
    /// An edge band's floor and cap (points).
    pub edge_minimum: f64,
    pub edge_maximum: f64,
    /// How far past its line a shown target holds (points).
    pub hysteresis: f64,
    /// The bottom dock band's depth; a side band is half of it.
    pub dock_band: f64,
    /// The top dock band's depth.
    pub dock_top_band: f64,
    /// The pane cell's padding around its rounded content rect.
    pub pane_padding: f64,
    /// The strip's gap, around a new dock's preview.
    pub strip_gap: f64,
}

impl Default for Style {
    fn default() -> Self {
        Self {
            edge_fraction: 0.25,
            edge_minimum: 48.0,
            edge_maximum: f64::MAX,
            hysteresis: 12.0,
            dock_band: 24.0,
            dock_top_band: 32.0,
            pane_padding: 0.0,
            strip_gap: 0.0,
        }
    }
}

/// A placed pane: its cell (content space when it scrolls, view space when
/// `fixed`), and the tab bar heights it reports at its top and bottom (0:
/// none).
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Pane {
    pub rect: Rect,
    /// A docked or floating pane: view coordinates, never scrolls.
    pub fixed: bool,
    pub header: f64,
    pub footer: f64,
}

/// A docked column: its edge, its frame and what it covers (view space).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Dock {
    pub edge: Edge,
    pub frame: Rect,
    pub cover: Rect,
}

/// One screen's placed geometry and the style's drop numbers.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Screen {
    pub width: f64,
    pub height: f64,
    /// In tie-break order.
    pub panes: Vec<Pane>,
    /// The column gap zones' frames (content space), in hit order.
    pub gaps: Vec<Rect>,
    pub docks: Vec<Dock>,
    /// The part of the strip nothing covers (view space); read only with docks.
    pub uncovered: Rect,
    pub strip_min_x: f64,
    pub style: Style,
}

/// What a target's preview fills (view space): the highlight, the whole
/// region the drop divides, and for a pane its body below its tab bar.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rects {
    pub highlight: Rect,
    pub region: Rect,
    pub body: Option<Rect>,
}

/// An edge band: a share of the extent above the style's floor, never more
/// than a third of it, so every pane keeps a center of at least a third of
/// each axis to join.
pub fn band(extent: f64, style: &Style) -> f64 {
    let clamped = (extent * style.edge_fraction).max(style.edge_minimum).min(style.edge_maximum);
    clamped.min(extent / 3.0).max(1.0)
}

/// The zone of pane cell `rect` under the point: the zones divide the pane
/// body below its `header`-point tab bar (and above a `footer`-point one);
/// over a tab bar a tab joins the pane. Each edge owns a band ([`band`]); a
/// point in several bands (a corner) goes to the edge it is relatively
/// nearest to (depth / band), else the center. `previous` is the zone the
/// preview shows in this pane now: it holds until the pointer is the
/// style's hysteresis past its line.
pub fn zone(
    x: f64,
    y: f64,
    rect: &Rect,
    header: f64,
    footer: f64,
    style: &Style,
    previous: Option<Zone>,
) -> Zone {
    let top = rect.y + header.max(0.0).min(rect.height);
    let bottom = top.max(rect.max_y() - footer.max(0.0));
    if y < top || !(y < bottom || footer <= 0.0) {
        return Zone::Center;
    }
    let body = Rect::new(rect.x, top, rect.width, bottom - top);
    let band_x = band(body.width, style);
    let band_y = band(body.height, style);
    let margin = style.hysteresis.max(0.0);
    let reach = |zone: Zone| -> f64 {
        let along = if matches!(zone, Zone::Left | Zone::Right) { band_x } else { band_y };
        let extra = match previous {
            Some(shown) if shown == zone => margin,
            Some(Zone::Center) => -margin.min(along / 2.0),
            _ => 0.0,
        };
        let depth = match zone {
            Zone::Left => x - body.x,
            Zone::Right => body.max_x() - x,
            Zone::Top => y - body.y,
            Zone::Bottom => body.max_y() - y,
            Zone::Center => return f64::INFINITY,
        };
        depth / (along + extra).max(1.0)
    };
    if let Some(shown) = previous
        && shown != Zone::Center
        && reach(shown) < 1.0
    {
        return shown;
    }
    let mut best: Option<(Zone, f64)> = None;
    for zone in Zone::EDGES {
        let depth = reach(zone);
        if depth < 1.0 && best.is_none_or(|(_, least)| depth < least) {
            best = Some((zone, depth));
        }
    }
    best.map_or(Zone::Center, |(zone, _)| zone)
}

impl Screen {
    /// The view x of strip content x at scroll `offset`.
    pub fn view_shift(&self, offset: f64) -> f64 {
        self.strip_min_x - offset
    }

    /// The rounded content rect of a pane cell: inset by the padding, a cell
    /// smaller than twice the padding collapses to its center line.
    pub fn content_rect(&self, cell: &Rect) -> Rect {
        let dx = self.style.pane_padding.min(cell.width / 2.0);
        let dy = self.style.pane_padding.min(cell.height / 2.0);
        Rect::new(cell.x + dx, cell.y + dy, cell.width - dx * 2.0, cell.height - dy * 2.0)
    }

    /// The tab bar height of a pane from its cell top: the cell's padding
    /// plus the header it reports (0 without one).
    pub fn header(&self, pane: &Pane) -> f64 {
        if pane.header > 0.0 {
            self.content_rect(&pane.rect).y - pane.rect.y + pane.header
        } else {
            0.0
        }
    }

    /// The tab bar height of a pane at its cell bottom (as [`Screen::header`]).
    pub fn footer(&self, pane: &Pane) -> f64 {
        if pane.footer > 0.0 {
            pane.rect.max_y() - self.content_rect(&pane.rect).max_y() + pane.footer
        } else {
            0.0
        }
    }

    /// A column gap under the content point. The shown gap holds the
    /// hysteresis horizontally past its frame; entered from a pane's left or
    /// right split zone it shrinks by at most a quarter of its width.
    pub fn gap_target(&self, x: f64, y: f64, previous: Option<Target>) -> Option<Target> {
        let margin = self.style.hysteresis.max(0.0);
        self.gaps.iter().enumerate().find_map(|(gap, frame)| {
            let inset = match previous {
                Some(Target::NewColumn { gap: shown }) if shown == gap => -margin,
                Some(Target::Pane { zone: Zone::Left | Zone::Right, .. }) => {
                    margin.min(frame.width / 4.0)
                }
                _ => 0.0,
            };
            frame
                .inset(inset, 0.0)
                .is_some_and(|zone| zone.contains(x, y))
                .then_some(Target::NewColumn { gap })
        })
    }

    /// The pane target under the point among `candidates` (index, cell,
    /// visible part): the pane whose visible part holds it, else the nearest
    /// one, with the zone at the nearest point of that pane: no dead zones.
    fn pane_target(
        &self,
        x: f64,
        y: f64,
        candidates: &[(usize, Rect, Rect)],
        previous: Option<Target>,
    ) -> Option<Target> {
        let resolve = |x: f64, y: f64, index: usize, cell: &Rect| {
            let shown = match previous {
                Some(Target::Pane { pane, zone }) if pane == index => Some(zone),
                _ => None,
            };
            // Every candidate's index names one of `self.panes`.
            let pane = self.panes.get(index)?;
            Some(zone(x, y, cell, self.header(pane), self.footer(pane), &self.style, shown))
        };
        if let Some((index, cell, _)) =
            candidates.iter().find(|(_, _, visible)| visible.contains(x, y))
        {
            return Some(Target::Pane { pane: *index, zone: resolve(x, y, *index, cell)? });
        }
        let mut nearest: Option<(&(usize, Rect, Rect), f64)> = None;
        for candidate in candidates {
            let distance = candidate.2.distance(x, y);
            if nearest.is_none_or(|(_, least)| distance < least) {
                nearest = Some((candidate, distance));
            }
        }
        let ((index, cell, visible), _) = nearest?;
        let (cx, cy) = visible.clamp(x, y);
        Some(Target::Pane { pane: *index, zone: resolve(cx, cy, *index, cell)? })
    }

    /// The drop target under a content-space point: a column gap first (so
    /// "new column" is reachable between columns), else a pane.
    pub fn target_in_content(&self, x: f64, y: f64, previous: Option<Target>) -> Option<Target> {
        if let Some(gap) = self.gap_target(x, y, previous) {
            return Some(gap);
        }
        let candidates: Vec<_> = self
            .panes
            .iter()
            .enumerate()
            .map(|(index, pane)| (index, pane.rect, pane.rect))
            .collect();
        self.pane_target(x, y, &candidates, previous)
    }

    /// The drop target under a view-space point with the strip scrolled to
    /// `offset`. A docked column's cover takes the drop for its own panes
    /// (nothing lands in a strip pane hidden under it); else a gap, else the
    /// strip and docked panes clipped to what the docks leave visible. Every
    /// point resolves while the screen has a pane.
    pub fn target(&self, x: f64, y: f64, offset: f64, previous: Option<Target>) -> Option<Target> {
        let shift = self.view_shift(offset);
        if let Some(cover) = self.docks.iter().find(|dock| dock.cover.contains(x, y)) {
            let candidates: Vec<_> = self
                .panes
                .iter()
                .enumerate()
                .filter(|(_, pane)| pane.fixed && cover.frame.contains_rect(&pane.rect))
                .map(|(index, pane)| (index, pane.rect, pane.rect))
                .collect();
            return self.pane_target(x, y, &candidates, previous);
        }
        if let Some(gap) = self.gap_target(x - shift, y, previous) {
            return Some(gap);
        }
        let docked = !self.docks.is_empty();
        let candidates: Vec<_> = self
            .panes
            .iter()
            .enumerate()
            .filter_map(|(index, pane)| {
                if pane.fixed {
                    return Some((index, pane.rect, pane.rect));
                }
                let cell = pane.rect.offset(shift);
                if !docked {
                    return Some((index, cell, cell));
                }
                cell.overlap(&self.uncovered).map(|visible| (index, cell, visible))
            })
            .collect();
        self.pane_target(x, y, &candidates, previous)
    }

    /// An edge band that opens a dock while that edge has none (view space).
    /// The top band is `dock_top_band` deep below the `top_inset` tab bar,
    /// the bottom `dock_band` above the `bottom_inset` one, the sides half
    /// `dock_band`; top and bottom win the corners. The shown dock grows its
    /// band inward by the hysteresis; entered from the pane split zone facing
    /// the same edge, the band shrinks by at most half its depth.
    pub fn dock_target(
        &self,
        x: f64,
        y: f64,
        top_inset: f64,
        bottom_inset: f64,
        previous: Option<Target>,
    ) -> Option<Target> {
        let (width, height) = (self.width, self.height);
        let band = self.style.dock_band.min(height / 4.0);
        let top_band = self.style.dock_top_band.min(height / 4.0);
        let side = (self.style.dock_band / 2.0).min(width / 8.0);
        let margin = self.style.hysteresis.max(0.0);
        let extra = |edge: Edge, depth: f64| match previous {
            Some(Target::NewDock { edge: shown }) if shown == edge => margin,
            Some(Target::Pane { zone, .. }) if zone.edge() == Some(edge) => {
                -margin.min(depth / 2.0)
            }
            _ => 0.0,
        };
        let free = |edge: Edge| !self.docks.iter().any(|dock| dock.edge == edge);
        let dock = |edge: Edge| Some(Target::NewDock { edge });
        if y >= top_inset
            && y <= top_inset + top_band + extra(Edge::Top, top_band)
            && free(Edge::Top)
        {
            return dock(Edge::Top);
        }
        let bottom = height - bottom_inset;
        if y >= bottom - band - extra(Edge::Bottom, band) && y <= bottom && free(Edge::Bottom) {
            return dock(Edge::Bottom);
        }
        if x <= side + extra(Edge::Left, side) && free(Edge::Left) {
            return dock(Edge::Left);
        }
        if x >= width - side - extra(Edge::Right, side) && free(Edge::Right) {
            return dock(Edge::Right);
        }
        None
    }

    /// Where a new dock would sit (view space): a band 30% of the height
    /// across the screen, or a side column 30% of the width down it, less
    /// the strip gaps.
    pub fn dock_preview(&self, edge: Edge) -> Rect {
        let (width, height, gap) = (self.width, self.height, self.style.strip_gap);
        if edge.is_band() {
            let band = height * 0.3;
            let y = if edge == Edge::Top { 0.0 } else { height - band };
            return Rect::new(gap, y, (width - gap * 2.0).max(1.0), band);
        }
        let column = width * 0.3;
        let x = if edge == Edge::Left { gap } else { width - column - gap };
        Rect::new(x, 0.0, column.max(1.0), height)
    }

    /// The whole region a drop on `target` divides (content space; a dock's
    /// and a fixed pane's in view space): the pane's content rect, the gap
    /// zone, or the new dock.
    pub fn region_rect(&self, target: Target) -> Option<Rect> {
        match target {
            Target::Pane { pane, .. } => {
                self.panes.get(pane).map(|pane| self.content_rect(&pane.rect))
            }
            Target::NewColumn { gap } => self.gaps.get(gap).copied(),
            Target::NewDock { edge } => Some(self.dock_preview(edge)),
        }
    }

    /// Where the glass highlight goes for `target` (spaces as
    /// [`Screen::region_rect`]): the half of the content rect an edge
    /// splits off, the whole of it for the center.
    pub fn highlight_rect(&self, target: Target) -> Option<Rect> {
        let Target::Pane { pane, zone } = target else { return self.region_rect(target) };
        let rect = self.content_rect(&self.panes.get(pane)?.rect);
        let (half_w, half_h) = (rect.width / 2.0, rect.height / 2.0);
        Some(match zone {
            Zone::Center => rect,
            Zone::Left => Rect::new(rect.x, rect.y, half_w, rect.height),
            Zone::Right => Rect::new(rect.mid_x(), rect.y, half_w, rect.height),
            Zone::Top => Rect::new(rect.x, rect.y, rect.width, half_h),
            Zone::Bottom => Rect::new(rect.x, rect.mid_y(), rect.width, half_h),
        })
    }

    /// The shift that brings `target`'s rects into view space at `offset`.
    fn view_dx(&self, target: Target, offset: f64) -> f64 {
        match target {
            Target::NewDock { .. } => 0.0,
            Target::Pane { pane, .. } if self.panes.get(pane).is_some_and(|pane| pane.fixed) => 0.0,
            _ => self.view_shift(offset),
        }
    }

    /// [`Screen::region_rect`] in view space with the strip at `offset`.
    pub fn region_rect_in_view(&self, target: Target, offset: f64) -> Option<Rect> {
        Some(self.region_rect(target)?.offset(self.view_dx(target, offset)))
    }

    /// [`Screen::highlight_rect`] in view space with the strip at `offset`.
    pub fn highlight_rect_in_view(&self, target: Target, offset: f64) -> Option<Rect> {
        Some(self.highlight_rect(target)?.offset(self.view_dx(target, offset)))
    }

    /// A pane's body in view space: its content rect below its tab bar (and
    /// above a bottom tab bar), the area its drop zones divide.
    pub fn pane_body(&self, index: usize, offset: f64) -> Option<Rect> {
        let pane = self.panes.get(index)?;
        let content =
            self.region_rect_in_view(Target::Pane { pane: index, zone: Zone::Center }, offset)?;
        let shown = if pane.fixed { pane.rect } else { pane.rect.offset(self.view_shift(offset)) };
        let top = content.y.max(shown.y + self.header(pane));
        let bottom = content.max_y().min(shown.max_y() - self.footer(pane));
        Some(Rect::new(content.x, top, content.width, (bottom - top).max(0.0)))
    }

    /// Every rect a target's preview reads, in view space at `offset`.
    pub fn rects(&self, target: Target, offset: f64) -> Option<Rects> {
        let body = match target {
            Target::Pane { pane, .. } => Some(self.pane_body(pane, offset)?),
            _ => None,
        };
        Some(Rects {
            highlight: self.highlight_rect_in_view(target, offset)?,
            region: self.region_rect_in_view(target, offset)?,
            body,
        })
    }
}

/// The inset of a pane zone's highlight inside the pane's body (classic
/// cmux's 4 pt).
pub const CLASSIC_PANE_PADDING: f64 = 4.0;

/// Classic cmux's pane drop overlay: the body inset `padding` for the
/// center; for an edge the half the split gives the new pane, inset on its
/// three outer sides and meeting the midline. Never a negative size.
pub fn classic_pane_highlight(body: &Rect, zone: Zone, padding: f64) -> Rect {
    let (x, y, w, h) = (body.x, body.y, body.width, body.height);
    let rect = match zone {
        Zone::Center => Rect::new(x + padding, y + padding, w - padding * 2.0, h - padding * 2.0),
        Zone::Left => {
            Rect::new(x + padding, y + padding, body.mid_x() - x - padding, h - padding * 2.0)
        }
        Zone::Right => Rect::new(
            body.mid_x(),
            y + padding,
            body.max_x() - body.mid_x() - padding,
            h - padding * 2.0,
        ),
        Zone::Top => {
            Rect::new(x + padding, y + padding, w - padding * 2.0, body.mid_y() - y - padding)
        }
        Zone::Bottom => Rect::new(
            x + padding,
            body.mid_y(),
            w - padding * 2.0,
            body.max_y() - body.mid_y() - padding,
        ),
    };
    Rect::new(rect.x, rect.y, rect.width.max(0.0), rect.height.max(0.0))
}

#[cfg(test)]
#[path = "pane_drop_zones_tests.rs"]
mod tests;
