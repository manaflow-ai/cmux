//! The scrolling column strip: its columns' frames, scroll range and snap offsets (Swift
//! `ColumnStripGeometry`), its scrollbar thumb (`StripScrollbarGeometry`, plans/cmux-next/dock-column.md
//! B1 to B3), the widths Equalize Splits gives its columns (`ColumnEqualizer`) and a scroll area's
//! cells (`ScrollAreaGeometry`).

use super::dock_strip::{self, DockMode, MAX_SHARE, MAX_SHARE_BOTH};
use super::split_layout::{self, SplitNode, SplitStyle, WIDTH_RANGE};
use super::{DockEdge, Rect, Size, SplitAxis, ceil_to_pixel, round_to_pixel, swift_max, swift_min};
use crate::shown_resize::{fraction, pixel_width};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// `ColumnStripGeometry.edgeTolerance`: how near the trailing edge a column's unrounded end counts as
/// reaching it.
pub const EDGE_TOLERANCE: f64 = 0.01;

/// `ColumnStripGeometry.frames(widths:viewport:gap:scale:minimumWidths:)`: each column's frame (y at 0,
/// the viewport's height) and the strip's content width. Rounding never pushes a column that fits past
/// the trailing edge nor stops it short of an edge it was meant to reach; a column widened to its
/// minimum makes the strip scroll.
pub fn frames(
    widths: &[f64],
    viewport: Size,
    gap: f64,
    scale: f64,
    minimum_widths: &[f64],
) -> (Vec<Rect>, f64) {
    let mut x = gap;
    let mut ideal_x = gap;
    let mut widened = false;
    let trailing_edge = viewport.width - gap;
    let mut frames = Vec::with_capacity(widths.len());
    let widest = swift_max(1., viewport.width - gap * 2.);
    for (index, &fraction) in widths.iter().enumerate() {
        let ideal = pixel_width(fraction, viewport.width, gap);
        let mut width = round_to_pixel(ideal, scale);
        let ideal_end = ideal_x + ideal;
        ideal_x = ideal_end + gap;
        let room = trailing_edge - x;
        if !widened
            && room >= 1.
            && ideal_end <= trailing_edge + EDGE_TOLERANCE
            && (width > room || (ideal_end - trailing_edge).abs() <= EDGE_TOLERANCE)
        {
            width = room;
        }
        if let Some(&minimum_width) = minimum_widths.get(index)
            && width < minimum_width
        {
            let minimum = ceil_to_pixel(swift_min(minimum_width, widest), scale);
            if minimum > width {
                width = minimum;
                widened = true;
            }
        }
        frames.push(Rect::new(x, 0., width, viewport.height));
        x += width + gap;
    }
    // Float sums land within a hair of the viewport; that hair is not scrollable content.
    let content = if frames.is_empty() {
        viewport.width
    } else if x - viewport.width < 0.001 {
        swift_min(x, viewport.width)
    } else {
        x
    };
    (frames, content)
}

/// `ColumnStripGeometry.maxOffset(contentWidth:viewportWidth:)`.
pub fn max_offset(content_width: f64, viewport_width: f64) -> f64 {
    swift_max(0., content_width - viewport_width)
}

/// `ColumnStripGeometry.clamp(_:contentWidth:viewportWidth:)`.
pub fn clamp(offset: f64, content_width: f64, viewport_width: f64) -> f64 {
    swift_min(swift_max(offset, 0.), max_offset(content_width, viewport_width))
}

/// `ColumnStripGeometry.snapOffsets(frames:contentWidth:viewportWidth:gap:)`: both ends and every
/// offset that rests a column's leading or trailing edge one gap inside the viewport, sorted, with
/// offsets within half a point of the one before dropped.
pub fn snap_offsets(
    frames: &[Rect],
    content_width: f64,
    viewport_width: f64,
    gap: f64,
) -> Vec<f64> {
    let mut values = vec![0., max_offset(content_width, viewport_width)];
    for frame in frames {
        values.push(clamp(frame.min_x() - gap, content_width, viewport_width));
        values.push(clamp(frame.max_x() + gap - viewport_width, content_width, viewport_width));
    }
    values.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mut result: Vec<f64> = Vec::with_capacity(values.len());
    for value in values {
        if result.last().is_none_or(|last| (last - value).abs() > 0.5) {
            result.push(value);
        }
    }
    result
}

