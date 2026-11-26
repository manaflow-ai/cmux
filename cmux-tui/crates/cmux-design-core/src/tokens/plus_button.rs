//! The window's one + button, as values: ports the pure rules of `PlusButtonLook.swift`
//! (CmuxNextDesign): its `State`, `Segment`, `geometry(in:...)`, `splitCornerRadius`,
//! `fill(_:hoverStyle:segment:)`, `glyphInk(hovering:pressed:)`, `ink(_:)`, the + and ⌄ path
//! `layout(in:scale:)` builds (with `CGPath.addGlyph(center:scale:)`), `drawGlyph`'s scale pick,
//! `allCorners`, `chevronHalfWidth` and `chevronRise`.
//!
//! The density-scaled `Metrics` values the Swift reads (`space1`, `space2`, `space3`,
//! `tabCornerRadius`, `tabBarControlSide`, `addGlyphExtent`, `cornerRadiusIsSet`) come in as
//! [`PlusMetrics`]; the theme's fills and inks come in as colours.
//!
//! Ops: `tokens.plus_button_geometry`, `tokens.plus_button_split_corner_radius`,
//! `tokens.plus_button_fill`, `tokens.plus_button_glyph_ink`, `tokens.plus_button_ink`,
//! `tokens.plus_button_path`, `tokens.plus_button_chevron`, `tokens.plus_button_draw_scale`,
//! `tokens.plus_button_state`.

use crate::ops::{OpError, OpResult, parse, reply};
use crate::tokens::color::{Color, Rgb};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A point (`CGPoint`, CGFloat = f64).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Point {
    /// x.
    pub x: f64,
    /// y.
    pub y: f64,
}

impl Point {
    /// A point at `x`, `y`.
    pub const fn new(x: f64, y: f64) -> Self {
        Point { x, y }
    }
}

/// A rectangle (`CGRect`, origin plus size; standardized, non-negative size).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
pub struct Rect {
    /// Origin x.
    pub x: f64,
    /// Origin y.
    pub y: f64,
    /// Width.
    pub width: f64,
    /// Height.
    pub height: f64,
}

impl Rect {
    /// A rectangle.
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Rect { x, y, width, height }
    }
    /// `CGRect.null`: what `insetBy` returns when the inset leaves a negative size.
    pub const NULL: Rect = Rect { x: f64::INFINITY, y: f64::INFINITY, width: 0.0, height: 0.0 };
    /// `minX`.
    pub fn min_x(&self) -> f64 {
        self.x
    }
    /// `minY`.
    pub fn min_y(&self) -> f64 {
        self.y
    }
    /// `maxX`.
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    /// `maxY`.
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    /// `midX`.
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    /// `midY`.
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    /// `CGRect.insetBy(dx:dy:)`: a negative resulting size gives [`Rect::NULL`].
    pub fn inset_by(&self, dx: f64, dy: f64) -> Rect {
        let width = self.width - dx * 2.0;
        let height = self.height - dy * 2.0;
        if width < 0.0 || height < 0.0 {
            return Rect::NULL;
        }
        Rect::new(self.x + dx, self.y + dy, width, height)
    }
}

/// What the pointer and the host's menu are doing to the + (`PlusButtonLook.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct State {
    /// The pointer is over the +.
    pub hovering: bool,
    /// The + is held down.
    pub pressed: bool,
    /// A menu the + opened is open.
    pub menu_open: bool,
    /// The other segment of a split `+ ⌄` is hovered.
    pub sibling_hovered: bool,
}

impl State {
    /// Hovered, or held by its menu.
    pub fn lit(&self) -> bool {
        self.hovering || self.menu_open
    }
    /// Pressed, or held by its menu.
    pub fn down(&self) -> bool {
        self.pressed || self.menu_open
    }
}

/// Where the + sits in its control (`PlusButtonLook.Segment`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Segment {
    /// A + of its own.
    #[default]
    Alone,
    /// The leading half of a split `+ ⌄`.
    Leading,
}

