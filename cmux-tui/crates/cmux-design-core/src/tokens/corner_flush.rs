//! The flush corner and concentric corners. Ports:
//!
//! - `CmuxNextDesign/CornerFlush.swift`: `enum CornerFlush` (values, titles, `current`'s resolution,
//!   `defaultFits`, `isOn`, `sidebarRowFlows`, `feetRadius`, `cardRadius`, `gap`, `sidebarGap`,
//!   `shade(isDark:)`) and the pure decisions and geometry inside the `CornerFlushChrome` view class
//!   (`topInset`, `apply`'s show test, `redraw`'s mode, `dividerLine`, `dividerSegments`,
//!   `toolbarPanes`, `tabRowEdge`, `hasTopStrip`, `markTopRow`, `leadingTabSelected`,
//!   `sidebarFolderPath`'s pieces and `wedgePath`'s rects). The protocols `TabStripCorner` and
//!   `SidebarSelectionCorner` have no default implementations; what a strip reports is [`StripReport`].
//!   The `extension Metrics` in that file is another module's.
//! - `CmuxNextDesignTokens/ConcentricContainer.swift` ([`ConcentricContainer`], `violations` and its
//!   private `format`).
//! - `CmuxNextDesignTokens/ConcentricCorners.swift` ([`ConcentricCorners`]).
//!
//! Values Swift reads from elsewhere (`Metrics.scale`, `Metrics.standardWindowCornerRadius`,
//! `DesignSettings`, the Debug Settings tunables, window and view frames) are inputs. Coordinates
//! are AppKit's unflipped ones (maxY is the top), as in Swift.

use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `LayoutGrid.base`: one grid step, unscaled.
pub const LAYOUT_GRID_BASE: f64 = 4.0;
/// The `flush-goo` fillets' radius, unscaled (`feetRadius`'s `Metrics.scale(8)`).
pub const FEET_RADIUS: f64 = 8.0;
/// `ChromeTunables.mainPaneShadeDark`'s default.
pub const MAIN_PANE_SHADE_DARK: f64 = 0.28;
/// `ChromeTunables.mainPaneShadeLight`'s default.
pub const MAIN_PANE_SHADE_LIGHT: f64 = 0.045;
/// `Metrics.folderTabMinimumShade`: the least shade under which tabs are folders.
pub const FOLDER_TAB_MINIMUM_SHADE: f64 = 0.011;
/// The Debug Settings tunable's key.
pub const TUNABLE_KEY: &str = "chrome.cornerFlush";
/// The tunable's default value.
pub const DEFAULT: CornerFlush = CornerFlush::Flush;
/// How near (pt) a strip's bottom must be to the card's top to sit on its top row.
pub const TOP_ROW_TOLERANCE: f64 = 2.0;
/// How near (pt) a strip's leading edge must be to the card's to be its leading strip.
pub const LEADING_TOLERANCE: f64 = 1.0;

/// A rectangle (CGRect); its min, max and size read standardized, as CGRect's do.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    /// The origin's x.
    pub x: f64,
    /// The origin's y.
    pub y: f64,
    /// The width (may be negative, as CGRect's).
    pub width: f64,
    /// The height (may be negative, as CGRect's).
    pub height: f64,
}

impl Rect {
    /// A rect from its origin and size.
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Rect {
        Rect { x, y, width, height }
    }
    /// CGRect `minX`.
    pub fn min_x(&self) -> f64 {
        self.x.min(self.x + self.width)
    }
    /// CGRect `maxX`.
    pub fn max_x(&self) -> f64 {
        self.x.max(self.x + self.width)
    }
    /// CGRect `minY`.
    pub fn min_y(&self) -> f64 {
        self.y.min(self.y + self.height)
    }
    /// CGRect `maxY`.
    pub fn max_y(&self) -> f64 {
        self.y.max(self.y + self.height)
    }
    /// CGRect `midX`.
    pub fn mid_x(&self) -> f64 {
        self.min_x() + self.w() / 2.0
    }
    /// CGRect `width` (standardized).
    pub fn w(&self) -> f64 {
        self.width.abs()
    }
    /// CGRect `height` (standardized).
    pub fn h(&self) -> f64 {
        self.height.abs()
    }
    /// CGRect `isEmpty`: no width or no height.
    pub fn is_empty(&self) -> bool {
        self.width == 0.0 || self.height == 0.0 || self.width.is_nan() || self.height.is_nan()
    }
}

/// A size (CGSize).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Size {
    /// The width.
    pub width: f64,
    /// The height.
    pub height: f64,
}

/// A point (CGPoint).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Point {
    /// x.
    pub x: f64,
    /// y.
    pub y: f64,
}

/// A closed range (`ClosedRange<CGFloat>`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Span {
    /// `lowerBound`.
    pub lower: f64,
    /// `upperBound`.
    pub upper: f64,
}

// MARK: - CornerFlush

/// `appearance.cornerFlush` (Swift `CornerFlush`), raw values as Swift's.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum CornerFlush {
    /// The older corner: the selected tab is a gray pill on the frame.
    #[serde(rename = "off")]
    Off,
    /// The card sits one grid step inside the frame on every side.
    #[serde(rename = "flush")]
    Flush,
    /// No gap on the sidebar's side.
    #[serde(rename = "flush-tight")]
    Tight,
    /// `flush`, with concave fillets where the selected tab meets the card.
    #[serde(rename = "flush-goo")]
    Goo,
}

