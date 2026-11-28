//! Hit testing and highlight rects for tab drops (Swift `DropZoneGeometry`; pane-drop-targets
//! DESIGN.md, plans/cmux-next/drop-zones/DESIGN.md). Coordinates are flipped: y grows down.

use super::pane_chrome::content_rect;
use super::{
    DockEdge, Point, Rect, Size, SplitAxis, dock_strip::MAX_BAND_SHARE, swift_max, swift_min,
};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// The `LayoutStyle` values tab drops read, with its defaults.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DropStyle {
    pub drop_edge_fraction: f64,
    /// `dropEdgeRange.lowerBound` and `upperBound`.
    pub drop_edge_minimum: f64,
    pub drop_edge_maximum: f64,
    pub drop_zone_hysteresis: f64,
    pub dock_drop_band: f64,
    pub dock_top_drop_band: f64,
    pub pane_padding: f64,
    pub column_gap: f64,
}

impl Default for DropStyle {
    fn default() -> Self {
        Self {
            drop_edge_fraction: 0.25,
            drop_edge_minimum: 48.,
            drop_edge_maximum: f64::MAX,
            drop_zone_hysteresis: 12.,
            dock_drop_band: 24.,
            dock_top_drop_band: 32.,
            pane_padding: 0.,
            column_gap: 6.,
        }
    }
}

impl DropStyle {
    /// `LayoutStyle.stripGap`.
    pub fn strip_gap(&self) -> f64 {
        swift_max(0., self.column_gap - self.pane_padding * 2.)
    }
}

/// Where in a pane a drop lands (Swift `PaneDropZone`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneDropZone {
    Left,
    Right,
    Top,
    Bottom,
    /// Add the tab to the pane itself.
    Center,
}

impl PaneDropZone {
    /// The axis of the split a drop in this zone creates; `None` for center.
    pub fn split_axis(self) -> Option<SplitAxis> {
        match self {
            Self::Left | Self::Right => Some(SplitAxis::Horizontal),
            Self::Top | Self::Bottom => Some(SplitAxis::Vertical),
            Self::Center => None,
        }
    }

    /// `zone.rawValue == edge.rawValue`.
    fn faces(self, edge: DockEdge) -> bool {
        matches!(
            (self, edge),
            (Self::Left, DockEdge::Left)
                | (Self::Right, DockEdge::Right)
                | (Self::Top, DockEdge::Top)
                | (Self::Bottom, DockEdge::Bottom)
        )
    }
}

/// What a tab drop does (Swift `DropTarget`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DropTarget {
    /// Split `pane` at `zone`, or join it for center.
    Pane { pane: String, zone: PaneDropZone },
    /// Create a new column after `after` (`None`: before the first column).
    NewColumn { screen: String, after: Option<String> },
    /// Open a dock at `edge` holding the tab.
    NewDock { screen: String, edge: DockEdge },
}

/// A "new column" drop zone centered on a column gap (Swift `ColumnGapZone`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct GapZone {
    pub after: Option<String>,
    pub frame: Rect,
}

/// A placed dock as drops read it: its edge, frame and cover (Swift `DockColumnFrame`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DockCover {
    pub edge: DockEdge,
    pub frame: Rect,
    pub cover: Rect,
}

/// The part of a screen's `ScreenGeometry` tab drops read: the pane cells and gap zones in content
/// space, the docks and the strip's uncovered range in view coordinates.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DropGeometry {
    pub viewport: Size,
    pub panes: BTreeMap<String, Rect>,
    pub gap_zones: Vec<GapZone>,
    pub dock: Vec<DockCover>,
    /// Panes that never scroll (docked and floating panes; view coordinates).
    pub fixed_panes: BTreeSet<String>,
    pub strip_min_x: f64,
    pub uncovered_min_x: f64,
    pub uncovered_max_x: f64,
    pub uncovered_min_y: f64,
    pub uncovered_max_y: f64,
}

impl DropGeometry {
    /// `ScreenGeometry.scrolls(pane:)`.
    pub fn scrolls(&self, pane: &str) -> bool {
        !self.fixed_panes.contains(pane)
    }

    /// `ScreenGeometry.viewShift(offset:)`: content x plus this is view x.
    pub fn view_shift(&self, offset: f64) -> f64 {
        self.strip_min_x - offset
    }
}

/// Each pane's header (tab bar) and footer height as the pane reports it.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Bars {
    pub headers: BTreeMap<String, f64>,
    pub footers: BTreeMap<String, f64>,
}

