//! Hover geometry in screen points, y up: the safe triangle (a pointer
//! heading for a shown card) and where a sidebar row's card sits
//! (`HoverCardEscapeGeometry`). Rectangles follow Core Graphics: `min_x` and
//! `max_x` read the standardized rect, `contains` is half open, and an inset
//! past empty gives the null rect.

/// A point.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct HoverPoint {
    pub x: f64,
    pub y: f64,
}

/// A rectangle: origin and size, as Core Graphics stores it.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
#[repr(C)]
pub struct HoverRect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Swift's `max(a, b)`: `b >= a ? b : a` (NaN handling included).
fn swift_max(a: f64, b: f64) -> f64 {
    if b >= a { b } else { a }
}

/// Swift's `min(a, b)`: `b < a ? b : a`.
fn swift_min(a: f64, b: f64) -> f64 {
    if b < a { b } else { a }
}

impl HoverRect {
    /// `CGRect.zero`.
    pub const ZERO: Self = Self { x: 0., y: 0., width: 0., height: 0. };
    /// `CGRect.null`.
    pub const NULL: Self = Self { x: f64::INFINITY, y: f64::INFINITY, width: 0., height: 0. };

    #[must_use]
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    #[must_use]
    pub fn is_null(&self) -> bool {
        self.x == f64::INFINITY || self.y == f64::INFINITY
    }

    #[must_use]
    pub fn min_x(&self) -> f64 {
        if self.width < 0. { self.x + self.width } else { self.x }
    }

    #[must_use]
    pub fn max_x(&self) -> f64 {
        if self.width < 0. { self.x } else { self.x + self.width }
    }

    #[must_use]
    pub fn min_y(&self) -> f64 {
        if self.height < 0. { self.y + self.height } else { self.y }
    }

    #[must_use]
    pub fn max_y(&self) -> f64 {
        if self.height < 0. { self.y } else { self.y + self.height }
    }

    #[must_use]
    pub fn mid_x(&self) -> f64 {
        self.min_x() + self.std_width() / 2.
    }

    #[must_use]
    pub fn mid_y(&self) -> f64 {
        self.min_y() + self.std_height() / 2.
    }

    /// `CGRect.width`: the standardized (never negative) width.
    #[must_use]
    pub fn std_width(&self) -> f64 {
        self.width.abs()
    }

    /// `CGRect.height`: the standardized height.
    #[must_use]
    pub fn std_height(&self) -> f64 {
        self.height.abs()
    }

    /// `CGRect.contains(_:)`: half open, false for a null or empty rect.
    #[must_use]
    pub fn contains(&self, p: HoverPoint) -> bool {
        !self.is_null()
            && p.x >= self.min_x()
            && p.x < self.max_x()
            && p.y >= self.min_y()
            && p.y < self.max_y()
    }

    /// `CGRect.intersects(_:)`: the rects share interior area.
    #[must_use]
    pub fn intersects(&self, other: &Self) -> bool {
        !self.is_null()
            && !other.is_null()
            && self.min_x() < other.max_x()
            && other.min_x() < self.max_x()
            && self.min_y() < other.max_y()
            && other.min_y() < self.max_y()
    }

    /// `CGRect.insetBy(dx:dy:)`: the null rect when the result would be
    /// narrower or shorter than zero.
    #[must_use]
    pub fn inset_by(&self, dx: f64, dy: f64) -> Self {
        if self.is_null() {
            return Self::NULL;
        }
        let width = self.std_width() - 2. * dx;
        let height = self.std_height() - 2. * dy;
        if width < 0. || height < 0. {
            return Self::NULL;
        }
        Self { x: self.min_x() + dx, y: self.min_y() + dy, width, height }
    }

    /// Whether a pointer moving from `from` to `to` heads for this rect (a
    /// shown card): `to` lies in it, or the move heads for it (its step toward
    /// the card is at least half its step along it) and `to` lies in the
    /// triangle from `from` to its nearer edge (the safe triangle: Amazon's
    /// menu aim, macOS submenus). A target it crosses on the way then does not
    /// take the card over.
    #[must_use]
    pub fn aimed_at(&self, from: Option<HoverPoint>, to: Option<HoverPoint>) -> bool {
        let _ = (from, to);
        false
    }
}

/// Which edge of the card goes where on its row.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum HoverRowAlignment {
    /// The card's top on the row's top (Chrome, Arc). No escape slot.
    #[default]
    Top,
    /// The card's top on the row's middle, below an escape slot beside the
    /// row's upper half (Debug Settings: `sidebar.hoverCardEscapeSlot`).
    Middle,
}