/// What `CornerFlush.current` reads (Swift's `Metrics.density`, `DesignSettings` and the tunable).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CurrentInputs {
    /// `Metrics.density == .compact`.
    #[serde(default)]
    pub compact: bool,
    /// `DesignSettings.gooeyTabs.isOn`.
    #[serde(default)]
    pub gooey_tabs: bool,
    /// The Debug Settings pick of `chrome.cornerFlush`, if any.
    #[serde(default)]
    pub tunable_override: Option<CornerFlush>,
    /// `appearance.cornerFlush`, if set.
    #[serde(default)]
    pub setting: Option<CornerFlush>,
    /// `defaultFits` (see [`default_fits`]).
    #[serde(default)]
    pub default_fits: bool,
}

/// What `CornerFlush.defaultFits` reads. Strings are the Swift enums' raw values; each `*Set` is
/// whether that optional is non-nil.
#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DefaultFitsInputs {
    /// `appearance.chromeStyle` (`ChromeStyle` raw value).
    pub chrome_style: String,
    /// `TabBarPosition` raw value (`top`, `bottom`).
    pub tab_bar_position: String,
    /// `TabBarOrder` raw value (`aboveToolbar`, `belowToolbar`).
    pub tab_bar_order: String,
    /// Vertical tabs.
    #[serde(default)]
    pub vertical_tabs: bool,
    /// `paneChrome.padding != nil`.
    #[serde(default)]
    pub padding_set: bool,
    /// `paneChrome.cornerRadius != nil`.
    #[serde(default)]
    pub corner_radius_set: bool,
    /// `paneChrome.cornerPadding != nil`.
    #[serde(default)]
    pub corner_padding_set: bool,
    /// `paneChrome.border != nil`.
    #[serde(default)]
    pub border_set: bool,
    /// `paneChrome.borderColor != nil`.
    #[serde(default)]
    pub border_color_set: bool,
    /// `paneChrome.borderWidth != nil`.
    #[serde(default)]
    pub border_width_set: bool,
    /// `paneChrome.separation != nil`.
    #[serde(default)]
    pub separation_set: bool,
    /// `ChromeTunables.mainPaneCurved.override != nil`.
    #[serde(default)]
    pub main_pane_curved_set: bool,
    /// `ChromeTunables.mainPaneGutter.override != nil`.
    #[serde(default)]
    pub main_pane_gutter_set: bool,
    /// `ChromeTunables.mainPaneCornerRadius.override != nil`.
    #[serde(default)]
    pub main_pane_corner_radius_set: bool,
}

impl CornerFlush {
    /// Every value, in Swift's `allCases` order.
    pub const ALL: [CornerFlush; 4] =
        [CornerFlush::Off, CornerFlush::Flush, CornerFlush::Tight, CornerFlush::Goo];

    /// The raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            CornerFlush::Off => "off",
            CornerFlush::Flush => "flush",
            CornerFlush::Tight => "flush-tight",
            CornerFlush::Goo => "flush-goo",
        }
    }

    /// The value a raw value names (Swift `CornerFlush(rawValue:)`).
    pub fn from_raw(raw: &str) -> Option<CornerFlush> {
        Self::ALL.into_iter().find(|v| v.raw_value() == raw)
    }

    /// The Debug Settings title (`tunableTitle`).
    pub fn tunable_title(self) -> &'static str {
        match self {
            CornerFlush::Off => "Off: a gray pill on the frame",
            CornerFlush::Flush => "Flush: the first tab rises from the card's edge",
            CornerFlush::Tight => "Flush, tight: the card meets the sidebar",
            CornerFlush::Goo => "Flush, goo: the selected tab flows into the card",
        }
    }

    /// `isOn`: anything but `off`.
    pub fn is_on(self) -> bool {
        self != CornerFlush::Off
    }

    /// `feetRadius`: `Metrics.scale(8)` under `flush-goo`, else 0. `scale` is `Metrics.scale`'s factor.
    pub fn feet_radius(self, scale: f64) -> f64 {
        if self == CornerFlush::Goo { FEET_RADIUS * scale } else { 0.0 }
    }

    /// `gap`: the frame's gap around the card, `Metrics.scale(LayoutGrid.base)`.
    pub fn gap(self, scale: f64) -> f64 {
        LAYOUT_GRID_BASE * scale
    }

    /// `cardRadius`: the card's radius in a square-cornered window,
    /// `max(0, standardWindowCornerRadius - gap)`.
    pub fn card_radius(self, standard_window_corner_radius: f64, scale: f64) -> f64 {
        (standard_window_corner_radius - self.gap(scale)).max(0.0)
    }

    /// `sidebarGap`: 0 under `flush-tight`, the gap under the other flush values, None when off.
    pub fn sidebar_gap(self, scale: f64) -> Option<f64> {
        if self.is_on() {
            Some(if self == CornerFlush::Tight { 0.0 } else { self.gap(scale) })
        } else {
            None
        }
    }
}

/// `CornerFlush.chosen`: gooey tabs pick `flush-goo`; else the tunable's pick, else the setting.
pub fn chosen(inputs: &CurrentInputs) -> Option<CornerFlush> {
    if inputs.gooey_tabs {
        return Some(CornerFlush::Goo);
    }
    inputs.tunable_override.or(inputs.setting)
}