/// `DropZoneGeometry.zone`: the zone of pane cell `rect` under `point`. The zones divide the pane body
/// below its `header` tab bar; over a tab bar a tab joins the pane (center). Each edge owns a band; a
/// point in several bands goes to the edge it is relatively nearest to, else center. `previous` holds
/// until the pointer is `drop_zone_hysteresis` past its line.
pub fn zone(
    point: Point,
    rect: Rect,
    header: f64,
    footer: f64,
    style: &DropStyle,
    previous: Option<PaneDropZone>,
) -> PaneDropZone {
    let top = rect.min_y() + swift_min(swift_max(0., header), rect.height());
    let bottom = swift_max(top, rect.max_y() - swift_max(0., footer));
    // Over the tab bar (header or footer) a tab joins the pane.
    if !(point.y >= top && (point.y < bottom || footer <= 0.)) {
        return PaneDropZone::Center;
    }
    let body = Rect::new(rect.min_x(), top, rect.width(), bottom - top);
    let band_x = band(body.width(), style);
    let band_y = band(body.height(), style);
    let margin = swift_max(0., style.drop_zone_hysteresis);
    // Depth into each edge's band as a share of the band (< 1 is inside).
    let reach = |zone: PaneDropZone| -> f64 {
        let extra = match previous {
            Some(p) if p == zone => margin,
            Some(PaneDropZone::Center) => {
                let along =
                    if zone.split_axis() == Some(SplitAxis::Horizontal) { band_x } else { band_y };
                -swift_min(margin, along / 2.)
            }
            _ => 0.,
        };
        match zone {
            PaneDropZone::Left => (point.x - body.min_x()) / swift_max(1., band_x + extra),
            PaneDropZone::Right => (body.max_x() - point.x) / swift_max(1., band_x + extra),
            PaneDropZone::Top => (point.y - body.min_y()) / swift_max(1., band_y + extra),
            PaneDropZone::Bottom => (body.max_y() - point.y) / swift_max(1., band_y + extra),
            PaneDropZone::Center => f64::INFINITY,
        }
    };
    if let Some(previous) = previous
        && previous != PaneDropZone::Center
        && reach(previous) < 1.
    {
        return previous;
    }
    let mut best: Option<(PaneDropZone, f64)> = None;
    for zone in [PaneDropZone::Left, PaneDropZone::Right, PaneDropZone::Top, PaneDropZone::Bottom] {
        let r = reach(zone);
        if r < 1. && best.is_none_or(|(_, b)| r < b) {
            best = Some((zone, r));
        }
    }
    best.map_or(PaneDropZone::Center, |(zone, _)| zone)
}

/// `DropZoneGeometry.band(for:)`: an edge band, a share of the extent clamped to the style's range and
/// never more than a third of it.
pub fn band(extent: f64, style: &DropStyle) -> f64 {
    let raw = extent * style.drop_edge_fraction;
    let clamped = swift_min(swift_max(raw, style.drop_edge_minimum), style.drop_edge_maximum);
    swift_max(1., swift_min(clamped, extent / 3.))
}

/// `DropZoneGeometry.target(at:)`: the drop target under `point` (content space). Column gaps win
/// over pane edges; a point in no pane goes to the nearest pane.
pub fn target(
    point: Point,
    screen: &str,
    geometry: &DropGeometry,
    bars: &Bars,
    style: &DropStyle,
    previous: Option<&DropTarget>,
) -> Option<DropTarget> {
    if let Some(gap) = gap_target(point, screen, geometry, style, previous) {
        return Some(gap);
    }
    let candidates: Vec<Candidate> = geometry
        .panes
        .iter()
        .map(|(pane, rect)| Candidate { pane, cell: *rect, visible: *rect })
        .collect();
    pane_target(point, candidates, bars, style, previous)
}

/// `gapTarget`: a column gap grows horizontally by the hysteresis while shown; entered from a pane's
/// left or right split zone it shrinks by at most a quarter of its width.
pub fn gap_target(
    point: Point,
    screen: &str,
    geometry: &DropGeometry,
    style: &DropStyle,
    previous: Option<&DropTarget>,
) -> Option<DropTarget> {
    let margin = swift_max(0., style.drop_zone_hysteresis);
    for zone in &geometry.gap_zones {
        let target = DropTarget::NewColumn { screen: screen.to_owned(), after: zone.after.clone() };
        let inset = match previous {
            Some(p) if *p == target => -margin,
            Some(DropTarget::Pane { zone: PaneDropZone::Left | PaneDropZone::Right, .. }) => {
                swift_min(margin, zone.frame.width() / 4.)
            }
            _ => 0.,
        };
        if zone.frame.inset_by(inset, 0.).is_some_and(|frame| frame.contains(point)) {
            return Some(target);
        }
    }
    None
}

