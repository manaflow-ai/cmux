//! Chrome metrics that follow the density: a port of CmuxNextDesign's Metrics+AddGlyph.swift
//! (with the `CGPath.addGlyph` geometry as segments), Metrics+ButtonContainer.swift,
//! Metrics+ButtonCorner.swift, Metrics+ChromeRowCorner.swift, Metrics+RowMatch.swift,
//! Metrics+TabBarControl.swift and the `chromeShapeKey` extension in CornerFlush.swift, plus the
//! parts of `ConcentricContainer` / `ConcentricCorners` (CmuxNextDesignTokens) and Metrics.swift
//! (`space1...space6`) they read.
//!
//! Live app values (`Metrics.tabCornerRadius`, `Metrics.smallIconSize`, `Metrics.tabHeight`,
//! tunable overrides, settings) are inputs.
//!
//! Ops: `tokens.metrics_*`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::density::tokens::{DensityPreset, DensityTokens, smax, smin};
use serde::{Deserialize, Serialize};
use serde_json::Value;

// MARK: - Grid

/// `ChromeTunables.space1...space6` defaults.
pub const SPACE_BASES: [f64; 6] = [2.0, 4.0, 6.0, 8.0, 12.0, 16.0];

/// `MetricTunables.sidebarRowHeight`'s compact value.
pub const SIDEBAR_ROW_COMPACT: f64 = 24.0;
/// `MetricTunables.sidebarRowHeight`'s comfortable value.
pub const SIDEBAR_ROW_COMFORTABLE: f64 = 32.0;
/// `MetricTunables.sidebarRowHeight`'s token.
pub const SIDEBAR_ROW_TOKEN: &str = "sidebarRowHeight";
/// `Metrics.folderTabMinimumShade` (MainPane.swift).
pub const FOLDER_TAB_MINIMUM_SHADE: f64 = 0.011;

/// `Metrics.scale(_:)`: `value` times the interface scale (1 while Interface Size is off).
pub fn scale(value: f64, interface_scale: f64) -> f64 {
    value * interface_scale
}

/// `Metrics.spaceN`: `scale(tokens.space(base))` for the grid step's (tunable) base.
pub fn space(tokens: &DensityTokens, interface_scale: f64, base: f64) -> f64 {
    scale(tokens.space(base), interface_scale)
}

// MARK: - Concentric corners

/// `ConcentricContainer`: a container's padding and its child's corner radius.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConcentricContainer {
    /// The padding around the child.
    pub padding: f64,
    /// The child's corner radius.
    pub child_radius: f64,
}

impl ConcentricContainer {
    /// `init(childRadius:padding:)`: both at least 0.
    pub fn new(child_radius: f64, padding: f64) -> Self {
        ConcentricContainer { child_radius: smax(0.0, child_radius), padding: smax(0.0, padding) }
    }

    /// `init(outerRadius:padding:)`.
    pub fn with_outer(outer_radius: f64, padding: f64) -> Self {
        Self::new(smax(0.0, outer_radius) - smax(0.0, padding), padding)
    }

    /// `cornerControl(outerRadius:side:minimumPadding:)`.
    pub fn corner_control(outer_radius: f64, side: f64, minimum_padding: f64) -> Self {
        Self::with_outer(outer_radius, smax(minimum_padding, outer_radius - side / 2.0))
    }

    /// `outerRadius`.
    pub fn outer_radius(&self) -> f64 {
        self.child_radius + self.padding
    }

    /// `textInset`.
    pub fn text_inset(&self) -> f64 {
        smax(self.padding, self.outer_radius())
    }

    /// `childRadius(fitting:)`.
    pub fn child_radius_fitting(&self, width: f64, height: f64) -> f64 {
        smax(0.0, smin(self.child_radius, smin(width, height) / 2.0))
    }

    /// `outerRadius(fitting:)`.
    pub fn outer_radius_fitting(&self, width: f64, height: f64) -> f64 {
        smax(0.0, smin(self.outer_radius(), smin(width, height) / 2.0))
    }
}

/// `ConcentricCorners.radius(fitting:radius:)`.
pub fn radius_fitting(width: f64, height: f64, radius: f64) -> f64 {
    smax(0.0, smin(radius, smin(width, height) / 2.0))
}

/// `ConcentricCorners.nested(in:inset:)`.
pub fn nested(radius: f64, inset: f64) -> f64 {
    smax(0.0, radius - inset)
}

// MARK: - Add glyph (Metrics+AddGlyph.swift)

/// `addGlyphExtent`: three quarters of the small icon, on the half-point grid.
pub fn add_glyph_extent(small_icon_size: f64) -> f64 {
    (small_icon_size * 0.75 * 2.0).round() / 2.0
}

/// `addGlyphLineWidth`.
pub fn add_glyph_line_width(space1: f64) -> f64 {
    space1 * 0.6
}