/// `CornerFlush.current`: `off` at compact density; else [`chosen`]; else the default where it fits.
pub fn current(inputs: &CurrentInputs) -> CornerFlush {
    if inputs.compact {
        return CornerFlush::Off;
    }
    if let Some(chosen) = chosen(inputs) {
        return chosen;
    }
    if inputs.default_fits { DEFAULT } else { CornerFlush::Off }
}

/// `CornerFlush.isChosen`: picked rather than defaulted, and drawing.
pub fn is_chosen(inputs: &CurrentInputs) -> bool {
    chosen(inputs).is_some() && current(inputs).is_on()
}

/// `CornerFlush.sidebarRowFlows`: `flush-goo` in effect on a block tab shape (`tabShape.runsIntoCard`).
pub fn sidebar_row_flows(current: CornerFlush, tab_shape_runs_into_card: bool) -> bool {
    current == CornerFlush::Goo && tab_shape_runs_into_card
}

/// `CornerFlush.defaultFits`: the default draws only over the stock chrome.
pub fn default_fits(inputs: &DefaultFitsInputs) -> bool {
    if !matches!(inputs.chrome_style.as_str(), "flat" | "default")
        || inputs.tab_bar_position != "top"
        || inputs.tab_bar_order != "aboveToolbar"
        || inputs.vertical_tabs
    {
        return false;
    }
    if inputs.padding_set
        || inputs.corner_radius_set
        || inputs.corner_padding_set
        || inputs.border_set
        || inputs.border_color_set
        || inputs.border_width_set
        || inputs.separation_set
    {
        return false;
    }
    !inputs.main_pane_curved_set
        && !inputs.main_pane_gutter_set
        && !inputs.main_pane_corner_radius_set
}

/// `shade(isDark:)`: the main pane's shade tunable for the theme (`shade_dark`, `shade_light` are
/// the tunables' values; [`MAIN_PANE_SHADE_DARK`], [`MAIN_PANE_SHADE_LIGHT`] by default).
pub fn shade(is_dark: bool, shade_dark: f64, shade_light: f64) -> f64 {
    if is_dark { shade_dark } else { shade_light }
}

// MARK: - CornerFlushChrome's decisions

/// `CornerFlushChrome.topInset(of:)`: the card top inset that centers the top row's pills on the
/// traffic lights' line; None when the corner is off or the tabs are at the bottom (or the window or
/// its lights are missing, which the caller says by passing None for `center_from_top`).
pub fn top_inset(
    is_on: bool,
    tabs_at_bottom: bool,
    center_from_top: Option<f64>,
    backing_scale: f64,
    pane_padding: f64,
    pill_top: f64,
    tab_height: f64,
) -> Option<f64> {
    if !is_on || tabs_at_bottom {
        return None;
    }
    let center_from_top = center_from_top?;
    let pill_center = pane_padding + pill_top + tab_height / 2.0;
    Some(((center_from_top - pill_center) * backing_scale).round() / backing_scale)
}

/// `apply`'s `on`: the corner draws over this content (not a page, tabs not at the bottom).
pub fn content_on(is_on: bool, page: bool, tabs_at_bottom: bool) -> bool {
    is_on && !page && !tabs_at_bottom
}

/// `apply`'s show test: the chrome shows when on, the shade's base is above 0, the radius is above 0
/// and the chrome sits in the root.
pub fn chrome_shows(on: bool, shade_base: f64, radius: f64, in_root: bool) -> bool {
    on && shade_base > 0.0 && radius > 0.0 && in_root
}

/// `redraw`'s card: the content less the tab strip (the top is maxY).
pub fn card_below_strip(content: Rect, strip_height: f64) -> Rect {
    let mut card = content;
    card.height = (card.h() - strip_height).max(0.0);
    card
}

/// What `redraw` draws.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RedrawMode {
    /// No whole tab row: the card is the whole content, rounded on every corner, no wedges.
    NoTopStrip,
    /// The shade is under the folder minimum: the selected tab keeps its pill, only the divider shows.
    Pill,
    /// Folder tabs running into the card, with wedges.
    Folder,
}

/// `redraw`'s choice between its three looks.
pub fn redraw_mode(has_top_strip: bool, alpha: f64) -> RedrawMode {
    if !has_top_strip {
        RedrawMode::NoTopStrip
    } else if alpha < FOLDER_TAB_MINIMUM_SHADE {
        RedrawMode::Pill
    } else {
        RedrawMode::Folder
    }
}

/// `redraw`'s first look: the sidebar's gooey row is cut only while the shade reads.
pub fn sidebar_hole_without_top_strip(alpha: f64) -> bool {
    alpha >= FOLDER_TAB_MINIMUM_SHADE
}

/// `CornerFlushChrome.dividerLine`: the card's top edge between its rounded corners, as a rect of
/// no height.
pub fn divider_line(card: Rect, radius: f64, square_leading: bool) -> Rect {
    let r = radius.min(card.w() / 2.0).min(card.h() / 2.0);
    let min_x = card.min_x() + if square_leading { 0.0 } else { r };
    let max_x = card.max_x() - r;
    Rect::new(min_x, card.max_y(), (max_x - min_x).max(0.0), 0.0)
}