/// `header(of:in:)`: the tab bar height of `pane` from its cell top, padding included.
fn header(pane: &str, cell: Rect, bars: &Bars, style: &DropStyle) -> f64 {
    match bars.headers.get(pane) {
        Some(&header) if header > 0. => {
            content_rect(cell, style.pane_padding).min_y() - cell.min_y() + header
        }
        _ => 0.,
    }
}

/// `footer(of:in:)`: the same at the bottom of the cell.
fn footer(pane: &str, cell: Rect, bars: &Bars, style: &DropStyle) -> f64 {
    match bars.footers.get(pane) {
        Some(&footer) if footer > 0. => {
            cell.max_y() - content_rect(cell, style.pane_padding).max_y() + footer
        }
        _ => 0.,
    }
}

/// `target(atView:offset:)`: the drop target under `point` in view coordinates, with the strip at
/// `offset`. A dock's cover goes to its fixed panes; the strip resolves as [`target`] with its panes
/// clipped to what the docks leave visible.
pub fn target_in_view(
    point: Point,
    offset: f64,
    screen: &str,
    geometry: &DropGeometry,
    bars: &Bars,
    style: &DropStyle,
    previous: Option<&DropTarget>,
) -> Option<DropTarget> {
    let shift = geometry.view_shift(offset);
    if let Some(cover) = geometry.dock.iter().find(|d| d.cover.contains(point)) {
        let panes = geometry
            .panes
            .iter()
            .filter(|(pane, rect)| {
                geometry.fixed_panes.contains(*pane) && cover.frame.contains_rect(rect)
            })
            .map(|(pane, rect)| Candidate { pane, cell: *rect, visible: *rect })
            .collect();
        return pane_target(point, panes, bars, style, previous);
    }
    let content = Point::new(point.x - shift, point.y);
    if let Some(gap) = gap_target(content, screen, geometry, style, previous) {
        return Some(gap);
    }
    let uncovered = (!geometry.dock.is_empty()).then(|| {
        Rect::new(
            geometry.uncovered_min_x,
            geometry.uncovered_min_y,
            geometry.uncovered_max_x - geometry.uncovered_min_x,
            geometry.uncovered_max_y - geometry.uncovered_min_y,
        )
    });
    let candidates = geometry
        .panes
        .iter()
        .filter_map(|(pane, rect)| {
            if !geometry.scrolls(pane) {
                return Some(Candidate { pane, cell: *rect, visible: *rect });
            }
            let cell = rect.offset_by(shift, 0.);
            let Some(uncovered) = uncovered else {
                return Some(Candidate { pane, cell, visible: cell });
            };
            let visible = cell.intersection(&uncovered).filter(|v| !v.is_empty())?;
            Some(Candidate { pane, cell, visible })
        })
        .collect();
    pane_target(point, candidates, bars, style, previous)
}

/// A pane a drop may land in: its cell and the part of it nothing covers.
struct Candidate<'a> {
    pane: &'a String,
    cell: Rect,
    visible: Rect,
}

/// `paneTarget`: the pane whose visible rect holds `point`, else the nearest one, with the zone at the
/// nearest point of that pane. Candidates go in pane id order.
fn pane_target(
    point: Point,
    mut candidates: Vec<Candidate>,
    bars: &Bars,
    style: &DropStyle,
    previous: Option<&DropTarget>,
) -> Option<DropTarget> {
    candidates.sort_by(|a, b| a.pane.cmp(b.pane));
    let resolve = |point: Point, pane: &str, cell: Rect| {
        let shown = match previous {
            Some(DropTarget::Pane { pane: previous_pane, zone }) if previous_pane == pane => {
                Some(*zone)
            }
            _ => None,
        };
        zone(
            point,
            cell,
            header(pane, cell, bars, style),
            footer(pane, cell, bars, style),
            style,
            shown,
        )
    };
    if let Some(hit) = candidates.iter().find(|c| c.visible.contains(point)) {
        return Some(DropTarget::Pane {
            pane: hit.pane.clone(),
            zone: resolve(point, hit.pane, hit.cell),
        });
    }
    // `min(by:)`: the first of the nearest.
    let mut nearest: Option<&Candidate> = None;
    for candidate in &candidates {
        if nearest.is_none_or(|n| distance(point, candidate.visible) < distance(point, n.visible)) {
            nearest = Some(candidate);
        }
    }
    let nearest = nearest?;
    let clamped = clamp(point, nearest.visible);
    Some(DropTarget::Pane {
        pane: nearest.pane.clone(),
        zone: resolve(clamped, nearest.pane, nearest.cell),
    })
}

