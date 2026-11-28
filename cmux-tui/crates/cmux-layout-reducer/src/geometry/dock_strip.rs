//! Splits a columns screen into its docks and the scrolling strip, and places them (Swift
//! `DockStripGeometry`; plans/cmux-next/dock-column.md S1 to S6 for left and right,
//! plans/cmux-next/layout-model.md F1 to F5 for four edges and orientation).

use super::{DockEdge, Rect, Size, column_pixel_width, round_to_pixel, swift_max, swift_min};
use serde::{Deserialize, Serialize};

/// The largest share of the viewport width one side dock takes; with a dock on each side, each takes
/// at most `MAX_SHARE_BOTH`.
pub const MAX_SHARE: f64 = 0.75;
pub const MAX_SHARE_BOTH: f64 = 0.4;
/// The same for the height of top and bottom docks (F3).
pub const MAX_BAND_SHARE: f64 = 0.5;
pub const MAX_BAND_SHARE_BOTH: f64 = 1.0 / 3.0;
/// The narrowest scrolling strip docked side docks leave, in points (at most half the viewport).
pub const MINIMUM_STRIP_WIDTH: f64 = 400.;

/// How a docked column shares the viewport with the strip (Swift `DockMode`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DockMode {
    /// The strip's viewport shrinks to leave room; nothing is covered.
    Docked,
    /// The column floats over the strip, which keeps the full width.
    Overlay,
}

/// Which frames own the corners where a side dock meets a band (Swift `FrameOrientation`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FrameOrientation {
    /// Left and right docks run the full height; bands sit between them.
    #[default]
    ColumnMajor,
    /// Bands run the full width; side docks sit between them.
    RowMajor,
}

/// S1, S2: which columns hold an edge, by index into the screen's columns in daemon order.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Parts {
    pub left: Option<usize>,
    pub right: Option<usize>,
    pub top: Option<usize>,
    pub bottom: Option<usize>,
    /// The scrolling columns in order.
    pub scrolling: Vec<usize>,
    /// A lone dock fills the screen: its one scrolling column shows at width 1.
    pub lone: bool,
}

/// `DockStripGeometry.docks`: the first dock per edge (in daemon order) holds that edge; any other
/// column marked for that edge scrolls. A screen whose columns would all be docks shows them all in the
/// strip; a lone one (Home's pinned dock with nothing beside it) fills the screen. `edges` is each
/// column's dock edge, `None` for a strip column.
pub fn parts(edges: &[Option<DockEdge>]) -> Parts {
    let mut parts = Parts::default();
    for (index, edge) in edges.iter().enumerate() {
        let slot = match edge {
            Some(DockEdge::Left) => &mut parts.left,
            Some(DockEdge::Right) => &mut parts.right,
            Some(DockEdge::Top) => &mut parts.top,
            Some(DockEdge::Bottom) => &mut parts.bottom,
            None => {
                parts.scrolling.push(index);
                continue;
            }
        };
        if slot.is_none() {
            *slot = Some(index);
        } else {
            parts.scrolling.push(index);
        }
    }
    if parts.scrolling.is_empty() {
        let all = (0..edges.len()).collect();
        return Parts { scrolling: all, lone: edges.len() == 1, ..Parts::default() };
    }
    parts
}

/// One dock to place: its column, its dock (`None`: the column is no dock), its width fraction and its
/// panes' minimum extent (width for a side dock, height for a band).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Dock {
    pub column: String,
    pub mode: Option<DockMode>,
    pub edge: Option<DockEdge>,
    pub width: f64,
    #[serde(default)]
    pub minimum_extent: f64,
}

/// A dock placed at its viewport edge, in view coordinates (Swift `DockColumnFrame` less its pin,
/// which the caller keeps).
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct DockFrame {
    pub column: String,
    pub edge: DockEdge,
    pub mode: DockMode,
    pub frame: Rect,
    /// What the dock hides of the strip below it.
    pub cover: Rect,
    /// The glass rim's frame: the dock plus half a gap, inside the viewport; `None` for `CGRect.null`.
    pub glass: Option<Rect>,
}

/// The strip region and the dock frames for a viewport (Swift `DockStripGeometry.Placement`).
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Placement {
    pub strip_min_x: f64,
    pub strip_width: f64,
    pub strip_min_y: f64,
    pub strip_height: f64,
    pub leading_inset: f64,
    pub trailing_inset: f64,
    pub dock: Vec<DockFrame>,
    pub uncovered_min_x: f64,
    pub uncovered_max_x: f64,
    pub uncovered_min_y: f64,
    pub uncovered_max_y: f64,
    pub clip_min_x: f64,
    pub clip_max_x: f64,
    pub clip_min_y: f64,
    pub clip_max_y: f64,
}