/// `ColumnStripGeometry.leadingColumnIndex(frames:offset:gap:)`: the column whose leading edge sits
/// nearest one gap inside the viewport at `offset` (the first of a tie).
pub fn leading_column_index(frames: &[Rect], offset: f64, gap: f64) -> Option<usize> {
    let distance = |index: usize| (frames[index].min_x() - gap - offset).abs();
    (0..frames.len())
        .reduce(|best, index| if distance(index) < distance(best) { index } else { best })
}

/// `StripScrollbarGeometry.thumb(track:offset:contentWidth:viewportWidth:minimumThumbWidth:)` (B1): the
/// visible share of the strip on `track`, `None` when every column fits. A rubber-banded offset past an
/// end shortens the thumb at that end instead of moving it off the track.
pub fn scrollbar_thumb(
    track: Rect,
    offset: f64,
    content_width: f64,
    viewport_width: f64,
    minimum_thumb_width: f64,
) -> Option<Rect> {
    let max_offset = max_offset(content_width, viewport_width);
    if !(max_offset > 0.5 && track.width() > 0. && content_width > 0.) {
        return None;
    }
    let minimum = swift_min(minimum_thumb_width, track.width());
    let width = swift_max(minimum, track.width() * viewport_width / content_width);
    let travel = track.width() - width;
    let clamped = swift_min(swift_max(offset, 0.), max_offset);
    let mut rect = Rect::new(
        track.min_x() + travel * clamped / max_offset,
        track.min_y(),
        width,
        track.height(),
    );
    let overshoot = if offset < 0. { -offset } else { swift_max(0., offset - max_offset) };
    if overshoot > 0. {
        let shrunk = swift_max(minimum, width - overshoot * track.width() / content_width);
        if offset > max_offset {
            rect.x = rect.max_x() - shrunk;
        }
        rect.w = shrunk;
    }
    Some(rect)
}

/// `StripScrollbarGeometry.offset(forThumbMinX:thumbWidth:track:maxOffset:)` (B2): the offset a thumb
/// drag to `thumb_min_x` asks for, clamped to the strip.
pub fn scrollbar_offset(thumb_min_x: f64, thumb_width: f64, track: Rect, max_offset: f64) -> f64 {
    let travel = track.width() - thumb_width;
    if !(travel > 0. && max_offset > 0.) {
        return 0.;
    }
    let fraction = swift_min(swift_max((thumb_min_x - track.min_x()) / travel, 0.), 1.);
    fraction * max_offset
}

/// `StripScrollbarGeometry.pageTarget(clickX:thumb:offset:viewportWidth:snaps:)` (B3): a track click
/// beside the thumb pages one viewport toward the click and rests on the snap nearest that page, at
/// least one snap from `offset`. `None` for a click on the thumb or no snaps.
pub fn scrollbar_page_target(
    click_x: f64,
    thumb: Rect,
    offset: f64,
    viewport_width: f64,
    snaps: &[f64],
) -> Option<f64> {
    if !(click_x < thumb.min_x() || click_x > thumb.max_x()) {
        return None;
    }
    let (&lowest, &highest) = (snaps.first()?, snaps.last()?);
    let direction = if click_x < thumb.min_x() { -1. } else { 1. };
    let page = swift_min(swift_max(offset + direction * viewport_width, lowest), highest);
    let mut best = snaps
        .iter()
        .copied()
        .reduce(|best, snap| if (snap - page).abs() < (best - page).abs() { snap } else { best })
        .unwrap_or(page);
    if direction > 0. && best <= offset + 0.5 {
        best = snaps.iter().copied().find(|&snap| snap > offset + 0.5).unwrap_or(best);
    }
    if direction < 0. && best >= offset - 0.5 {
        best = snaps.iter().copied().rev().find(|&snap| snap < offset - 0.5).unwrap_or(best);
    }
    Some(best)
}

/// A column's dock: its edge and mode (the `DockColumn` fields equalizing reads).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColumnDock {
    pub edge: DockEdge,
    pub mode: DockMode,
}

/// One column for [`equalize`]: its id, width share, dock and minimum width in points
/// (`LayoutColumn.minimumSize(style:).width`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct EqualizeColumn {
    pub id: String,
    pub width: f64,
    #[serde(default)]
    pub dock: Option<ColumnDock>,
    #[serde(default)]
    pub minimum: f64,
}

/// `ColumnResize`: a column's new width share.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ColumnResize {
    pub column: String,
    pub width: f64,
}

