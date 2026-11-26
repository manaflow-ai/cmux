//! The drop overlay's pure geometry, moved out of the app's Swift (cmux
//! NEXT `DropOverlayGeometry.swift`). Flipped coordinates: y grows down, so
//! `min_y` is the top. The app keeps the paths it draws (rounded rects,
//! rings, brackets, the spotlight); these rules say where they go.

use serde::{Deserialize, Serialize};

/// A rectangle in the overlay plane.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    #[must_use]
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    fn max_x(self) -> f64 {
        self.x + self.width
    }

    fn max_y(self) -> f64 {
        self.y + self.height
    }

    fn mid_x(self) -> f64 {
        self.x + self.width / 2.0
    }

    fn mid_y(self) -> f64 {
        self.y + self.height / 2.0
    }
}

/// A point in the overlay plane.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// Where a drop lands relative to its region (`DropOverlayZone`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Zone {
    Center,
    Left,
    Right,
    Top,
    Bottom,
    /// Between columns (a new strip column).
    Column,
}

/// A rect edge (`CGRectEdge`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RectEdge {
    MinX,
    MaxX,
    MinY,
    MaxY,
}

/// The two panes a split creates inside `region`: the incoming one on the
/// zone's side and the existing one, each giving up half of `gap`. A center
/// or column drop creates no second pane.
#[must_use]
pub fn split_preview(region: Rect, zone: Zone, gap: f64) -> (Rect, Option<Rect>) {
    let half = gap.max(0.0) / 2.0;
    match zone {
        Zone::Left | Zone::Right => {
            let width = (region.width / 2.0 - half).max(0.0);
            let leading = Rect::new(region.x, region.y, width, region.height);
            let trailing = Rect::new(region.max_x() - width, region.y, width, region.height);
            if zone == Zone::Left { (leading, Some(trailing)) } else { (trailing, Some(leading)) }
        }
        Zone::Top | Zone::Bottom => {
            let height = (region.height / 2.0 - half).max(0.0);
            let upper = Rect::new(region.x, region.y, region.width, height);
            let lower = Rect::new(region.x, region.max_y() - height, region.width, height);
            if zone == Zone::Top { (upper, Some(lower)) } else { (lower, Some(upper)) }
        }
        Zone::Center | Zone::Column => (region, None),
    }
}

/// The insertion caret: on the line where the new divider appears for a
/// split, along the tab strip (top edge) for a center drop, and down the
/// middle of a column gap. `length` is a share of that edge.
#[must_use]
pub fn insertion_line(region: Rect, zone: Zone, width: f64, length: f64) -> Rect {
    let share = length.clamp(0.0, 1.0);
    match zone {
        Zone::Left | Zone::Right | Zone::Column => {
            let height = region.height * share;
            Rect::new(region.mid_x() - width / 2.0, region.mid_y() - height / 2.0, width, height)
        }
        Zone::Top | Zone::Bottom => {
            let span = region.width * share;
            Rect::new(region.mid_x() - span / 2.0, region.mid_y() - width / 2.0, span, width)
        }
        Zone::Center => {
            let span = region.width * share;
            Rect::new(region.mid_x() - span / 2.0, region.y + width, span, width)
        }
    }
}

/// Edges a glow grows from: the side the new pane takes, every edge for a
/// center drop or a column gap.
#[must_use]
pub fn glow_edges(zone: Zone) -> &'static [RectEdge] {
    match zone {
        Zone::Left => &[RectEdge::MinX],
        Zone::Right => &[RectEdge::MaxX],
        Zone::Top => &[RectEdge::MinY],
        Zone::Bottom => &[RectEdge::MaxY],
        Zone::Center | Zone::Column => {
            &[RectEdge::MinX, RectEdge::MaxX, RectEdge::MinY, RectEdge::MaxY]
        }
    }
}

/// A band of `depth` along `edge` of `rect` (flipped: `min_y` is the top),
/// the slice `CGRect.divided(atDistance:from:)` cuts.
#[must_use]
pub fn band(rect: Rect, edge: RectEdge, depth: f64) -> Rect {
    let across = |rect: Rect| match edge {
        RectEdge::MinX | RectEdge::MaxX => rect.width,
        RectEdge::MinY | RectEdge::MaxY => rect.height,
    };
    // The depth is clamped to the rect as given, then cut from the
    // standardized rect as `divided` does (never below 0 nor past its side).
    let depth = depth.max(0.0).min(across(rect));
    let rect = standardized(rect);
    let depth = depth.max(0.0).min(across(rect));
    match edge {
        RectEdge::MinX => Rect::new(rect.x, rect.y, depth, rect.height),
        RectEdge::MaxX => Rect::new(rect.max_x() - depth, rect.y, depth, rect.height),
        RectEdge::MinY => Rect::new(rect.x, rect.y, rect.width, depth),
        RectEdge::MaxY => Rect::new(rect.x, rect.max_y() - depth, rect.width, depth),
    }
}

/// `rect` with a non-negative size, as Core Graphics reads it.
fn standardized(rect: Rect) -> Rect {
    let (x, width) =
        if rect.width < 0.0 { (rect.x + rect.width, -rect.width) } else { (rect.x, rect.width) };
    let (y, height) = if rect.height < 0.0 {
        (rect.y + rect.height, -rect.height)
    } else {
        (rect.y, rect.height)
    };
    Rect::new(x, y, width, height)
}

/// A card of `fraction` of the target's width (at most `max_width`) and
/// `height`, centered in it and never larger than it.
#[must_use]
pub fn inset_card(target: Rect, fraction: f64, max_width: f64, height: f64) -> Rect {
    let width = (target.width * fraction.clamp(0.0, 1.0)).min(max_width).min(target.width);
    let card_height = height.min(target.height);
    Rect::new(target.mid_x() - width / 2.0, target.mid_y() - card_height / 2.0, width, card_height)
}

/// The tab pill at the target's top leading corner, inset by `inset`,
/// `width` wide (at most the target's width less the insets).
#[must_use]
pub fn tab_pill(target: Rect, width: f64, height: f64, inset: f64) -> Rect {
    let pill_width = width.min(target.width - inset * 2.0).max(0.0);
    let pill_height = height.min(target.height - inset * 2.0).max(0.0);
    Rect::new(target.x + inset, target.y + inset, pill_width, pill_height)
}

/// The card a morph starts from: centered on the pointer, `width` wide with a
/// 3:2 aspect (its height rounded half away from zero, as Swift's `rounded()`).
#[must_use]
pub fn morph_start(pointer: Point, width: f64) -> Rect {
    let height = (width * 2.0 / 3.0).round();
    Rect::new(pointer.x - width / 2.0, pointer.y - height / 2.0, width, height)
}

#[cfg(test)]
#[path = "drop_overlay_geometry_tests.rs"]
mod tests;