/// The distance from `point` to `rect` (0 inside).
pub fn distance(point: Point, rect: Rect) -> f64 {
    let dx = swift_max(swift_max(rect.min_x() - point.x, 0.), point.x - rect.max_x());
    let dy = swift_max(swift_max(rect.min_y() - point.y, 0.), point.y - rect.max_y());
    (dx * dx + dy * dy).sqrt()
}

/// `point` clamped into `rect`, edges included.
pub fn clamp(point: Point, rect: Rect) -> Point {
    Point::new(
        swift_min(swift_max(point.x, rect.min_x()), rect.max_x()),
        swift_min(swift_max(point.y, rect.min_y()), rect.max_y()),
    )
}

/// `dockTarget(atView:)` (DD1): an edge band that opens a dock while that edge has none (view
/// coordinates). Top and bottom win in the corners; the shown dock's band grows by the hysteresis, and
/// entered from the pane split zone facing the same edge it shrinks by at most half its depth.
/// `top_inset` and `bottom_inset` are the tab bar heights at those edges.
pub fn dock_target(
    point: Point,
    screen: &str,
    geometry: &DropGeometry,
    style: &DropStyle,
    top_inset: f64,
    bottom_inset: f64,
    previous: Option<&DropTarget>,
) -> Option<DropTarget> {
    let size = geometry.viewport;
    let band = swift_min(style.dock_drop_band, size.height / 4.);
    let top_band = swift_min(style.dock_top_drop_band, size.height / 4.);
    let side = swift_min(style.dock_drop_band / 2., size.width / 8.);
    let margin = swift_max(0., style.drop_zone_hysteresis);
    let new_dock = |edge: DockEdge| DropTarget::NewDock { screen: screen.to_owned(), edge };
    let extra = |edge: DockEdge, depth: f64| -> f64 {
        if previous == Some(&new_dock(edge)) {
            return margin;
        }
        match previous {
            Some(DropTarget::Pane { zone, .. }) if zone.faces(edge) => {
                -swift_min(margin, depth / 2.)
            }
            _ => 0.,
        }
    };
    let free = |edge: DockEdge| !geometry.dock.iter().any(|d| d.edge == edge);
    if point.y >= top_inset
        && point.y <= top_inset + top_band + extra(DockEdge::Top, top_band)
        && free(DockEdge::Top)
    {
        return Some(new_dock(DockEdge::Top));
    }
    let bottom = size.height - bottom_inset;
    if point.y >= bottom - band - extra(DockEdge::Bottom, band)
        && point.y <= bottom
        && free(DockEdge::Bottom)
    {
        return Some(new_dock(DockEdge::Bottom));
    }
    if point.x <= side + extra(DockEdge::Left, side) && free(DockEdge::Left) {
        return Some(new_dock(DockEdge::Left));
    }
    if point.x >= size.width - side - extra(DockEdge::Right, side) && free(DockEdge::Right) {
        return Some(new_dock(DockEdge::Right));
    }
    None
}

/// `dockPreview`: where a new dock would sit (view coordinates): a band 30% of the height across the
/// screen, or a side column 30% of the width down it, less the strip gaps.
pub fn dock_preview(edge: DockEdge, geometry: &DropGeometry, style: &DropStyle) -> Rect {
    let size = geometry.viewport;
    let gap = style.strip_gap();
    if edge.is_band() {
        let height = swift_min(size.height * 0.3, size.height * MAX_BAND_SHARE);
        let y = if edge == DockEdge::Top { 0. } else { size.height - height };
        return Rect::new(gap, y, swift_max(1., size.width - gap * 2.), height);
    }
    let width = size.width * 0.3;
    let x = if edge == DockEdge::Left { gap } else { size.width - width - gap };
    Rect::new(x, 0., swift_max(1., width), size.height)
}

