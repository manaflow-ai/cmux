//! The top row: `TopRowLine` and its look, `TopRowSpacing` (gaps and glyph slots),
//! `GlyphInkMeasure`'s scan, `TrafficLightsLine` and `WindowedTrafficLights`.
//!
//! `PaneChromeMetrics` values (tab gap, pill center, card top) come in as numbers: they belong to
//! the pane chrome tokens.

use super::{Rect, run};
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `TopRowLineLook`: the line the traffic lights, the toolbar band, the sidebar's + and the top
/// row's tabs share.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TopRowLineLook {
    #[default]
    Concentric,
    Lights,
    Tabs,
    Titlebar,
    Off,
}

/// The tunable's key.
pub const LOOK_TUNABLE_KEY: &str = "chrome.topRowLine";

impl TopRowLineLook {
    pub const ALL: [TopRowLineLook; 5] =
        [Self::Concentric, Self::Lights, Self::Tabs, Self::Titlebar, Self::Off];

    pub fn raw(self) -> &'static str {
        match self {
            Self::Concentric => "concentric",
            Self::Lights => "lights",
            Self::Tabs => "tabs",
            Self::Titlebar => "titlebar",
            Self::Off => "off",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Concentric => "Even inset, concentric with the window (default)",
            Self::Lights => "Traffic lights' line",
            Self::Tabs => "The tabs' line",
            Self::Titlebar => "Middle of the titlebar row",
            Self::Off => "Off (pills on their strip's padding)",
        }
    }
}

/// `TopRowLine.resolve`: the line's center from the window's top, per look.
pub fn resolve(
    look: TopRowLineLook,
    lights_center_y: f64,
    tabs_center_y: f64,
    titlebar_height: f64,
    concentric_card_top: f64,
) -> f64 {
    match look {
        TopRowLineLook::Lights | TopRowLineLook::Off => lights_center_y,
        TopRowLineLook::Tabs => tabs_center_y,
        TopRowLineLook::Concentric => concentric_card_top + tabs_center_y,
        TopRowLineLook::Titlebar => titlebar_height / 2.0,
    }
}

/// `TopRowLine.controlTop`: the top of a `side` control centered on the line, on the pixel grid.
pub fn control_top(center_y: f64, side: f64, scale: f64) -> f64 {
    let s = scale.max(1.0);
    ((center_y - side / 2.0) * s).round() / s
}

/// Where `WindowTitlebar.topRowLine(in:)` takes the line from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TopRowLineSource {
    /// No line (not the minimal titlebar with top tabs, or no traffic lights).
    None,
    /// The look's target line itself.
    Target,
    /// Floating panes: `stripTop + pillTop + tabHeight / 2`.
    FloatingStrip,
    /// `TopRowLine.concentric(row, rim: stripCardTop)`.
    Concentric,
    /// The pill center the card top that centers it reaches (`target.reached(by:cardTop:rim:)`).
    Reached,
}

/// The branch `WindowTitlebar.topRowLine(in:look:)` takes.
pub fn line_source(
    look: TopRowLineLook,
    has_target: bool,
    floating_panes: bool,
) -> TopRowLineSource {
    if !has_target {
        return TopRowLineSource::None;
    }
    if look == TopRowLineLook::Off {
        return TopRowLineSource::Target;
    }
    if floating_panes {
        return if look == TopRowLineLook::Concentric {
            TopRowLineSource::Target
        } else {
            TopRowLineSource::FloatingStrip
        };
    }
    if look == TopRowLineLook::Concentric {
        TopRowLineSource::Concentric
    } else {
        TopRowLineSource::Reached
    }
}

/// `topRowEvensPillGaps`: the pills' gaps are evened when a line is drawn on docked panes.
pub fn evens_pill_gaps(look: TopRowLineLook, floating_panes: bool, has_target: bool) -> bool {
    look != TopRowLineLook::Off && !floating_panes && has_target
}

/// `Metrics.windowEdgeInset`: a titled, windowed window keeps at least the rim.
pub fn window_edge_inset(inset: f64, edged: bool, rim_height: f64) -> f64 {
    if edged { inset.max(rim_height) } else { inset }
}