/// How an icon-only chrome button shows hover and press (`ChromeHoverStyle`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HoverStyle {
    /// A rounded-rectangle fill.
    #[default]
    Plate,
    /// No fill.
    Glyph,
    /// A circle centered on the glyph.
    Circle,
}

impl HoverStyle {
    /// Whether the style paints a fill behind the glyph (`paintsFill`).
    pub fn paints_fill(self) -> bool {
        self != HoverStyle::Glyph
    }
}

/// Every + button's hover style (`PlusButtonLook.defaultHoverStyle`).
pub const DEFAULT_HOVER_STYLE: HoverStyle = HoverStyle::Plate;

/// `CACornerMask.layerMinXMinYCorner`.
pub const CORNER_MIN_X_MIN_Y: u32 = 1;
/// `CACornerMask.layerMaxXMinYCorner`.
pub const CORNER_MAX_X_MIN_Y: u32 = 2;
/// `CACornerMask.layerMinXMaxYCorner`.
pub const CORNER_MIN_X_MAX_Y: u32 = 4;
/// `CACornerMask.layerMaxXMaxYCorner`.
pub const CORNER_MAX_X_MAX_Y: u32 = 8;
/// `PlusButtonLook.allCorners`, as the `CACornerMask` raw value.
pub const ALL_CORNERS: u32 =
    CORNER_MIN_X_MIN_Y | CORNER_MIN_X_MAX_Y | CORNER_MAX_X_MIN_Y | CORNER_MAX_X_MAX_Y;
/// The split segment's leading corners, as the `CACornerMask` raw value.
pub const LEADING_CORNERS: u32 = CORNER_MIN_X_MIN_Y | CORNER_MIN_X_MAX_Y;

/// The density-scaled `Metrics` values the + reads.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlusMetrics {
    /// `Metrics.space1`.
    pub space1: f64,
    /// `Metrics.space2`.
    pub space2: f64,
    /// `Metrics.space3`.
    pub space3: f64,
    /// `Metrics.tabCornerRadius` (also `buttonCornerRadius`).
    pub tab_corner_radius: f64,
    /// `Metrics.tabBarControlSide` (`tabHeight`).
    pub tab_bar_control_side: f64,
    /// `Metrics.addGlyphExtent`.
    pub add_glyph_extent: f64,
    /// `Metrics.cornerRadiusIsSet`: the person set a corner radius.
    #[serde(default)]
    pub corner_radius_is_set: bool,
}

/// `ConcentricCorners.radius(fitting:radius:)`: `radius`, at most half the shorter side, never negative.
pub fn radius_fitting(width: f64, height: f64, radius: f64) -> f64 {
    0f64.max(radius.min(width.min(height) / 2.0))
}

/// `Metrics.tabBarControlCornerRadius(fitting:)`: the tab pill's corner on a control of the size
/// (`None`: the `tabBarControlSide` square).
pub fn tab_bar_control_corner_radius(m: &PlusMetrics, size: Option<(f64, f64)>) -> f64 {
    let side = m.tab_bar_control_side;
    let (w, h) = size.unwrap_or((side, side));
    radius_fitting(w, h, m.tab_corner_radius)
}

/// `Metrics.buttonCornerRadius(proportionalTo:)`: 8 on 28 on the half-point grid, at most half the
/// side; a set corner radius keeps the button corner instead.
pub fn button_corner_radius_proportional(m: &PlusMetrics, side: f64) -> f64 {
    if m.corner_radius_is_set {
        return m.tab_corner_radius.min(side / 2.0);
    }
    (((side * 8.0 / 28.0) * 2.0).round() / 2.0).min(side / 2.0)
}

/// Where the fill and the glyph go in a host's bounds (`PlusButtonLook.Geometry`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Geometry {
    /// The fill's frame.
    pub fill: Rect,
    /// The fill's corner radius.
    pub corner_radius: f64,
    /// The rounded corners, as the `CACornerMask` raw value.
    pub corners: u32,
    /// The glyph's center, on the device pixels.
    pub glyph_center: Point,
}