/// `addMenuChevronPointSize`.
pub fn add_menu_chevron_point_size(small_icon_size: f64, space1: f64) -> f64 {
    (add_glyph_extent(small_icon_size) + space1 / 2.0).round()
}

/// A point.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point {
    /// x.
    pub x: f64,
    /// y.
    pub y: f64,
}

/// `CGPath.addGlyph(center:scale:)`: the + as its horizontal then vertical segment, the center
/// snapped to the backing pixel grid.
pub fn add_glyph_path(center: Point, scale: f64, small_icon_size: f64) -> [[Point; 2]; 2] {
    let arm = add_glyph_extent(small_icon_size) / 2.0;
    let scale = smax(scale, 1.0);
    let c = Point { x: (center.x * scale).round() / scale, y: (center.y * scale).round() / scale };
    [
        [Point { x: c.x - arm, y: c.y }, Point { x: c.x + arm, y: c.y }],
        [Point { x: c.x, y: c.y - arm }, Point { x: c.x, y: c.y + arm }],
    ]
}

// MARK: - Buttons (Metrics+ButtonContainer.swift, Metrics+ButtonCorner.swift)

/// `buttonContainer(padding:)`: the button corner (`buttonCornerRadius` = `tabCornerRadius`)
/// inside `padding`.
pub fn button_container(button_corner_radius: f64, padding: f64) -> ConcentricContainer {
    ConcentricContainer::new(button_corner_radius, padding)
}

/// `cornerControl(outerRadius:side:)`: at least `space1` of padding.
pub fn corner_control(outer_radius: f64, side: f64, space1: f64) -> ConcentricContainer {
    ConcentricContainer::corner_control(outer_radius, side, space1)
}

/// `buttonCornerRadius(fitting:)`.
pub fn button_corner_radius_fitting(button_corner_radius: f64, width: f64, height: f64) -> f64 {
    radius_fitting(width, height, button_corner_radius)
}

/// `buttonCornerRadius(proportionalTo:)`: the set corner, else Helium's 8 on 28, capped at half.
pub fn button_corner_radius_proportional(
    button_corner_radius: f64,
    side: f64,
    corner_radius_is_set: bool,
) -> f64 {
    if corner_radius_is_set {
        return smin(button_corner_radius, side / 2.0);
    }
    smin(((side * 8.0 / 28.0) * 2.0).round() / 2.0, side / 2.0)
}

/// `buttonCornerRadius(nestedIn:inset:)`.
pub fn button_corner_radius_nested(
    button_corner_radius: f64,
    outer: Option<f64>,
    inset: f64,
) -> f64 {
    nested(outer.unwrap_or(button_corner_radius), inset)
}

// MARK: - Chrome row corner (Metrics+ChromeRowCorner.swift)

/// `chromeRowCornerRadius(height:)`: Helium's 8 on 28, whole points.
pub fn chrome_row_corner_radius(height: f64) -> f64 {
    (height * 8.0 / 28.0).round()
}

/// `cornerRadiusIsSet`: Settings' pane corner or the density's pane corner is set.
pub fn corner_radius_is_set(
    pane_chrome_corner_radius: Option<f64>,
    density_pane_corner_radius: Option<f64>,
) -> bool {
    pane_chrome_corner_radius.is_some() || density_pane_corner_radius.is_some()
}

/// `usesChromeRowCorner`.
pub fn uses_chrome_row_corner(corner_radius_is_set: bool, floating_panes: bool) -> bool {
    !corner_radius_is_set && !floating_panes
}

// MARK: - Row match (Metrics+RowMatch.swift)

/// `densityRowHeight`: the sidebar row (`row_override` is the tunable's override) scaled, plus
/// `space1` for the default row fill.
pub fn density_row_height(
    tokens: &DensityTokens,
    interface_scale: f64,
    row_override: Option<f64>,
    space1_base: f64,
) -> f64 {
    let computed =
        tokens.resolve(SIDEBAR_ROW_COMPACT, SIDEBAR_ROW_COMFORTABLE, Some(SIDEBAR_ROW_TOKEN));
    let height = scale(row_override.unwrap_or(computed), interface_scale);
    height
        + if tokens.uses_default_row_fill() {
            space(tokens, interface_scale, space1_base)
        } else {
            0.0
        }
}

/// `defaultDensityRowHeight`: Default's row plus its `space1`, unscaled.
pub fn default_density_row_height(space1_base: f64) -> f64 {
    let cozy = DensityPreset::Cozy.tokens();
    cozy.resolve(SIDEBAR_ROW_COMPACT, SIDEBAR_ROW_COMFORTABLE, Some(SIDEBAR_ROW_TOKEN))
        + cozy.space(space1_base)
}