/// What a point is, for a shown card.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum HoverZone {
    /// On the row the card describes.
    Row,
    /// On the card.
    Card,
    /// In the empty slot beside the row: the card goes.
    Escape,
    /// Between the row and the card: the card stays only for a pointer heading into it.
    Gap,
    /// Anywhere else.
    Outside,
}

/// Where a sidebar row's hover card sits, and which part of the screen keeps
/// it. The card sits beside the sidebar with its top on the hovered row's top
/// (Leo 2026-10-21: "WHY HAS IT NOT BEEN ALIGNED"), touching the row's fill
/// (Leo 2026-10-28), and follows the row from row to row. Near the screen's
/// bottom edge the room clamps it up; near its right edge it goes left of
/// the row. `HoverRowAlignment::Middle` keeps the earlier escape-slot layout
/// (#22473, Leo 2026-10-20 "trapped by the preview").
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct HoverCardEscapeGeometry {
    /// The row's frame.
    pub anchor: HoverRect,
    /// The card's frame at rest.
    pub card: HoverRect,
    /// The empty slot beside the row that the card never covers; zero when
    /// the screen left no room for one (and always with `Top`).
    pub escape_slot: HoverRect,
    /// The strip between the row and the card, beside the card; zero when they touch.
    pub gap_strip: HoverRect,
    /// The card sits left of its row (no room on the right).
    pub is_leading: bool,
}

/// Sidebar row cards sit directly against their anchor.
pub const HOVER_ROW_GAP: f64 = 0.;

/// The room between a target and a `.beside` card (the update card, a pull
/// request badge's card): one device pixel of `scale`.
#[must_use]
pub fn hover_edge_gap(scale: f64) -> f64 {
    let _ = scale;
    0.
}

/// A sidebar row's anchor for its card: `row`'s vertical extent across
/// `column`'s horizontal one, so a row's inset, trailing trim or group depth
/// never moves the card sideways.
#[must_use]
pub fn hover_row_band(row: HoverRect, column: HoverRect) -> HoverRect {
    let _ = (row, column);
    HoverRect::ZERO
}

/// The room a row's card rests in: the screen's visible frame less `margin`,
/// and between its window's bottom and top, so the last row's card never
/// hangs below the window (Lawrence 2026-10-22). Across, the room is the
/// screen's: the card goes beside the sidebar, past the window's edge when the
/// window is no wider than the sidebar.
#[must_use]
pub fn hover_card_room(visible: HoverRect, window: Option<HoverRect>, margin: f64) -> HoverRect {
    let _ = (window, margin);
    visible
}

impl HoverCardEscapeGeometry {
    /// The card for `anchor` (a workspace's fill, or a group or rail band) at
    /// `size` (width, height), kept inside `visible` (the room, already inset
    /// by any margin) when given, its near edge `gap` (`HOVER_ROW_GAP` when
    /// `None`) off the anchor's edge on device pixels of `scale`, lined up
    /// with the row by `alignment`.
    #[must_use]
    pub fn new(
        anchor: HoverRect,
        size: (f64, f64),
        visible: Option<HoverRect>,
        scale: f64,
        gap: Option<f64>,
        alignment: HoverRowAlignment,
    ) -> Self {
        let _ = (size, visible, scale, gap, alignment);
        Self {
            anchor,
            card: HoverRect::ZERO,
            escape_slot: HoverRect::ZERO,
            gap_strip: HoverRect::ZERO,
            is_leading: false,
        }
    }

    /// What `point` is: the card first, then the row, the slot and the gap.
    #[must_use]
    pub fn zone(&self, point: HoverPoint) -> HoverZone {
        if self.card.contains(point) {
            HoverZone::Card
        } else if self.anchor.contains(point) {
            HoverZone::Row
        } else if self.escape_slot.contains(point) {
            HoverZone::Escape
        } else if self.gap_strip.contains(point) {
            HoverZone::Gap
        } else {
            HoverZone::Outside
        }
    }

    /// Whether the pointer at `point` keeps the card by where it is: on the
    /// row or on the card. In the gap only a pointer heading into the card
    /// keeps it (the coordinator's aim test).
    #[must_use]
    pub fn keeps_card(&self, point: HoverPoint) -> bool {
        matches!(self.zone(point), HoverZone::Row | HoverZone::Card)
    }
}