/// The top row strip's facts `topRowCardTop` reads.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CardTopInputs {
    pub look: TopRowLineLook,
    pub floating_panes: bool,
    pub gutter: f64,
    /// The window is titled and not full screen (`windowEdgeInset` applies).
    pub edged: bool,
    /// `PaneTabRowRim.height`.
    pub rim_height: f64,
    /// `PaneChromeMetrics.current.cardTopKeepingStripCentering(centeringPillOn:scale:)`.
    pub keep_centering: f64,
    /// `topRowMetrics.cardTop(centeringPillOn:rim:scale:)` with the rim as floor.
    pub centered: f64,
    /// `topRowMetrics` strip height, tab height and snapped pane padding (for the even split).
    pub strip_height: f64,
    pub tab_height: f64,
    pub snapped_padding: f64,
    pub scale: f64,
}

/// `WindowTitlebar.topRowCardTop(centeringPillOn:gutter:in:look:)`.
pub fn card_top(i: &CardTopInputs) -> f64 {
    if i.floating_panes {
        return i.gutter;
    }
    let floor = window_edge_inset(0.0, i.edged, i.rim_height);
    match i.look {
        TopRowLineLook::Concentric => floor,
        TopRowLineLook::Off => {
            window_edge_inset(i.gutter.min(i.keep_centering), i.edged, i.rim_height)
        }
        _ => {
            let card = i.gutter.min(i.centered).max(floor);
            even_split_card_top(card, floor, i.gutter.max(floor), floor, i)
        }
    }
}

/// `PaneChromeMetrics.evenSplitCardTop`: an odd pixel of room moves the card one pixel, down when it fits.
fn even_split_card_top(card_top: f64, lower: f64, upper: f64, rim: f64, i: &CardTopInputs) -> f64 {
    let s = i.scale.max(1.0);
    let room = i.strip_height - i.tab_height - i.snapped_padding - (card_top - rim.max(0.0));
    if !(room > 0.0 && ((room * s).round() as i64) % 2 != 0) {
        return card_top;
    }
    if card_top + 1.0 / s <= upper {
        return card_top + 1.0 / s;
    }
    if card_top - 1.0 / s >= lower {
        return card_top - 1.0 / s;
    }
    card_top
}

/// `TopRowSpacing`'s derived sizes from the button side and the glyph extent.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spacing {
    pub group_gap: f64,
    pub glyph_gap: f64,
    pub arrow_icon_size: f64,
    pub toggle_glyph_point_size: f64,
}

/// `TopRowSpacing.groupGap`, `glyphGap`, `arrowIconSize`, `toggleGlyphPointSize`.
pub fn spacing(button_side: f64, glyph_extent: f64) -> Spacing {
    let group_gap = (button_side * 0.3 * 2.0).round() / 2.0;
    Spacing {
        group_gap,
        glyph_gap: group_gap + (button_side - glyph_extent).max(0.0),
        arrow_icon_size: (glyph_extent / 0.6 * 2.0).round() / 2.0,
        toggle_glyph_point_size: (glyph_extent / 0.95 * 2.0).round() / 2.0,
    }
}

/// A button's image width and where its ink is (`lower...upper`).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Glyph {
    pub image_width: f64,
    pub ink: [f64; 2],
}

impl Glyph {
    /// A button with no image.
    pub const EMPTY: Glyph = Glyph { image_width: 0.0, ink: [0.0, 0.0] };

    pub fn width(&self) -> f64 {
        self.ink[1] - self.ink[0]
    }
    pub fn center_offset(&self) -> f64 {
        (self.ink[0] + self.ink[1] - self.image_width) / 2.0
    }
}

/// One slot: its x and width in the band.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Slot {
    pub x: f64,
    pub width: f64,
}

/// `TopRowSpacing.Slots`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Slots {
    pub frames: Vec<Slot>,
    pub width: f64,
    pub leading_ink: f64,
}