/// `CornerFlushChrome.dividerSegments`: `line` less `gaps`, left to right, empty segments dropped.
pub fn divider_segments(line: Rect, gaps: &[Span]) -> Vec<Rect> {
    if line.w() <= 0.0 {
        return Vec::new();
    }
    let mut sorted = gaps.to_vec();
    sorted.sort_by(|a, b| a.lower.total_cmp(&b.lower));
    let mut segments = Vec::new();
    let mut start = line.min_x();
    for gap in sorted {
        if !(gap.upper > start && gap.lower < line.max_x()) {
            continue;
        }
        if gap.lower > start {
            segments.push(Rect::new(start, line.min_y(), gap.lower - start, 0.0));
        }
        start = start.max(gap.upper);
    }
    if start < line.max_x() {
        segments.push(Rect::new(start, line.min_y(), line.max_x() - start, 0.0));
    }
    segments
}

/// What one tab strip of the window reports (the `TabStripCorner` protocol and its view's state),
/// with frames already in the root's coordinates. Strips of other windows are left out by the caller.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StripReport {
    /// `cornerFrameInWindow`, converted to the root.
    pub frame: Rect,
    /// The strip view's own `isHidden`.
    #[serde(default)]
    pub hidden: bool,
    /// The strip's `isHiddenOrHasHiddenAncestor`.
    #[serde(default)]
    pub hidden_in_tree: bool,
    /// The pane (the strip's superview) bounds in the root; None when the strip has no superview.
    #[serde(default)]
    pub pane: Option<Rect>,
    /// The pane's `isHiddenOrHasHiddenAncestor`.
    #[serde(default)]
    pub pane_hidden_in_tree: bool,
    /// `meetsToolbar`.
    #[serde(default)]
    pub meets_toolbar: bool,
    /// `selectsLeadingTab`.
    #[serde(default)]
    pub selects_leading_tab: bool,
}

fn on_row(frame: Rect, card: Rect) -> bool {
    (frame.min_y() - card.max_y()).abs() < TOP_ROW_TOLERANCE
}

/// `CornerFlushChrome.toolbarPanes`: the horizontal spans of the panes on the tab row whose toolbar
/// meets their tabs.
pub fn toolbar_panes(card: Rect, strips: &[StripReport]) -> Vec<Span> {
    let mut spans = Vec::new();
    for strip in strips.iter().filter(|s| s.meets_toolbar) {
        let Some(pane) = strip.pane else { continue };
        if strip.hidden_in_tree || !on_row(strip.frame, card) {
            continue;
        }
        spans.push(Span { lower: pane.min_x(), upper: pane.max_x() });
    }
    spans
}

/// `CornerFlushChrome.tabRowEdge`: `card` with its top on the top row's strips' bottom edge.
pub fn tab_row_edge(card: Rect, strips: &[StripReport]) -> Rect {
    let mut bottom: Option<f64> = None;
    for strip in strips {
        if strip.hidden_in_tree {
            continue;
        }
        let min_y = strip.frame.min_y();
        if (min_y - card.max_y()).abs() >= TOP_ROW_TOLERANCE {
            continue;
        }
        bottom = Some(bottom.unwrap_or(min_y).max(min_y));
    }
    let Some(bottom) = bottom else { return card };
    let mut edge = card;
    edge.height = (bottom - card.min_y()).max(0.0);
    edge
}

/// `CornerFlushChrome.hasTopStrip`: some shown pane's strip sits on the card's top, and every shown
/// pane that reaches above it shows its strip right there.
pub fn has_top_strip(card: Rect, strips: &[StripReport]) -> bool {
    let mut on_top = false;
    for strip in strips {
        let Some(pane) = strip.pane else { continue };
        if strip.pane_hidden_in_tree {
            continue;
        }
        if pane.max_y() <= card.max_y() + TOP_ROW_TOLERANCE {
            continue;
        }
        if strip.hidden || !on_row(strip.frame, card) {
            return false;
        }
        on_top = true;
    }
    on_top
}

/// What `markTopRow` tells one strip.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TopRowMark {
    /// `setRunsIntoCard`.
    pub runs_into_card: bool,
    /// `setTonedInCard`.
    pub toned_in_card: bool,
    /// The clip its content areas take (`setChromeClip(card:)`), None when not on the top row.
    pub clip: Option<Rect>,
}

/// `CornerFlushChrome.markTopRow`: per strip, whether it runs its selected tab into the card, tones
/// its own row, and the clip its content takes (the card, widened by `radius` to the left under
/// `square_leading`). `card` None: no tab row.
pub fn mark_top_row(
    card: Option<Rect>,
    radius: f64,
    square_leading: bool,
    tab_shape_runs_into_card: bool,
    strips: &[StripReport],
) -> Vec<TopRowMark> {
    let mut clip = card;
    if let Some(c) = clip.as_mut().filter(|_| square_leading) {
        c.x -= radius;
        c.width += radius;
    }
    strips
        .iter()
        .map(|strip| {
            let on_top = card.is_some_and(|c| !strip.hidden && on_row(strip.frame, c));
            TopRowMark {
                runs_into_card: on_top && tab_shape_runs_into_card,
                toned_in_card: card.is_some() && !on_top && !strip.hidden,
                clip: if on_top { clip } else { None },
            }
        })
        .collect()
}

/// `CornerFlushChrome.leadingTabSelected`: whether the shown strip at the card's top leading corner
/// selects its first tab (the first match, in report order).
pub fn leading_tab_selected(card: Rect, strips: &[StripReport]) -> bool {
    for strip in strips {
        if strip.hidden_in_tree {
            continue;
        }
        let frame = strip.frame;
        if (frame.min_x() - card.min_x()).abs() < LEADING_TOLERANCE && on_row(frame, card) {
            return strip.selects_leading_tab;
        }
    }
    false
}