/// The inputs of [`geometry`] (`PlusButtonLook.geometry(in:segment:hoverStyle:showsChevron:roundsAsTabBarControl:scale:)`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GeometryInput {
    /// The host's bounds.
    pub bounds: Rect,
    /// Where the + sits.
    #[serde(default)]
    pub segment: Segment,
    /// The hover look.
    #[serde(default)]
    pub hover_style: HoverStyle,
    /// A ⌄ after the + in the same control.
    #[serde(default)]
    pub shows_chevron: bool,
    /// A + in a tab bar.
    #[serde(default)]
    pub rounds_as_tab_bar_control: bool,
    /// The device scale.
    pub scale: f64,
    /// The metrics.
    pub metrics: PlusMetrics,
}

/// The fill's frame, its corner and the glyph's center for a host of `bounds`.
pub fn geometry(input: &GeometryInput) -> Geometry {
    let m = &input.metrics;
    let bounds = input.bounds;
    let side = bounds.width.min(bounds.height);
    let square = Rect::new(
        bounds.min_x() + (bounds.width - side) / 2.0,
        bounds.min_y() + (bounds.height - side) / 2.0,
        side,
        side,
    );
    let split = input.segment == Segment::Leading && !input.shows_chevron;
    let fill = if split {
        bounds
    } else if input.shows_chevron {
        bounds.inset_by(m.space1, (bounds.height - side) / 2.0)
    } else {
        square
    };
    let corner = if input.hover_style == HoverStyle::Circle && !input.shows_chevron && !split {
        side / 2.0
    } else if input.rounds_as_tab_bar_control {
        tab_bar_control_corner_radius(m, Some((fill.width, fill.height)))
    } else if split {
        button_corner_radius_proportional(m, m.tab_bar_control_side)
    } else {
        button_corner_radius_proportional(m, fill.width.min(fill.height))
    };
    let corners = if split { LEADING_CORNERS } else { ALL_CORNERS };
    let lean = if split { m.space1 / 2.0 } else { 0.0 };
    let scale = input.scale.max(1.0);
    let chevron_shift = if input.shows_chevron { m.space2 } else { 0.0 };
    let center = Point::new(
        ((square.mid_x() - chevron_shift + lean) * scale).round() / scale,
        (square.mid_y() * scale).round() / scale,
    );
    Geometry { fill, corner_radius: corner, corners, glyph_center: center }
}

/// `PlusButtonLook.splitCornerRadius`: `tabBarControlCornerRadius()` on the control's square.
pub fn split_corner_radius(m: &PlusMetrics) -> f64 {
    tab_bar_control_corner_radius(m, None)
}

/// Which fill the + shows (`PlusButtonLook.fill(_:hoverStyle:segment:)` through `ChromeHover.fillColor`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Fill {
    /// No fill.
    None,
    /// `Palette.hoverFill`.
    Hover,
    /// `Palette.pressedFill`.
    Pressed,
    /// `Palette.hoverFill` at half its alpha (the split segment while its sibling is hovered).
    HalfHover,
}

/// The fill for `state`. `shows_hover_fills` is `DesignSettings.showsHoverFills` (false in calm
/// mode: a lit-only-by-pointer state then paints none).
pub fn fill(
    state: State,
    hover_style: HoverStyle,
    segment: Segment,
    shows_hover_fills: bool,
) -> Fill {
    if !hover_style.paints_fill() {
        return Fill::None;
    }
    if state.lit() || state.down() {
        // ChromeHover.fillColor(.init(hovering: lit, pressed: down)): pressed wins; `lit` there is
        // false, so a hover goes through the calm-mode gate.
        if state.down() {
            return Fill::Pressed;
        }
        return if shows_hover_fills { Fill::Hover } else { Fill::None };
    }
    if segment != Segment::Leading || !state.sibling_hovered {
        return Fill::None;
    }
    if shows_hover_fills { Fill::HalfHover } else { Fill::None }
}