/// `TopRowSpacing.slots`: buttons whose inks sit `gap` apart, each as wide as it can be without
/// reaching past the midpoint of its gap to a neighbor; the band starts at its first button.
pub fn slots(side: f64, gap: f64, glyphs: &[Glyph]) -> Slots {
    let Some(first) = glyphs.first() else {
        return Slots { frames: Vec::new(), width: 0.0, leading_ink: 0.0 };
    };
    let mut centers = vec![side / 2.0 + first.center_offset()];
    for pair in glyphs.windows(2) {
        let last = centers[centers.len() - 1];
        centers.push(last + pair[0].width() / 2.0 + gap + pair[1].width() / 2.0);
    }
    let edges: Vec<f64> =
        centers.iter().zip(glyphs).map(|(c, g)| c + g.width() / 2.0 + gap / 2.0).collect();
    let mut frames: Vec<Slot> = Vec::with_capacity(glyphs.len());
    for (index, glyph) in glyphs.iter().enumerate() {
        let middle = centers[index] - glyph.center_offset();
        let mut half = side / 2.0;
        if index > 0 {
            half = half.min(middle - edges[index - 1]);
        }
        if index < glyphs.len() - 1 {
            half = half.min(edges[index] - middle);
        }
        half = half.max(0.0);
        frames.push(Slot { x: middle - half, width: half * 2.0 });
    }
    let shift = frames[0].x;
    for frame in &mut frames {
        frame.x -= shift;
    }
    let leading_ink = centers[0] - first.width() / 2.0 - shift;
    let width = frames.last().map_or(0.0, |f| f.x + f.width);
    Slots { frames, width, leading_ink }
}

/// `TopRowSpacing.leadingGap`: the gap before the band, less the ink's own lead, at least `space1`.
pub fn leading_gap(gap: f64, leading_ink: f64, space1: f64) -> f64 {
    space1.max(gap - leading_ink)
}

/// `Slots.frames(presence:height:)`: each slot scaled by `presence`, a `side` square centered in `height`.
pub fn slot_frames(slots: &Slots, presence: f64, height: f64, side: f64) -> Vec<Rect> {
    slots
        .frames
        .iter()
        .map(|f| Rect::new(f.x * presence, (height - side) / 2.0, f.width * presence, side))
        .collect()
}

/// `GlyphInkMeasure`'s render scale.
pub const INK_SCALE: f64 = 4.0;
/// Alpha above which a pixel is ink (0.3 of 255).
pub const INK_ALPHA: u8 = 76;

/// The bitmap `GlyphInkMeasure` draws an image of `width` x `height` points into.
pub fn ink_bitmap_size(width: f64, height: f64) -> (i64, i64) {
    ((width * INK_SCALE).ceil() as i64, (height * INK_SCALE).ceil() as i64)
}

/// `GlyphInkMeasure.measure` after drawing: `alpha` is the bitmap's alpha, row by row, `pixels_wide`
/// per row. No ink (or no bitmap) is the whole image.
pub fn glyph_ink(image_width: f64, pixels_wide: usize, alpha: &[u8]) -> Glyph {
    let whole = Glyph { image_width, ink: [0.0, image_width.max(0.0)] };
    if pixels_wide == 0 || alpha.is_empty() {
        return whole;
    }
    let (mut min_x, mut max_x) = (usize::MAX, None::<usize>);
    for row in alpha.chunks(pixels_wide) {
        for (x, a) in row.iter().enumerate() {
            if *a > INK_ALPHA {
                min_x = min_x.min(x);
                max_x = Some(max_x.map_or(x, |m| m.max(x)));
            }
        }
    }
    match max_x {
        Some(max_x) if max_x >= min_x => {
            Glyph { image_width, ink: [min_x as f64 / INK_SCALE, (max_x + 1) as f64 / INK_SCALE] }
        }
        _ => whole,
    }
}

/// The traffic lights' button side.
pub const BUTTON_SIDE: f64 = 14.0;
/// AppKit's titlebar height.
pub const NATIVE_TITLEBAR_HEIGHT: f64 = 32.0;

/// `TrafficLightsLine.Placement`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Placement {
    pub container_height: f64,
    pub center_y: f64,
    pub leading_x: f64,
}