/// The docks at the four edges, each optional.
#[derive(Clone, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct Docks {
    pub left: Option<Dock>,
    pub right: Option<Dock>,
    pub top: Option<Dock>,
    pub bottom: Option<Dock>,
}

/// `DockStripGeometry.place` (S3, S4, F1 to F3): a side dock's width is a fraction of the whole viewport
/// width, at least its panes' minimum and at most `MAX_SHARE` of the viewport; a band's height is the
/// same fraction of the viewport height, capped by `MAX_BAND_SHARE`. Docked side docks shrink in
/// proportion so the strip keeps `MINIMUM_STRIP_WIDTH`. Orientation decides the corners.
pub fn place(
    docks: &Docks,
    viewport: Size,
    gap: f64,
    orientation: FrameOrientation,
    scale: f64,
) -> Placement {
    let size = Rect::new(0., 0., viewport.width, viewport.height);
    // A dock without a docked value is not a dock.
    let (left, right, top, bottom) =
        (pinned(&docks.left), pinned(&docks.right), pinned(&docks.top), pinned(&docks.bottom));
    let side_share = if left.is_some() && right.is_some() { MAX_SHARE_BOTH } else { MAX_SHARE };
    let band_share =
        if top.is_some() && bottom.is_some() { MAX_BAND_SHARE_BOTH } else { MAX_BAND_SHARE };
    let extent = |dock: &Dock, length: f64, share: f64| {
        let raw = column_pixel_width(dock.width, length, gap);
        let widest = swift_max(1., length * share);
        round_to_pixel(swift_min(swift_max(raw, dock.minimum_extent), widest), scale)
    };
    let mut left_width = left.map(|d| extent(d, viewport.width, side_share));
    let mut right_width = right.map(|d| extent(d, viewport.width, side_share));
    let top_height = top.map(|d| extent(d, viewport.height, band_share));
    let bottom_height = bottom.map(|d| extent(d, viewport.height, band_share));
    let docked = |dock: Option<&Dock>| dock.and_then(|d| d.mode) == Some(DockMode::Docked);
    let docked_left = if docked(left) { left_width } else { None };
    let docked_right = if docked(right) { right_width } else { None };
    let used = docked_left.unwrap_or(0.) + docked_right.unwrap_or(0.);
    let gaps = gap * [docked_left, docked_right].iter().filter(|w| w.is_some()).count() as f64;
    let room = viewport.width - swift_min(MINIMUM_STRIP_WIDTH, viewport.width / 2.) - gaps;
    if used > 0. && used > room && room > 0. {
        let factor = room / used;
        if docked_left.is_some() {
            left_width = left_width.map(|w| round_to_pixel(w * factor, scale));
        }
        if docked_right.is_some() {
            right_width = right_width.map(|w| round_to_pixel(w * factor, scale));
        }
    }

    // The strip: docked docks take space, overlay docks inset (S4, F2).
    let mut p = Placement {
        strip_min_x: 0.,
        strip_width: viewport.width,
        strip_min_y: 0.,
        strip_height: 0.,
        leading_inset: 0.,
        trailing_inset: 0.,
        dock: Vec::new(),
        uncovered_min_x: 0.,
        uncovered_max_x: viewport.width,
        uncovered_min_y: 0.,
        uncovered_max_y: 0.,
        clip_min_x: 0.,
        clip_max_x: viewport.width,
        clip_min_y: 0.,
        clip_max_y: 0.,
    };
    let mut strip_max_x = viewport.width;
    let mut strip_min_y = 0.;
    let mut strip_max_y = viewport.height;
    let mut uncovered_min_y = 0.;
    let mut uncovered_max_y = viewport.height;
    let mut clip_min_y = 0.;
    let mut clip_max_y = viewport.height;
    if let Some(left_width) = left_width {
        let inner = gap + left_width;
        if docked(left) {
            p.strip_min_x = inner;
            p.uncovered_min_x = inner;
            p.clip_min_x = inner;
        } else {
            p.leading_inset = inner;
            p.uncovered_min_x = inner + gap / 2.;
            p.clip_min_x = gap / 2.;
        }
    }
    if let Some(right_width) = right_width {
        let inner = viewport.width - gap - right_width;
        if docked(right) {
            strip_max_x = inner;
            p.uncovered_max_x = inner;
            p.clip_max_x = inner;
        } else {
            p.trailing_inset = viewport.width - inner;
            p.uncovered_max_x = inner - gap / 2.;
            p.clip_max_x = viewport.width - gap / 2.;
        }
    }
    if let Some(top_height) = top_height {
        // Strip panes have no gap above them, so a band adds its own.
        strip_min_y = top_height + gap;
        uncovered_min_y = if docked(top) { strip_min_y } else { top_height + gap / 2. };
        clip_min_y = if docked(top) { strip_min_y } else { 0. };
    }
    if let Some(bottom_height) = bottom_height {
        strip_max_y = viewport.height - bottom_height - gap;
        uncovered_max_y =
            if docked(bottom) { strip_max_y } else { viewport.height - bottom_height - gap / 2. };
        clip_max_y = if docked(bottom) { strip_max_y } else { viewport.height };
    }
    p.strip_width = swift_max(1., strip_max_x - p.strip_min_x);
    p.strip_min_y = strip_min_y;
    p.strip_height = swift_max(1., strip_max_y - strip_min_y);
    p.uncovered_min_y = uncovered_min_y;
    p.uncovered_max_y = uncovered_max_y;
    p.clip_min_y = clip_min_y;
    p.clip_max_y = clip_max_y;

    // The docks' lengths: column-major sides run the full height and bands sit between the sides' inner
    // edges; row-major bands run the full width and sides sit between the bands' inner edges.
    let row_major = orientation == FrameOrientation::RowMajor;
    let side_min_y = if row_major { top_height.map_or(0., |h| h + gap) } else { 0. };
    let side_max_y = if row_major {
        bottom_height.map_or(viewport.height, |h| viewport.height - h - gap)
    } else {
        viewport.height
    };
    let band_min_x = if row_major { gap } else { left_width.map_or(gap, |w| gap + w + gap) };
    let band_max_x = if row_major {
        viewport.width - gap
    } else {
        right_width.map_or(viewport.width - gap, |w| viewport.width - gap - w - gap)
    };
    let entry = |dock: &Dock, frame: Rect, cover: Rect| -> Option<DockFrame> {
        let glass = frame.inset_by(-gap / 2., -gap / 2.).and_then(|g| g.intersection(&size));
        Some(DockFrame {
            column: dock.column.clone(),
            edge: dock.edge?,
            mode: dock.mode?,
            frame,
            cover,
            glass,
        })
    };
    let side_height = swift_max(0., side_max_y - side_min_y);
    let band_width = swift_max(0., band_max_x - band_min_x);
    if let (Some(left), Some(left_width)) = (left, left_width) {
        let frame = Rect::new(gap, side_min_y, left_width, side_height);
        let cover = Rect::new(0., side_min_y, p.uncovered_min_x, frame.height());
        p.dock.extend(entry(left, frame, cover));
    }
    if let (Some(right), Some(right_width)) = (right, right_width) {
        let frame =
            Rect::new(viewport.width - gap - right_width, side_min_y, right_width, side_height);
        let cover_x = p.uncovered_max_x;
        let cover = Rect::new(cover_x, side_min_y, viewport.width - cover_x, frame.height());
        p.dock.extend(entry(right, frame, cover));
    }
    let band_cover_min_x = if row_major { 0. } else { p.uncovered_min_x };
    let band_cover_max_x = if row_major { viewport.width } else { p.uncovered_max_x };
    if let (Some(top), Some(top_height)) = (top, top_height) {
        let frame = Rect::new(band_min_x, 0., band_width, top_height);
        let cover =
            Rect::new(band_cover_min_x, 0., band_cover_max_x - band_cover_min_x, uncovered_min_y);
        p.dock.extend(entry(top, frame, cover));
    }
    if let (Some(bottom), Some(bottom_height)) = (bottom, bottom_height) {
        let frame =
            Rect::new(band_min_x, viewport.height - bottom_height, band_width, bottom_height);
        let cover = Rect::new(
            band_cover_min_x,
            uncovered_max_y,
            band_cover_max_x - band_cover_min_x,
            viewport.height - uncovered_max_y,
        );
        p.dock.extend(entry(bottom, frame, cover));
    }
    p
}

fn pinned(dock: &Option<Dock>) -> Option<&Dock> {
    dock.as_ref().filter(|d| d.mode.is_some() && d.edge.is_some())
}

/// `ownsCorners`: the docks that own the frame's corners and draw above the others (F4).
pub fn owns_corners(edge: DockEdge, orientation: FrameOrientation) -> bool {
    match orientation {
        FrameOrientation::ColumnMajor => !edge.is_band(),
        FrameOrientation::RowMajor => edge.is_band(),
    }
}