/// [`Fill`] as a colour from the theme's `hover_fill` and `pressed_fill`.
pub fn fill_color(fill: Fill, hover_fill: Rgb, pressed_fill: Rgb) -> Option<Rgb> {
    match fill {
        Fill::None => None,
        Fill::Hover => Some(hover_fill),
        Fill::Pressed => Some(pressed_fill),
        Fill::HalfHover => Some(hover_fill.with_alpha(hover_fill.a / 2.0)),
    }
}

/// Which palette ink the + strokes in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ink {
    /// `Palette.textSecondary`.
    TextSecondary,
    /// `Palette.textPrimary`.
    TextPrimary,
    /// `Palette.litGlyph`.
    LitGlyph,
}

/// `PlusButtonLook.glyphInk(hovering:pressed:)`: secondary at rest, primary on hover, lit while pressed.
pub fn glyph_ink(hovering: bool, pressed: bool) -> Ink {
    if pressed {
        Ink::LitGlyph
    } else if hovering {
        Ink::TextPrimary
    } else {
        Ink::TextSecondary
    }
}

/// `PlusButtonLook.ink(_:)`: a held + keeps its hover ink; an open menu lights it.
pub fn ink(state: State) -> Ink {
    glyph_ink(state.hovering || state.pressed, state.menu_open)
}

/// [`Ink`] as a colour from the theme's three inks.
pub fn ink_color(ink: Ink, text_secondary: Rgb, text_primary: Rgb, lit_glyph: Rgb) -> Rgb {
    match ink {
        Ink::TextSecondary => text_secondary,
        Ink::TextPrimary => text_primary,
        Ink::LitGlyph => lit_glyph,
    }
}

/// `PlusButtonLook.chevronHalfWidth`: three quarters of the +'s arm.
pub fn chevron_half_width(add_glyph_extent: f64) -> f64 {
    add_glyph_extent / 2.0 * 0.75
}

/// `PlusButtonLook.chevronRise`: its half width.
pub fn chevron_rise(add_glyph_extent: f64) -> f64 {
    chevron_half_width(add_glyph_extent)
}

/// `CGPath.addGlyph(center:scale:)`: the + as two strokes (horizontal, then vertical), its center
/// snapped to the device pixels of `scale`.
pub fn add_glyph(center: Point, scale: f64, add_glyph_extent: f64) -> [[Point; 2]; 2] {
    let arm = add_glyph_extent / 2.0;
    let scale = scale.max(1.0);
    let c = Point::new((center.x * scale).round() / scale, (center.y * scale).round() / scale);
    [
        [Point::new(c.x - arm, c.y), Point::new(c.x + arm, c.y)],
        [Point::new(c.x, c.y - arm), Point::new(c.x, c.y + arm)],
    ]
}

/// The ⌄ `layout(in:scale:)` adds after the +: three points, left, tip, right.
pub fn chevron(glyph_center: Point, add_glyph_extent: f64, space3: f64) -> [Point; 3] {
    let x = glyph_center.x + add_glyph_extent / 2.0 + space3;
    let half = chevron_half_width(add_glyph_extent);
    let rise = chevron_rise(add_glyph_extent);
    [
        Point::new(x - half, glyph_center.y - rise / 2.0),
        Point::new(x, glyph_center.y + rise / 2.0),
        Point::new(x + half, glyph_center.y - rise / 2.0),
    ]
}

/// The glyph layer's whole path `layout(in:scale:)` builds: the + strokes, then the ⌄ when shown.
pub fn path(
    geometry: &Geometry,
    scale: f64,
    shows_chevron: bool,
    m: &PlusMetrics,
) -> Vec<Vec<Point>> {
    let mut out: Vec<Vec<Point>> = add_glyph(geometry.glyph_center, scale, m.add_glyph_extent)
        .iter()
        .map(|s| s.to_vec())
        .collect();
    if shows_chevron {
        out.push(chevron(geometry.glyph_center, m.add_glyph_extent, m.space3).to_vec());
    }
    out
}