/// `TrafficLightsLine.placement`: the lights centered on the line (AppKit's own middle when none),
/// on the pixel grid, the container tall enough to hold them.
pub fn placement(
    center_y: Option<f64>,
    button_height: f64,
    native_height: f64,
    scale: f64,
) -> Placement {
    let s = scale.max(1.0);
    let center = (center_y.unwrap_or(native_height / 2.0) * s).round() / s;
    let height = native_height.max(((center + button_height / 2.0) * s).ceil() / s);
    Placement {
        container_height: height,
        center_y: center,
        leading_x: ((center - button_height / 2.0) * s).round() / s,
    }
}

/// `TrafficLightsLine.targetCenterY`: under `lights` and `off` the lights keep AppKit's line.
pub fn follows_line(look: TopRowLineLook) -> bool {
    look != TopRowLineLook::Lights && look != TopRowLineLook::Off
}

/// `NSWindow.StyleMask` raw bits.
pub mod style_mask {
    pub const TITLED: u64 = 1 << 0;
    pub const CLOSABLE: u64 = 1 << 1;
    pub const MINIATURIZABLE: u64 = 1 << 2;
    pub const RESIZABLE: u64 = 1 << 3;
    pub const FULL_SIZE_CONTENT_VIEW: u64 = 1 << 15;
}

/// `TrafficLightsOwner.tilingMask`: the bits that move the buttons, with all three buttons present.
pub fn tiling_mask(mask: u64) -> u64 {
    use style_mask::*;
    let base = TITLED | CLOSABLE | MINIATURIZABLE | RESIZABLE;
    (mask & (base | FULL_SIZE_CONTENT_VIEW)) | base
}

/// `TrafficLightsOwner.nativeOffsets`' check: close at 0, then miniaturize, then zoom to its right.
pub fn offsets_valid(close: Option<f64>, miniaturize: Option<f64>, zoom: Option<f64>) -> bool {
    let mini = miniaturize.unwrap_or(0.0);
    close == Some(0.0) && mini > 0.0 && zoom.unwrap_or(0.0) > mini
}

/// A shown standard button: its native offset from close, and its size.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RestingButton {
    pub offset: f64,
    pub width: f64,
    pub height: f64,
}

/// `TrafficLightsLine.restingFrame`'s union: each button at `leadingX + offset`, centered on the
/// placement's line (window coordinates, bottom-left origin). No buttons: none.
pub fn resting_frame(
    placement: &Placement,
    window_height: f64,
    buttons: &[RestingButton],
) -> Option<Rect> {
    let mid_y = window_height - placement.center_y;
    buttons
        .iter()
        .map(|b| {
            Rect::new(placement.leading_x + b.offset, mid_y - b.height / 2.0, b.width, b.height)
        })
        .reduce(|a, b| a.union(&b))
}

/// `TrafficLightsLine.apply`'s button x: left to right, the anchor plus the native offset (or the
/// button's own distance from close); right to left, where AppKit put it.
pub fn button_x(
    left_to_right: bool,
    anchor_x: f64,
    offset: Option<f64>,
    button_min_x: f64,
    close_min_x: f64,
) -> f64 {
    if left_to_right {
        anchor_x + offset.unwrap_or(button_min_x - close_min_x)
    } else {
        button_min_x
    }
}

/// `WindowedTrafficLights`: where the lights sat while windowed, from the window's top.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowedTrafficLights {
    #[serde(default)]
    pub place: Option<WindowedPlace>,
}

/// One noted place.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowedPlace {
    pub x: f64,
    pub from_top: f64,
    pub width: f64,
    pub height: f64,
}

impl WindowedTrafficLights {
    /// Notes the lights' frame, only while windowed.
    pub fn note(&mut self, lights: Rect, window_height: f64, windowed: bool) {
        if !windowed {
            return;
        }
        self.place = Some(WindowedPlace {
            x: lights.min_x(),
            from_top: window_height - lights.max_y(),
            width: lights.width.abs(),
            height: lights.height.abs(),
        });
    }