/// `tabsFollowRows`: neither tab height nor strip height set, and full-size tabs.
pub fn tabs_follow_rows(
    tab_height_set: bool,
    tab_strip_height_set: bool,
    compact_tabs: bool,
) -> bool {
    !tab_height_set && !tab_strip_height_set && !compact_tabs
}

/// `tabRowGrowth`: how much taller the tabs grow to match the rows.
pub fn tab_row_growth(
    tabs_follow_rows: bool,
    density_row_height: f64,
    tab_height_value: f64,
) -> f64 {
    if tabs_follow_rows { density_row_height - tab_height_value } else { 0.0 }
}

// MARK: - Tab bar control (Metrics+TabBarControl.swift)

/// `tabBarControlSide`: the tab height.
pub fn tab_bar_control_side(tab_height: f64) -> f64 {
    tab_height
}

/// `tabBarControlCornerRadius(fitting:)`: the tab corner, fitting `size` (default the side
/// squared).
pub fn tab_bar_control_corner_radius(
    tab_height: f64,
    tab_corner_radius: f64,
    size: Option<(f64, f64)>,
) -> f64 {
    let side = tab_bar_control_side(tab_height);
    let (w, h) = size.unwrap_or((side, side));
    radius_fitting(w, h, tab_corner_radius)
}

// MARK: - Chrome shape key (CornerFlush.swift)

/// `CornerFlush.allCases` raw values, in order.
pub const CORNER_FLUSH_CASES: [&str; 4] = ["off", "flush", "flush-tight", "flush-goo"];
/// `TabShape.allCases` raw values, in order.
pub const TAB_SHAPE_CASES: [&str; 2] = ["block", "rounded"];

/// `chromeShapeKey`: floating panes (1), twice the corner's index, the tab shape's index over 4
/// and 16 times the main pane's corner radius. Unknown raw values count as index 0.
pub fn chrome_shape_key(
    floating_panes: bool,
    corner_flush: &str,
    tab_shape: &str,
    main_pane_corner_radius: f64,
) -> f64 {
    let flush = CORNER_FLUSH_CASES.iter().position(|c| *c == corner_flush).unwrap_or(0);
    let shape = (usize::from(floating_panes) + 2 * flush) as f64;
    let tab = TAB_SHAPE_CASES.iter().position(|c| *c == tab_shape).unwrap_or(0) as f64 / 4.0;
    shape + tab + 16.0 * main_pane_corner_radius
}

// MARK: - Ops

fn one() -> f64 {
    1.0
}