/// `drawGlyph`'s device scale: the context's x scale, else 2 when it is 0.
pub fn draw_scale(transform_a: f64) -> f64 {
    if transform_a.abs() > 0.0 { transform_a.abs() } else { 2.0 }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MetricsRequest {
    metrics: PlusMetrics,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FillRequest {
    #[serde(default)]
    state: State,
    #[serde(default)]
    hover_style: HoverStyle,
    #[serde(default)]
    segment: Segment,
    #[serde(default = "yes")]
    shows_hover_fills: bool,
    hover_fill: Option<Color>,
    pressed_fill: Option<Color>,
}

fn yes() -> bool {
    true
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FillReply {
    fill: Fill,
    color: Option<Color>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InkColors {
    text_secondary: Color,
    text_primary: Color,
    lit_glyph: Color,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GlyphInkRequest {
    #[serde(default)]
    hovering: bool,
    #[serde(default)]
    pressed: bool,
    colors: Option<InkColors>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InkRequest {
    #[serde(default)]
    state: State,
    colors: Option<InkColors>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InkReply {
    ink: Ink,
    color: Option<Color>,
}

fn ink_reply(ink: Ink, colors: Option<InkColors>) -> OpResult {
    let color = colors.map(|c| {
        Color::from(ink_color(
            ink,
            c.text_secondary.into(),
            c.text_primary.into(),
            c.lit_glyph.into(),
        ))
    });
    reply(&InkReply { ink, color })
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct GeometryReply {
    #[serde(flatten)]
    geometry: Geometry,
    path: Vec<Vec<Point>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChevronRequest {
    glyph_center: Point,
    add_glyph_extent: f64,
    space3: f64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ChevronReply {
    half_width: f64,
    rise: f64,
    points: [Point; 3],
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PathRequest {
    center: Point,
    scale: f64,
    add_glyph_extent: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DrawScaleRequest {
    transform_a: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StateRequest {
    #[serde(default)]
    state: State,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StateReply {
    lit: bool,
    down: bool,
}

/// Runs the `tokens.plus_button_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        // {bounds, segment?, hoverStyle?, showsChevron?, roundsAsTabBarControl?, scale, metrics}
        // -> {fill, cornerRadius, corners, glyphCenter, path}
        "plus_button_geometry" => {
            let input: GeometryInput = parse(request)?;
            let g = geometry(&input);
            let path = path(&g, input.scale, input.shows_chevron, &input.metrics);
            reply(&GeometryReply { geometry: g, path })
        }
        "plus_button_split_corner_radius" => {
            let r: MetricsRequest = parse(request)?;
            reply(&split_corner_radius(&r.metrics))
        }
        "plus_button_fill" => {
            let r: FillRequest = parse(request)?;
            let f = fill(r.state, r.hover_style, r.segment, r.shows_hover_fills);
            let color = match (r.hover_fill, r.pressed_fill) {
                (Some(h), Some(p)) => fill_color(f, h.into(), p.into()).map(Color::from),
                _ => None,
            };
            reply(&FillReply { fill: f, color })
        }
        "plus_button_glyph_ink" => {
            let r: GlyphInkRequest = parse(request)?;
            ink_reply(glyph_ink(r.hovering, r.pressed), r.colors)
        }
        "plus_button_ink" => {
            let r: InkRequest = parse(request)?;
            ink_reply(ink(r.state), r.colors)
        }
        "plus_button_path" => {
            let r: PathRequest = parse(request)?;
            reply(&add_glyph(r.center, r.scale, r.add_glyph_extent))
        }
        "plus_button_chevron" => {
            let r: ChevronRequest = parse(request)?;
            reply(&ChevronReply {
                half_width: chevron_half_width(r.add_glyph_extent),
                rise: chevron_rise(r.add_glyph_extent),
                points: chevron(r.glyph_center, r.add_glyph_extent, r.space3),
            })
        }
        "plus_button_draw_scale" => {
            let r: DrawScaleRequest = parse(request)?;
            reply(&draw_scale(r.transform_a))
        }
        "plus_button_state" => {
            let r: StateRequest = parse(request)?;
            reply(&StateReply { lit: r.state.lit(), down: r.state.down() })
        }
        _ => Err(OpError::Unknown),
    }
}
