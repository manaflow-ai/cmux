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

// Not in cmux_motion_ffi.h (cbindgen copies associated consts as macros, and
// NULL's `f64::INFINITY` is not C); Swift has CGRect.zero and CGRect.null.
impl HoverRect {
    /// `CGRect.zero`.
    ///
    /// cbindgen:ignore
    pub const ZERO: Self = Self { x: 0., y: 0., width: 0., height: 0. };
    /// `CGRect.null`.
    ///
    /// cbindgen:ignore
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
        let (Some(from), Some(to)) = (from, to) else { return false };
        let has_area = self.std_width() > 0. && self.std_height() > 0.;
        if !has_area || from == to {
            return false;
        }
        if self.contains(to) {
            return true;
        }
        let beside = from.x < self.min_x() || from.x > self.max_x();
        // The move must head for the card more than it runs along it: a
        // pointer sliding across a tab strip or down a list with a pixel of
        // drift toward the card is not aiming.
        let dx = to.x - from.x;
        let dy = to.y - from.y;
        let toward = if beside {
            if from.x < self.min_x() { dx } else { -dx }
        } else if from.y < self.min_y() {
            dy
        } else {
            -dy
        };
        let along = if beside { dy.abs() } else { dx.abs() };
        let heads_for_it = toward > 0. && toward * 2. >= along;
        if !heads_for_it {
            return false;
        }
        let (a, b) = if beside {
            let x = if from.x < self.min_x() { self.min_x() } else { self.max_x() };
            (HoverPoint { x, y: self.min_y() }, HoverPoint { x, y: self.max_y() })
        } else {
            let y = if from.y < self.min_y() { self.min_y() } else { self.max_y() };
            (HoverPoint { x: self.min_x(), y }, HoverPoint { x: self.max_x(), y })
        };
        // Inside the triangle `from a b` (either winding).
        let side =
            |p: HoverPoint, q: HoverPoint| (q.x - p.x) * (to.y - p.y) - (q.y - p.y) * (to.x - p.x);
        let ab = side(from, a);
        let bc = side(a, b);
        let ca = side(b, from);
        (ab >= 0. && bc >= 0. && ca >= 0.) || (ab <= 0. && bc <= 0. && ca <= 0.)
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
    1. / swift_max(scale, 1.)
}

/// A sidebar row's anchor for its card: `row`'s vertical extent across
/// `column`'s horizontal one, so a row's inset, trailing trim or group depth
/// never moves the card sideways.
#[must_use]
pub fn hover_row_band(row: HoverRect, column: HoverRect) -> HoverRect {
    HoverRect::new(column.min_x(), row.min_y(), column.std_width(), row.std_height())
}

/// The room a row's card rests in: the screen's visible frame less `margin`,
/// and between its window's bottom and top, so the last row's card never
/// hangs below the window (Lawrence 2026-10-22). Across, the room is the
/// screen's: the card goes beside the sidebar, past the window's edge when the
/// window is no wider than the sidebar.
#[must_use]
pub fn hover_card_room(visible: HoverRect, window: Option<HoverRect>, margin: f64) -> HoverRect {
    let screen = visible.inset_by(margin, margin);
    let Some(window) = window else { return screen };
    let bottom = swift_max(screen.min_y(), window.min_y());
    let top = swift_min(screen.max_y(), window.max_y());
    // Swift's `guard top > bottom else { return screen }` (NaN: the screen).
    if top > bottom {
        HoverRect::new(screen.min_x(), bottom, screen.std_width(), top - bottom)
    } else {
        screen
    }
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
        let (width, height) = size;
        let scale = swift_max(scale, 1.);
        let gap = gap.unwrap_or(HOVER_ROW_GAP);
        let up = |v: f64| (v * scale).ceil() / scale;
        let down = |v: f64| (v * scale).floor() / scale;
        let middle = down(anchor.mid_y());
        // Snap toward the row so a fractional edge never leaves a visible seam.
        let mut x = down(anchor.max_x()) + gap;
        let mut leading = false;
        if let Some(visible) = visible
            && x + width > visible.max_x()
            && up(anchor.min_x()) - gap - width >= visible.min_x()
        {
            x = up(anchor.min_x()) - gap - width;
            leading = true;
        }
        let mut below = true;
        let mut y = match alignment {
            // The card's top on the row's top, on a device pixel; the clamp
            // below keeps it on screen.
            HoverRowAlignment::Top => (anchor.max_y() * scale).round() / scale - height,
            // Below the slot: the card's top on the row's middle; above it
            // near the screen's bottom.
            HoverRowAlignment::Middle => {
                let mut y = middle - height;
                if let Some(visible) = visible
                    && y < visible.min_y()
                    && middle + height <= visible.max_y()
                {
                    y = middle;
                    below = false;
                }
                y
            }
        };
        if let Some(visible) = visible {
            x = swift_min(swift_max(x, visible.min_x()), visible.max_x() - width);
            y = swift_min(swift_max(y, visible.min_y()), visible.max_y() - height);
        }
        let card = HoverRect::new(x, y, width, height);
        // The slot spans from the row to the card's far edge, beside the
        // row's far half (the row's upper half when the card is below).
        let slot_x = if leading { card.min_x() } else { anchor.max_x() };
        let slot_width = if leading {
            swift_max(0., anchor.min_x() - slot_x)
        } else {
            swift_max(0., card.max_x() - slot_x)
        };
        let slot = if below {
            HoverRect::new(
                slot_x,
                card.max_y(),
                slot_width,
                swift_max(0., anchor.max_y() - card.max_y()),
            )
        } else {
            HoverRect::new(
                slot_x,
                anchor.min_y(),
                slot_width,
                swift_max(0., card.min_y() - anchor.min_y()),
            )
        };
        let escape_slot = if alignment == HoverRowAlignment::Middle
            && slot.std_width() > 0.
            && slot.std_height() > 0.
        {
            slot
        } else {
            HoverRect::ZERO
        };
        let strip = if leading {
            HoverRect::new(
                card.max_x(),
                card.min_y(),
                swift_max(0., anchor.min_x() - card.max_x()),
                card.std_height(),
            )
        } else {
            HoverRect::new(
                anchor.max_x(),
                card.min_y(),
                swift_max(0., card.min_x() - anchor.max_x()),
                card.std_height(),
            )
        };
        let gap_strip =
            if strip.std_width() > 0. && strip.std_height() > 0. { strip } else { HoverRect::ZERO };
        Self { anchor, card, escape_slot, gap_strip, is_leading: leading }
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