/// Which side of the card a sidebar row sits on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Side {
    /// Left of the card.
    Left,
    /// Right of the card.
    Right,
}

/// One concave fillet: the square less the circle in `ellipse`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Foot {
    /// The square, `r` on a side.
    pub rect: Rect,
    /// The circle's bounding rect, subtracted from the square.
    pub ellipse: Rect,
}

/// The pieces of `sidebarFolderPath`: the union of the rounded `body`, the `square` half on the
/// card's side and each foot (the path union itself is drawing).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SidebarFolder {
    /// The card's side the row sits on.
    pub side: Side,
    /// The card's edge x the row meets.
    pub edge: f64,
    /// The row out to a point past the card's edge.
    pub body: Rect,
    /// `body`'s corner radius.
    pub corner: f64,
    /// The square half on the card's side.
    pub square: Rect,
    /// The fillets above and below (none when `feet` is 0).
    pub feet: Vec<Foot>,
}

/// `CornerFlushChrome.sidebarFolderPath`'s geometry; None when the row does not sit beside the card
/// or it or its fillets would reach the card's rounded corners.
#[allow(clippy::neg_cmp_op_on_partial_ord)] // Swift's `guard a >= b`: NaN refuses, as there.
pub fn sidebar_folder(
    row: Rect,
    card: Rect,
    card_radius: f64,
    row_radius: f64,
    feet: f64,
) -> Option<SidebarFolder> {
    let r = feet;
    if row.is_empty()
        || card.is_empty()
        || !(row.min_y() - r >= card.min_y() + card_radius)
        || !(row.max_y() + r <= card.max_y() - card_radius)
    {
        return None;
    }
    let side = if row.max_x() <= card.min_x() + 0.5 {
        Side::Left
    } else if row.min_x() >= card.max_x() - 0.5 {
        Side::Right
    } else {
        return None;
    };
    let left = side == Side::Left;
    let edge = if left { card.min_x() } else { card.max_x() };
    let body = if left {
        Rect::new(row.min_x(), row.min_y(), edge + 1.0 - row.min_x(), row.h())
    } else {
        Rect::new(edge - 1.0, row.min_y(), row.max_x() - edge + 1.0, row.h())
    };
    let corner = row_radius.min(body.h() / 2.0).min(body.w() / 2.0);
    let square = if left {
        Rect::new(body.mid_x(), body.min_y(), body.w() / 2.0, body.h())
    } else {
        Rect::new(body.min_x(), body.min_y(), body.w() / 2.0, body.h())
    };
    let mut out = SidebarFolder { side, edge, body, corner, square, feet: Vec::new() };
    if r > 0.0 {
        let x = if left { edge - r } else { edge };
        let center = if left { edge - r } else { edge + r };
        for (y, center_y) in [(row.max_y(), row.max_y() + r), (row.min_y() - r, row.min_y() - r)] {
            out.feet.push(Foot {
                rect: Rect::new(x, y, r, r),
                ellipse: Rect::new(center - r, center_y - r, 2.0 * r, 2.0 * r),
            });
        }
    }
    Some(out)
}

/// `CornerFlushChrome.wedgePath`'s pieces: the top corner squares (without the leading one under
/// `square_leading`) and the radius of the card's rounded rect they are cut by.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Wedges {
    /// The corner radius `r`.
    pub radius: f64,
    /// The corner squares, leading first.
    pub corners: Vec<Rect>,
}

/// `CornerFlushChrome.wedgePath`'s rects and radius.
pub fn wedges(card: Rect, radius: f64, square_leading: bool) -> Wedges {
    let r = radius.min(card.w() / 2.0).min(card.h() / 2.0);
    let mut corners = Vec::new();
    for (x, leading) in [(card.min_x(), true), (card.max_x() - r, false)] {
        if leading && square_leading {
            continue;
        }
        corners.push(Rect::new(x, card.max_y() - r, r, r));
    }
    Wedges { radius: r, corners }
}

/// Whether `point` is in the wedge path: in a corner square and outside the card's rounded corner
/// (the circle of radius `r` inside that corner).
pub fn wedge_contains(card: Rect, radius: f64, square_leading: bool, point: Point) -> bool {
    let r = radius.min(card.w() / 2.0).min(card.h() / 2.0);
    let cy = card.max_y() - r;
    let corners =
        [(card.min_x(), card.min_x() + r, true), (card.max_x() - r, card.max_x() - r, false)];
    corners.into_iter().any(|(x, cx, leading)| {
        if leading && square_leading {
            return false;
        }
        let inside = point.x >= x && point.x <= x + r && point.y >= cy && point.y <= cy + r;
        inside && (point.x - cx).hypot(point.y - cy) > r
    })
}

// MARK: - ConcentricContainer

/// A container whose corner is concentric with its child's (Swift `ConcentricContainer`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConcentricContainer {
    /// The inset from the container's edge to the child's.
    pub padding: f64,
    /// The child's corner radius.
    pub child_radius: f64,
}

impl ConcentricContainer {
    /// `init(childRadius:padding:)`: both clamped to 0 or more.
    pub fn new(child_radius: f64, padding: f64) -> ConcentricContainer {
        ConcentricContainer { child_radius: child_radius.max(0.0), padding: padding.max(0.0) }
    }