fn space1_base() -> f64 {
    SPACE_BASES[0]
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddGlyphRequest {
    small_icon_size: f64,
    space1: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AddGlyphReply {
    extent: f64,
    line_width: f64,
    chevron_point_size: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AddGlyphPathRequest {
    center: Point,
    #[serde(default = "one")]
    scale: f64,
    small_icon_size: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ButtonContainerRequest {
    button_corner_radius: f64,
    padding: f64,
    #[serde(default)]
    fitting: Option<Size>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CornerControlRequest {
    outer_radius: f64,
    side: f64,
    space1: f64,
    #[serde(default)]
    fitting: Option<Size>,
}

/// A size.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Size {
    /// The width.
    pub width: f64,
    /// The height.
    pub height: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ContainerReply {
    padding: f64,
    child_radius: f64,
    outer_radius: f64,
    text_inset: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    child_radius_fitting: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    outer_radius_fitting: Option<f64>,
}

fn container_reply(c: ConcentricContainer, fitting: Option<Size>) -> OpResult {
    reply(&ContainerReply {
        padding: c.padding,
        child_radius: c.child_radius,
        outer_radius: c.outer_radius(),
        text_inset: c.text_inset(),
        child_radius_fitting: fitting.map(|s| c.child_radius_fitting(s.width, s.height)),
        outer_radius_fitting: fitting.map(|s| c.outer_radius_fitting(s.width, s.height)),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ButtonCornerRequest {
    button_corner_radius: f64,
    #[serde(default)]
    fitting: Option<Size>,
    #[serde(default)]
    proportional_to: Option<f64>,
    #[serde(default)]
    corner_radius_is_set: bool,
    #[serde(default)]
    nested_in: Option<f64>,
    #[serde(default)]
    inset: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct HeightRequest {
    height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CornerSetRequest {
    #[serde(default)]
    pane_chrome_corner_radius: Option<f64>,
    #[serde(default)]
    density_pane_corner_radius: Option<f64>,
    #[serde(default)]
    floating_panes: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CornerSetReply {
    corner_radius_is_set: bool,
    uses_chrome_row_corner: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RowHeightRequest {
    density: DensityTokens,
    #[serde(default = "one")]
    interface_scale: f64,
    #[serde(default)]
    row_override: Option<f64>,
    #[serde(default = "space1_base")]
    space1_base: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DefaultRowHeightRequest {
    #[serde(default = "space1_base")]
    space1_base: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabsFollowRowsRequest {
    #[serde(default)]
    tab_height_set: bool,
    #[serde(default)]
    tab_strip_height_set: bool,
    #[serde(default)]
    compact_tabs: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabRowGrowthRequest {
    tabs_follow_rows: bool,
    density_row_height: f64,
    tab_height_value: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabBarControlRequest {
    tab_height: f64,
    tab_corner_radius: f64,
    #[serde(default)]
    fitting: Option<Size>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TabBarControlReply {
    side: f64,
    corner_radius: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShapeKeyRequest {
    #[serde(default)]
    floating_panes: bool,
    corner_flush: String,
    tab_shape: String,
    main_pane_corner_radius: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpacesRequest {
    density: DensityTokens,
    #[serde(default = "one")]
    interface_scale: f64,
    #[serde(default)]
    bases: Option<[f64; 6]>,
}

/// Runs the `tokens.metrics_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "metrics_add_glyph" => {
            let r: AddGlyphRequest = parse(request)?;
            reply(&AddGlyphReply {
                extent: add_glyph_extent(r.small_icon_size),
                line_width: add_glyph_line_width(r.space1),
                chevron_point_size: add_menu_chevron_point_size(r.small_icon_size, r.space1),
            })
        }
        "metrics_add_glyph_path" => {
            let r: AddGlyphPathRequest = parse(request)?;
            reply(&add_glyph_path(r.center, r.scale, r.small_icon_size))
        }
        "metrics_button_container" => {
            let r: ButtonContainerRequest = parse(request)?;
            container_reply(button_container(r.button_corner_radius, r.padding), r.fitting)
        }
        "metrics_corner_control" => {
            let r: CornerControlRequest = parse(request)?;
            container_reply(corner_control(r.outer_radius, r.side, r.space1), r.fitting)
        }
        "metrics_button_corner_radius" => {
            let r: ButtonCornerRequest = parse(request)?;
            let radius = if let Some(s) = r.fitting {
                button_corner_radius_fitting(r.button_corner_radius, s.width, s.height)
            } else if let Some(side) = r.proportional_to {
                button_corner_radius_proportional(
                    r.button_corner_radius,
                    side,
                    r.corner_radius_is_set,
                )
            } else if let Some(inset) = r.inset {
                button_corner_radius_nested(r.button_corner_radius, r.nested_in, inset)
            } else {
                return Err(OpError::Invalid(
                    "one of fitting, proportionalTo or inset is required".into(),
                ));
            };
            reply(&radius)
        }
        "metrics_chrome_row_corner_radius" => {
            let r: HeightRequest = parse(request)?;
            reply(&chrome_row_corner_radius(r.height))
        }
        "metrics_corner_radius_is_set" => {
            let r: CornerSetRequest = parse(request)?;
            let set =
                corner_radius_is_set(r.pane_chrome_corner_radius, r.density_pane_corner_radius);
            reply(&CornerSetReply {
                corner_radius_is_set: set,
                uses_chrome_row_corner: uses_chrome_row_corner(set, r.floating_panes),
            })
        }
        "metrics_density_row_height" => {
            let r: RowHeightRequest = parse(request)?;
            reply(&density_row_height(&r.density, r.interface_scale, r.row_override, r.space1_base))
        }
        "metrics_default_density_row_height" => {
            let r: DefaultRowHeightRequest = parse(request)?;
            reply(&default_density_row_height(r.space1_base))
        }
        "metrics_tabs_follow_rows" => {
            let r: TabsFollowRowsRequest = parse(request)?;
            reply(&tabs_follow_rows(r.tab_height_set, r.tab_strip_height_set, r.compact_tabs))
        }
        "metrics_tab_row_growth" => {
            let r: TabRowGrowthRequest = parse(request)?;
            reply(&tab_row_growth(r.tabs_follow_rows, r.density_row_height, r.tab_height_value))
        }
        "metrics_tab_bar_control" => {
            let r: TabBarControlRequest = parse(request)?;
            reply(&TabBarControlReply {
                side: tab_bar_control_side(r.tab_height),
                corner_radius: tab_bar_control_corner_radius(
                    r.tab_height,
                    r.tab_corner_radius,
                    r.fitting.map(|s| (s.width, s.height)),
                ),
            })
        }
        "metrics_chrome_shape_key" => {
            let r: ShapeKeyRequest = parse(request)?;
            reply(&chrome_shape_key(
                r.floating_panes,
                &r.corner_flush,
                &r.tab_shape,
                r.main_pane_corner_radius,
            ))
        }
        "metrics_spaces" => {
            let r: SpacesRequest = parse(request)?;
            let bases = r.bases.unwrap_or(SPACE_BASES);
            reply(&bases.map(|b| space(&r.density, r.interface_scale, b)))
        }
        _ => Err(OpError::Unknown),
    }
}