/// `regionRect(for:)`: the whole region a drop on `target` divides (content space).
pub fn region_rect(
    target: &DropTarget,
    geometry: &DropGeometry,
    style: &DropStyle,
) -> Option<Rect> {
    match target {
        DropTarget::Pane { pane, .. } => {
            geometry.panes.get(pane).map(|cell| content_rect(*cell, style.pane_padding))
        }
        DropTarget::NewColumn { after, .. } => {
            geometry.gap_zones.iter().find(|z| z.after == *after).map(|z| z.frame)
        }
        DropTarget::NewDock { edge, .. } => Some(dock_preview(*edge, geometry, style)),
    }
}

/// `highlightRect(for:)`: where the glass highlight goes for `target` (content space).
pub fn highlight_rect(
    target: &DropTarget,
    geometry: &DropGeometry,
    style: &DropStyle,
) -> Option<Rect> {
    match target {
        DropTarget::Pane { pane, zone } => {
            let rect = content_rect(*geometry.panes.get(pane)?, style.pane_padding);
            Some(match zone {
                PaneDropZone::Center => rect,
                PaneDropZone::Left => {
                    Rect::new(rect.min_x(), rect.min_y(), rect.width() / 2., rect.height())
                }
                PaneDropZone::Right => {
                    Rect::new(rect.mid_x(), rect.min_y(), rect.width() / 2., rect.height())
                }
                PaneDropZone::Top => {
                    Rect::new(rect.min_x(), rect.min_y(), rect.width(), rect.height() / 2.)
                }
                PaneDropZone::Bottom => {
                    Rect::new(rect.min_x(), rect.mid_y(), rect.width(), rect.height() / 2.)
                }
            })
        }
        DropTarget::NewColumn { after, .. } => {
            geometry.gap_zones.iter().find(|z| z.after == *after).map(|z| z.frame)
        }
        DropTarget::NewDock { edge, .. } => Some(dock_preview(*edge, geometry, style)),
    }
}

/// A content-space rect in view coordinates with the strip at `offset`: docks and fixed panes stay.
fn in_view(rect: Rect, target: &DropTarget, offset: f64, geometry: &DropGeometry) -> Rect {
    match target {
        DropTarget::NewDock { .. } => rect,
        DropTarget::Pane { pane, .. } if !geometry.scrolls(pane) => rect,
        _ => rect.offset_by(geometry.view_shift(offset), 0.),
    }
}

/// `regionRectInView(for:offset:)`.
pub fn region_rect_in_view(
    target: &DropTarget,
    offset: f64,
    geometry: &DropGeometry,
    style: &DropStyle,
) -> Option<Rect> {
    region_rect(target, geometry, style).map(|rect| in_view(rect, target, offset, geometry))
}

/// `highlightRectInView(for:offset:)`.
pub fn highlight_rect_in_view(
    target: &DropTarget,
    offset: f64,
    geometry: &DropGeometry,
    style: &DropStyle,
) -> Option<Rect> {
    highlight_rect(target, geometry, style).map(|rect| in_view(rect, target, offset, geometry))
}

/// The inset of a pane zone's highlight inside the pane's body (classic cmux's 4 pt).
pub const CLASSIC_PANE_PADDING: f64 = 4.;

/// `classicPaneHighlight` (classic cmux's `compactOverlayFrame`): the body inset `padding` for center;
/// a half for an edge, inset on its three outer sides and meeting the midline.
pub fn classic_pane_highlight(body: Rect, zone: PaneDropZone, padding: f64) -> Rect {
    let (x, y, w, h) = (body.min_x(), body.min_y(), body.width(), body.height());
    let rect = match zone {
        PaneDropZone::Center => {
            Rect::new(x + padding, y + padding, w - padding * 2., h - padding * 2.)
        }
        PaneDropZone::Left => {
            Rect::new(x + padding, y + padding, body.mid_x() - x - padding, h - padding * 2.)
        }
        PaneDropZone::Right => Rect::new(
            body.mid_x(),
            y + padding,
            body.max_x() - body.mid_x() - padding,
            h - padding * 2.,
        ),
        PaneDropZone::Top => {
            Rect::new(x + padding, y + padding, w - padding * 2., body.mid_y() - y - padding)
        }
        PaneDropZone::Bottom => Rect::new(
            x + padding,
            body.mid_y(),
            w - padding * 2.,
            body.max_y() - body.mid_y() - padding,
        ),
    };
    Rect::new(rect.min_x(), rect.min_y(), swift_max(0., rect.width()), swift_max(0., rect.height()))
}