    /// `init(outerRadius:padding:)`: the child's radius is the outer less the padding.
    pub fn with_outer(outer_radius: f64, padding: f64) -> ConcentricContainer {
        Self::new(outer_radius.max(0.0) - padding.max(0.0), padding)
    }

    /// `cornerControl(outerRadius:side:minimumPadding:)`: a square control in a window corner.
    pub fn corner_control(
        outer_radius: f64,
        side: f64,
        minimum_padding: f64,
    ) -> ConcentricContainer {
        Self::with_outer(outer_radius, minimum_padding.max(outer_radius - side / 2.0))
    }

    /// `capsule(controlHeight:padding:)`: a capsule control's radius is half its height.
    pub fn capsule(control_height: f64, padding: f64) -> ConcentricContainer {
        Self::new(control_height.max(0.0) / 2.0, padding)
    }

    /// `topTrailingFrame(side:in:flipped:)`.
    pub fn top_trailing_frame(&self, side: f64, bounds: Rect, flipped: bool) -> Rect {
        Rect::new(
            bounds.max_x() - self.padding - side,
            if flipped {
                bounds.min_y() + self.padding
            } else {
                bounds.max_y() - self.padding - side
            },
            side,
            side,
        )
    }

    /// `outerRadius`: child radius plus padding.
    pub fn outer_radius(&self) -> f64 {
        self.child_radius + self.padding
    }

    /// `textInset`: `max(padding, outerRadius)`.
    pub fn text_inset(&self) -> f64 {
        self.padding.max(self.outer_radius())
    }

    /// `childRadius(fitting:)`.
    pub fn child_radius_fitting(&self, size: Size) -> f64 {
        self.child_radius.min(size.width.min(size.height) / 2.0).max(0.0)
    }

    /// `outerRadius(fitting:)`.
    pub fn outer_radius_fitting(&self, size: Size) -> f64 {
        self.outer_radius().min(size.width.min(size.height) / 2.0).max(0.0)
    }
}

/// `ConcentricContainer`'s default `violations` tolerance.
pub const VIOLATION_TOLERANCE: f64 = 0.5;

/// `ConcentricContainer.violations`: what breaks the concentric rule for `child` in `bounds`.
pub fn violations(
    child: Rect,
    child_radius: f64,
    bounds: Rect,
    outer_radius: f64,
    padding: f64,
    tolerance: f64,
) -> Vec<String> {
    let insets = [
        ("top", child.min_y() - bounds.min_y()),
        ("bottom", bounds.max_y() - child.max_y()),
        ("leading", child.min_x() - bounds.min_x()),
        ("trailing", bounds.max_x() - child.max_x()),
    ];
    let near: Vec<(&str, f64)> = insets
        .into_iter()
        .filter(|(_, inset)| *inset <= padding + outer_radius + tolerance)
        .collect();
    let mut out = Vec::new();
    for (edge, inset) in &near {
        if (inset - padding).abs() > tolerance {
            out.push(format!(
                "{edge} inset {} is not the padding {}",
                format(*inset),
                format(padding)
            ));
        }
    }
    let has = |name: &str| near.iter().any(|(edge, _)| *edge == name);
    let in_corner = (has("top") || has("bottom")) && (has("leading") || has("trailing"));
    if in_corner {
        let expected = (outer_radius - padding).min(child.w().min(child.h()) / 2.0).max(0.0);
        if (child_radius - expected).abs() > tolerance {
            out.push(format!(
                "child radius {} is not {} - {} = {}",
                format(child_radius),
                format(outer_radius),
                format(padding),
                format(expected)
            ));
        }
    }
    out
}

/// `ConcentricContainer`'s private `format`: two decimals, an integer without a point. Swift traps
/// on NaN, infinities and integers past `Int`; this prints `NaN`, `inf` and saturates instead.
pub fn format(value: f64) -> String {
    let rounded = (value * 100.0).round() / 100.0;
    if rounded == rounded.round() { (rounded as i64).to_string() } else { rounded.to_string() }
}

// MARK: - ConcentricCorners

/// Nested corner radii, each a padding inside the last (Swift `ConcentricCorners`).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConcentricCorners {
    /// The outermost radius.
    pub outer: f64,
    /// The inset between levels.
    pub padding: f64,
}

impl ConcentricCorners {
    /// `init(outer:padding:)`: both clamped to 0 or more.
    pub fn new(outer: f64, padding: f64) -> ConcentricCorners {
        ConcentricCorners { outer: outer.max(0.0), padding: padding.max(0.0) }
    }

    /// `inner`: one level in.
    pub fn inner(&self) -> f64 {
        self.radius(1)
    }

    /// `radius(depth:)`: `max(0, outer - depth * padding)`.
    pub fn radius(&self, depth: i64) -> f64 {
        (self.outer - depth as f64 * self.padding).max(0.0)
    }

    /// `nested(in:inset:)`: `max(0, radius - inset)`.
    pub fn nested(&self, radius: f64, inset: f64) -> f64 {
        (radius - inset).max(0.0)
    }

    /// `radius(fitting:radius:)`: `radius` capped at half the shorter side.
    pub fn radius_fitting(&self, size: Size, radius: f64) -> f64 {
        radius.min(size.width.min(size.height) / 2.0).max(0.0)
    }
}

// MARK: - Ops

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ValueScale {
    value: CornerFlush,
    #[serde(default = "one")]
    scale: f64,
    #[serde(default)]
    standard_window_corner_radius: f64,
}