/// `ColumnEqualizer.resizes`: the widths that give every column a person sees side by side one width
/// on screen, docked side docks included; empty when they are equal already. The strip's columns share
/// `1 / n` of it, `n` every strip column when all fit beside the docks at their minimum width, else the
/// strip columns in `visible` (empty: every one). Overlay docks and bands keep their widths.
pub fn equalize(
    columns: &[EqualizeColumn],
    visible: &BTreeSet<String>,
    viewport_width: f64,
    gap: f64,
) -> Vec<ColumnResize> {
    let edges: Vec<Option<DockEdge>> =
        columns.iter().map(|column| column.dock.map(|dock| dock.edge)).collect();
    let parts = dock_strip::parts(&edges);
    let strip: Vec<&EqualizeColumn> = parts
        .scrolling
        .iter()
        .map(|&index| &columns[index])
        .filter(|column| column.dock.is_none())
        .collect();
    if strip.is_empty() {
        return Vec::new();
    }
    let clamped = |value: f64| swift_min(swift_max(value, WIDTH_RANGE.0), WIDTH_RANGE.1);
    let mut result = Vec::new();
    let mut set = |column: &EqualizeColumn, width: f64| {
        if (column.width - width).abs() > 0.001 {
            result.push(ColumnResize { column: column.id.clone(), width });
        }
    };
    let sides: Vec<&EqualizeColumn> = [parts.left, parts.right]
        .into_iter()
        .flatten()
        .map(|index| &columns[index])
        .filter(|column| column.dock.is_some_and(|dock| dock.mode == DockMode::Docked))
        .collect();
    let equal_width = |count: usize| {
        let total = (sides.len() + count) as f64;
        (viewport_width - (total + 1.) * gap) / total
    };
    let widest = strip
        .iter()
        .map(|column| column.minimum)
        .reduce(|best, value| if value > best { value } else { best })
        .unwrap_or(0.);
    let fits_all = 1.0 / strip.len() as f64 >= WIDTH_RANGE.0
        && (viewport_width <= 0. || equal_width(strip.len()) >= widest);
    let shown = strip.iter().filter(|column| visible.contains(&column.id)).count();
    let strip_count = if fits_all || shown == 0 { strip.len() } else { shown };
    if !sides.is_empty() && viewport_width > gap {
        let equal = equal_width(strip_count);
        let share =
            if parts.left.is_some() && parts.right.is_some() { MAX_SHARE_BOTH } else { MAX_SHARE }
                * viewport_width;
        for dock in &sides {
            let width = swift_min(swift_max(equal, dock.minimum), share);
            set(dock, clamped(fraction(width, viewport_width, gap)));
        }
    }
    let each = clamped(1.0 / strip_count as f64);
    for column in strip {
        set(column, each);
    }
    result
}

/// `ScrollAreaGeometry.navigationRect(_:)`: `rect` in a scroll area's content scaled onto its window,
/// for the focus-navigation map.
pub fn scroll_area_navigation_rect(window: Rect, content_width: f64, rect: Rect) -> Rect {
    if content_width <= 0. {
        return rect;
    }
    let factor = window.width() / content_width;
    Rect::new(
        window.min_x() + (rect.min_x() - window.min_x()) * factor,
        rect.min_y(),
        rect.width() * factor,
        rect.height(),
    )
}

/// `ScrollAreaGeometry.cells(of:)`: the subtrees a scroll area lays side by side, its horizontal splits
/// taken apart in order.
pub fn scroll_area_cells(root: &SplitNode) -> Vec<&SplitNode> {
    match root {
        SplitNode::Split { axis: SplitAxis::Horizontal, a, b, .. } => {
            let mut cells = scroll_area_cells(a);
            cells.extend(scroll_area_cells(b));
            cells
        }
        _ => vec![root],
    }
}

/// `ScrollAreaGeometry.overflow(of:in:style:scale:)`: the split that scrolls inside `window` and its
/// content rect, when scroll areas are on and the tree's minimum width does not fit.
pub fn scroll_area_overflow(
    root: &SplitNode,
    window: Rect,
    style: &SplitStyle,
    scroll_areas_enabled: bool,
    scale: f64,
) -> Option<(String, Rect)> {
    let SplitNode::Split { split, .. } = root else { return None };
    if !scroll_areas_enabled {
        return None;
    }
    let needed = ceil_to_pixel(split_layout::minimum_size(root, style).width, scale);
    if needed <= window.width() + 0.5 {
        return None;
    }
    Some((split.clone(), Rect::new(window.min_x(), window.min_y(), needed, window.height())))
}