    /// The noted frame in a window `window_height` tall.
    pub fn resting(&self, window_height: f64) -> Option<Rect> {
        self.place.map(|p| Rect::new(p.x, window_height - p.from_top - p.height, p.width, p.height))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LookReply {
    raw: &'static str,
    title: &'static str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LooksReply {
    key: &'static str,
    default: TopRowLineLook,
    looks: Vec<LookReply>,
}

/// `window.topRowLooks` `{}` → `{key, default, looks: [{raw, title}]}`.
pub(super) fn op_looks(request: &Value) -> OpResult {
    run(request, |_: Value| LooksReply {
        key: LOOK_TUNABLE_KEY,
        default: TopRowLineLook::default(),
        looks: TopRowLineLook::ALL
            .iter()
            .map(|l| LookReply { raw: l.raw(), title: l.title() })
            .collect(),
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResolveRequest {
    look: TopRowLineLook,
    lights_center_y: f64,
    tabs_center_y: f64,
    titlebar_height: f64,
    #[serde(default)]
    concentric_card_top: f64,
}

/// `window.topRowResolve` `{look, lightsCenterY, tabsCenterY, titlebarHeight, concentricCardTop?}` → centerY.
pub(super) fn op_resolve(request: &Value) -> OpResult {
    run(request, |r: ResolveRequest| {
        resolve(
            r.look,
            r.lights_center_y,
            r.tabs_center_y,
            r.titlebar_height,
            r.concentric_card_top,
        )
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ControlTopRequest {
    center_y: f64,
    side: f64,
    scale: f64,
}

/// `window.topRowControlTop` `{centerY, side, scale}` → top.
pub(super) fn op_control_top(request: &Value) -> OpResult {
    run(request, |r: ControlTopRequest| control_top(r.center_y, r.side, r.scale))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LineSourceRequest {
    look: TopRowLineLook,
    has_target: bool,
    floating_panes: bool,
}

/// `window.topRowLineSource` `{look, hasTarget, floatingPanes}` → source.
pub(super) fn op_line_source(request: &Value) -> OpResult {
    run(request, |r: LineSourceRequest| line_source(r.look, r.has_target, r.floating_panes))
}

/// `window.topRowEvensPillGaps` `{look, hasTarget, floatingPanes}` → bool.
pub(super) fn op_evens_pill_gaps(request: &Value) -> OpResult {
    run(request, |r: LineSourceRequest| evens_pill_gaps(r.look, r.floating_panes, r.has_target))
}

/// `window.topRowCardTop` [`CardTopInputs`] → card top.
pub(super) fn op_card_top(request: &Value) -> OpResult {
    run(request, |r: CardTopInputs| card_top(&r))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SpacingRequest {
    button_side: f64,
    glyph_extent: f64,
}

/// `window.topRowSpacing` `{buttonSide, glyphExtent}` → [`Spacing`].
pub(super) fn op_spacing(request: &Value) -> OpResult {
    run(request, |r: SpacingRequest| spacing(r.button_side, r.glyph_extent))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SlotsRequest {
    side: f64,
    gap: f64,
    /// A null glyph is a button with no image.
    glyphs: Vec<Option<Glyph>>,
}

/// `window.topRowSlots` `{side, gap, glyphs}` → [`Slots`].
pub(super) fn op_slots(request: &Value) -> OpResult {
    run(request, |r: SlotsRequest| {
        let glyphs: Vec<Glyph> = r.glyphs.into_iter().map(|g| g.unwrap_or(Glyph::EMPTY)).collect();
        slots(r.side, r.gap, &glyphs)
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SlotFramesRequest {
    slots: Slots,
    presence: f64,
    height: f64,
    side: f64,
}

/// `window.topRowSlotFrames` `{slots, presence, height, side}` → `[Rect]`.
pub(super) fn op_slot_frames(request: &Value) -> OpResult {
    run(request, |r: SlotFramesRequest| slot_frames(&r.slots, r.presence, r.height, r.side))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LeadingGapRequest {
    gap: f64,
    leading_ink: f64,
    space1: f64,
}

/// `window.topRowLeadingGap` `{gap, leadingInk, space1}` → gap.
pub(super) fn op_leading_gap(request: &Value) -> OpResult {
    run(request, |r: LeadingGapRequest| leading_gap(r.gap, r.leading_ink, r.space1))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct GlyphInkRequest {
    image_width: f64,
    pixels_wide: usize,
    alpha: Vec<u8>,
}

/// `window.glyphInk` `{imageWidth, pixelsWide, alpha}` → [`Glyph`].
pub(super) fn op_glyph_ink(request: &Value) -> OpResult {
    run(request, |r: GlyphInkRequest| glyph_ink(r.image_width, r.pixels_wide, &r.alpha))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlacementRequest {
    #[serde(default)]
    center_y: Option<f64>,
    #[serde(default = "default_button_height")]
    button_height: f64,
    #[serde(default = "default_native_height")]
    native_height: f64,
    scale: f64,
}

fn default_button_height() -> f64 {
    BUTTON_SIDE
}
fn default_native_height() -> f64 {
    NATIVE_TITLEBAR_HEIGHT
}

/// `window.trafficLightsPlacement` `{centerY?, buttonHeight?, nativeHeight?, scale}` → [`Placement`].
pub(super) fn op_traffic_lights_placement(request: &Value) -> OpResult {
    run(request, |r: PlacementRequest| {
        placement(r.center_y, r.button_height, r.native_height, r.scale)
    })
}

#[derive(Deserialize)]
struct LookRequest {
    look: TopRowLineLook,
}

/// `window.trafficLightsFollowsLine` `{look}` → bool.
pub(super) fn op_traffic_lights_follows_line(request: &Value) -> OpResult {
    run(request, |r: LookRequest| follows_line(r.look))
}

#[derive(Deserialize)]
struct MaskRequest {
    mask: u64,
}

/// `window.trafficLightsTilingMask` `{mask}` → mask.
pub(super) fn op_tiling_mask(request: &Value) -> OpResult {
    run(request, |r: MaskRequest| tiling_mask(r.mask))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OffsetsRequest {
    #[serde(default)]
    close: Option<f64>,
    #[serde(default)]
    miniaturize: Option<f64>,
    #[serde(default)]
    zoom: Option<f64>,
}

/// `window.trafficLightsOffsetsValid` `{close?, miniaturize?, zoom?}` → bool.
pub(super) fn op_offsets_valid(request: &Value) -> OpResult {
    run(request, |r: OffsetsRequest| offsets_valid(r.close, r.miniaturize, r.zoom))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RestingFrameRequest {
    placement: Placement,
    window_height: f64,
    buttons: Vec<RestingButton>,
}

/// `window.trafficLightsRestingFrame` `{placement, windowHeight, buttons}` → Rect or null.
pub(super) fn op_resting_frame(request: &Value) -> OpResult {
    run(request, |r: RestingFrameRequest| resting_frame(&r.placement, r.window_height, &r.buttons))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ButtonXRequest {
    left_to_right: bool,
    anchor_x: f64,
    #[serde(default)]
    offset: Option<f64>,
    button_min_x: f64,
    close_min_x: f64,
}

/// `window.trafficLightsButtonX` `{leftToRight, anchorX, offset?, buttonMinX, closeMinX}` → x.
pub(super) fn op_button_x(request: &Value) -> OpResult {
    run(request, |r: ButtonXRequest| {
        button_x(r.left_to_right, r.anchor_x, r.offset, r.button_min_x, r.close_min_x)
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WindowedRequest {
    #[serde(default)]
    state: WindowedTrafficLights,
    #[serde(default)]
    note: Option<WindowedNote>,
    #[serde(default)]
    resting_height: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WindowedNote {
    lights: Rect,
    window_height: f64,
    windowed: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WindowedReply {
    state: WindowedTrafficLights,
    resting: Option<Rect>,
}

/// `window.windowedTrafficLights` `{state?, note?, restingHeight?}` → `{state, resting}`.
pub(super) fn op_windowed_traffic_lights(request: &Value) -> OpResult {
    run(request, |r: WindowedRequest| {
        let mut state = r.state;
        if let Some(n) = r.note {
            state.note(n.lights, n.window_height, n.windowed);
        }
        let resting = r.resting_height.and_then(|h| state.resting(h));
        WindowedReply { state, resting }
    })
}