fn one() -> f64 {
    1.0
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct MetricsReply {
    is_on: bool,
    feet_radius: f64,
    gap: f64,
    card_radius: f64,
    sidebar_gap: Option<f64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ValueInfo {
    value: CornerFlush,
    title: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CurrentReply {
    current: CornerFlush,
    chosen: Option<CornerFlush>,
    is_chosen: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowFlowsRequest {
    current: CornerFlush,
    tab_shape_runs_into_card: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShadeRequest {
    is_dark: bool,
    #[serde(default = "shade_dark")]
    shade_dark: f64,
    #[serde(default = "shade_light")]
    shade_light: f64,
}

fn shade_dark() -> f64 {
    MAIN_PANE_SHADE_DARK
}
fn shade_light() -> f64 {
    MAIN_PANE_SHADE_LIGHT
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TopInsetRequest {
    is_on: bool,
    #[serde(default)]
    tabs_at_bottom: bool,
    center_from_top: Option<f64>,
    backing_scale: f64,
    pane_padding: f64,
    pill_top: f64,
    tab_height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShowsRequest {
    is_on: bool,
    #[serde(default)]
    page: bool,
    #[serde(default)]
    tabs_at_bottom: bool,
    shade_base: f64,
    radius: f64,
    in_root: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ShowsReply {
    on: bool,
    shows: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RedrawRequest {
    content: Rect,
    strip_height: f64,
    alpha: f64,
    #[serde(default)]
    strips: Vec<StripReport>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RedrawReply {
    card: Rect,
    mode: RedrawMode,
    sidebar_hole: bool,
    square_leading: bool,
    edge: Rect,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LineRequest {
    card: Rect,
    radius: f64,
    #[serde(default)]
    square_leading: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SegmentsRequest {
    line: Rect,
    #[serde(default)]
    gaps: Vec<Span>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StripsRequest {
    card: Rect,
    #[serde(default)]
    strips: Vec<StripReport>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MarkRequest {
    card: Option<Rect>,
    #[serde(default)]
    radius: f64,
    #[serde(default)]
    square_leading: bool,
    tab_shape_runs_into_card: bool,
    #[serde(default)]
    strips: Vec<StripReport>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FolderRequest {
    row: Rect,
    card: Rect,
    card_radius: f64,
    row_radius: f64,
    feet: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WedgeContainsRequest {
    card: Rect,
    radius: f64,
    #[serde(default)]
    square_leading: bool,
    point: Point,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ContainerRequest {
    child_radius: Option<f64>,
    outer_radius: Option<f64>,
    control_height: Option<f64>,
    side: Option<f64>,
    minimum_padding: Option<f64>,
    #[serde(default)]
    padding: f64,
    fitting: Option<Size>,
    frame_side: Option<f64>,
    bounds: Option<Rect>,
    #[serde(default)]
    flipped: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ContainerReply {
    padding: f64,
    child_radius: f64,
    outer_radius: f64,
    text_inset: f64,
    child_radius_fitting: Option<f64>,
    outer_radius_fitting: Option<f64>,
    top_trailing_frame: Option<Rect>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ViolationsRequest {
    child: Rect,
    child_radius: f64,
    bounds: Rect,
    outer_radius: f64,
    padding: f64,
    #[serde(default = "tolerance")]
    tolerance: f64,
}

fn tolerance() -> f64 {
    VIOLATION_TOLERANCE
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FormatRequest {
    value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CornersRequest {
    outer: f64,
    padding: f64,
    #[serde(default)]
    depths: Vec<i64>,
    nested: Option<NestedRequest>,
    fitting: Option<Size>,
    #[serde(default)]
    radius: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NestedRequest {
    radius: f64,
    inset: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CornersReply {
    outer: f64,
    padding: f64,
    inner: f64,
    radii: Vec<f64>,
    nested: Option<f64>,
    radius_fitting: Option<f64>,
}

fn container_from(r: &ContainerRequest) -> Result<ConcentricContainer, OpError> {
    if let Some(h) = r.control_height {
        Ok(ConcentricContainer::capsule(h, r.padding))
    } else if let (Some(outer), Some(side)) = (r.outer_radius, r.side) {
        Ok(ConcentricContainer::corner_control(outer, side, r.minimum_padding.unwrap_or(0.0)))
    } else if let Some(outer) = r.outer_radius {
        Ok(ConcentricContainer::with_outer(outer, r.padding))
    } else if let Some(child) = r.child_radius {
        Ok(ConcentricContainer::new(child, r.padding))
    } else {
        Err(OpError::Invalid(
            "give childRadius, outerRadius, outerRadius with side, or controlHeight".into(),
        ))
    }
}

/// Runs the `tokens.corner_flush_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "corner_flush_values" => reply(
            &CornerFlush::ALL
                .iter()
                .map(|&value| ValueInfo { value, title: value.tunable_title() })
                .collect::<Vec<_>>(),
        ),
        "corner_flush_metrics" => {
            let r: ValueScale = parse(request)?;
            reply(&MetricsReply {
                is_on: r.value.is_on(),
                feet_radius: r.value.feet_radius(r.scale),
                gap: r.value.gap(r.scale),
                card_radius: r.value.card_radius(r.standard_window_corner_radius, r.scale),
                sidebar_gap: r.value.sidebar_gap(r.scale),
            })
        }
        "corner_flush_current" => {
            let r: CurrentInputs = parse(request)?;
            reply(&CurrentReply {
                current: current(&r),
                chosen: chosen(&r),
                is_chosen: is_chosen(&r),
            })
        }
        "corner_flush_default_fits" => {
            let r: DefaultFitsInputs = parse(request)?;
            reply(&default_fits(&r))
        }
        "corner_flush_sidebar_row_flows" => {
            let r: RowFlowsRequest = parse(request)?;
            reply(&sidebar_row_flows(r.current, r.tab_shape_runs_into_card))
        }
        "corner_flush_shade" => {
            let r: ShadeRequest = parse(request)?;
            reply(&shade(r.is_dark, r.shade_dark, r.shade_light))
        }
        "corner_flush_top_inset" => {
            let r: TopInsetRequest = parse(request)?;
            reply(&top_inset(
                r.is_on,
                r.tabs_at_bottom,
                r.center_from_top,
                r.backing_scale,
                r.pane_padding,
                r.pill_top,
                r.tab_height,
            ))
        }
        "corner_flush_chrome_shows" => {
            let r: ShowsRequest = parse(request)?;
            let on = content_on(r.is_on, r.page, r.tabs_at_bottom);
            reply(&ShowsReply { on, shows: chrome_shows(on, r.shade_base, r.radius, r.in_root) })
        }
        "corner_flush_redraw" => {
            let r: RedrawRequest = parse(request)?;
            let card = card_below_strip(r.content, r.strip_height);
            let mode = redraw_mode(has_top_strip(card, &r.strips), r.alpha);
            reply(&RedrawReply {
                card,
                mode,
                sidebar_hole: match mode {
                    RedrawMode::NoTopStrip => sidebar_hole_without_top_strip(r.alpha),
                    RedrawMode::Pill => false,
                    RedrawMode::Folder => true,
                },
                square_leading: mode == RedrawMode::Folder && leading_tab_selected(card, &r.strips),
                edge: tab_row_edge(card, &r.strips),
            })
        }
        "corner_flush_divider_line" => {
            let r: LineRequest = parse(request)?;
            reply(&divider_line(r.card, r.radius, r.square_leading))
        }
        "corner_flush_divider_segments" => {
            let r: SegmentsRequest = parse(request)?;
            reply(&divider_segments(r.line, &r.gaps))
        }
        "corner_flush_toolbar_panes" => {
            let r: StripsRequest = parse(request)?;
            reply(&toolbar_panes(r.card, &r.strips))
        }
        "corner_flush_tab_row_edge" => {
            let r: StripsRequest = parse(request)?;
            reply(&tab_row_edge(r.card, &r.strips))
        }
        "corner_flush_has_top_strip" => {
            let r: StripsRequest = parse(request)?;
            reply(&has_top_strip(r.card, &r.strips))
        }
        "corner_flush_leading_tab_selected" => {
            let r: StripsRequest = parse(request)?;
            reply(&leading_tab_selected(r.card, &r.strips))
        }
        "corner_flush_mark_top_row" => {
            let r: MarkRequest = parse(request)?;
            reply(&mark_top_row(
                r.card,
                r.radius,
                r.square_leading,
                r.tab_shape_runs_into_card,
                &r.strips,
            ))
        }
        "corner_flush_sidebar_folder" => {
            let r: FolderRequest = parse(request)?;
            reply(&sidebar_folder(r.row, r.card, r.card_radius, r.row_radius, r.feet))
        }
        "corner_flush_wedges" => {
            let r: LineRequest = parse(request)?;
            reply(&wedges(r.card, r.radius, r.square_leading))
        }
        "corner_flush_wedge_contains" => {
            let r: WedgeContainsRequest = parse(request)?;
            reply(&wedge_contains(r.card, r.radius, r.square_leading, r.point))
        }
        "corner_flush_concentric_container" => {
            let r: ContainerRequest = parse(request)?;
            let c = container_from(&r)?;
            reply(&ContainerReply {
                padding: c.padding,
                child_radius: c.child_radius,
                outer_radius: c.outer_radius(),
                text_inset: c.text_inset(),
                child_radius_fitting: r.fitting.map(|s| c.child_radius_fitting(s)),
                outer_radius_fitting: r.fitting.map(|s| c.outer_radius_fitting(s)),
                top_trailing_frame: match (r.frame_side, r.bounds) {
                    (Some(side), Some(bounds)) => {
                        Some(c.top_trailing_frame(side, bounds, r.flipped))
                    }
                    _ => None,
                },
            })
        }
        "corner_flush_violations" => {
            let r: ViolationsRequest = parse(request)?;
            reply(&violations(
                r.child,
                r.child_radius,
                r.bounds,
                r.outer_radius,
                r.padding,
                r.tolerance,
            ))
        }
        "corner_flush_format" => {
            let r: FormatRequest = parse(request)?;
            reply(&format(r.value))
        }
        "corner_flush_concentric_corners" => {
            let r: CornersRequest = parse(request)?;
            let c = ConcentricCorners::new(r.outer, r.padding);
            reply(&CornersReply {
                outer: c.outer,
                padding: c.padding,
                inner: c.inner(),
                radii: r.depths.iter().map(|&d| c.radius(d)).collect(),
                nested: r.nested.map(|n| c.nested(n.radius, n.inset)),
                radius_fitting: r.fitting.map(|s| c.radius_fitting(s, r.radius)),
            })
        }
        _ => Err(OpError::Unknown),
    }
}
