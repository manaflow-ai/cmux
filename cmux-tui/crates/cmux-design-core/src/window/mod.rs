//! Window press routing, focus route, click trace, resize bands, full-screen titlebar press,
//! the top row's line and spacing, the traffic lights' line, zoom, window targeting, the launch
//! layout settle and the debug probes' rules (CmuxNextDesign `Windows/`, `Debug/`,
//! `Diagnostics/`, `ClickTrace`, `WindowPressRouter`, `FullScreenTitlebarPress`, `ResizeBands`,
//! `KeyWindowRepaint`, `FocusRoute`).
//!
//! The app keeps every AppKit call (hit tests, `makeKey`, frames, events). It hands these
//! functions the facts it read and does what they decide. Windows and views are opaque ids.
//!
//! Ops: `window.NAME` (see [`call`]).

pub mod click_trace;
pub mod diagnostics;
pub mod fill;
pub mod launch;
pub mod press;
pub mod targeting;
pub mod top_row;
pub mod zoom;

use crate::ops::{self, OpError, OpResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// A rectangle in points (AppKit's bottom-left origin unless a rule says otherwise).
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    pub fn min_x(&self) -> f64 {
        self.x.min(self.x + self.width)
    }
    pub fn min_y(&self) -> f64 {
        self.y.min(self.y + self.height)
    }
    pub fn max_x(&self) -> f64 {
        self.x.max(self.x + self.width)
    }
    pub fn max_y(&self) -> f64 {
        self.y.max(self.y + self.height)
    }
    /// `CGRect.contains(_:)`: half open, so a point on the max edges is outside.
    pub fn contains(&self, point: Point) -> bool {
        point.x >= self.min_x()
            && point.x < self.max_x()
            && point.y >= self.min_y()
            && point.y < self.max_y()
    }
    /// `CGRect.union(_:)` for two non-null rectangles.
    pub fn union(&self, other: &Rect) -> Rect {
        let (x, y) = (self.min_x().min(other.min_x()), self.min_y().min(other.min_y()));
        Rect::new(x, y, self.max_x().max(other.max_x()) - x, self.max_y().max(other.max_y()) - y)
    }
}

/// A point in points.
#[derive(Debug, Clone, Copy, PartialEq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// The `NSEvent.EventType`s these rules tell apart.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventKind {
    LeftMouseDown,
    LeftMouseDragged,
    LeftMouseUp,
    RightMouseDown,
    OtherMouseDown,
    Pressure,
    /// Any other type.
    #[serde(other)]
    Other,
}

/// Runs `window.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        // ClickTrace
        "clickTraceStep" => click_trace::op_step(request),
        "clickEntries" => click_trace::op_entries(request),
        "clickReport" => click_trace::op_report(request),
        "clickPoint" => click_trace::op_point(request),
        "clickButton" => click_trace::op_button(request),
        // Press routing
        "keyNeutralStep" => press::op_key_neutral_step(request),
        "isPage" => press::op_is_page(request),
        "fullScreenTitlebarStep" => press::op_full_screen_step(request),
        "fullScreenTitlebarButton" => press::op_full_screen_button(request),
        "resizeBandsClaim" => press::op_resize_bands_claim(request),
        "showsFocus" => press::op_shows_focus(request),
        "focusRouteDescription" => press::op_focus_route_description(request),
        // Top row and traffic lights
        "topRowLooks" => top_row::op_looks(request),
        "topRowResolve" => top_row::op_resolve(request),
        "topRowControlTop" => top_row::op_control_top(request),
        "topRowLineSource" => top_row::op_line_source(request),
        "topRowCardTop" => top_row::op_card_top(request),
        "topRowEvensPillGaps" => top_row::op_evens_pill_gaps(request),
        "topRowSpacing" => top_row::op_spacing(request),
        "topRowSlots" => top_row::op_slots(request),
        "topRowSlotFrames" => top_row::op_slot_frames(request),
        "topRowLeadingGap" => top_row::op_leading_gap(request),
        "glyphInk" => top_row::op_glyph_ink(request),
        "trafficLightsPlacement" => top_row::op_traffic_lights_placement(request),
        "trafficLightsFollowsLine" => top_row::op_traffic_lights_follows_line(request),
        "trafficLightsTilingMask" => top_row::op_tiling_mask(request),
        "trafficLightsOffsetsValid" => top_row::op_offsets_valid(request),
        "trafficLightsRestingFrame" => top_row::op_resting_frame(request),
        "trafficLightsButtonX" => top_row::op_button_x(request),
        "windowedTrafficLights" => top_row::op_windowed_traffic_lights(request),
        // Zoom and targeting
        "zoomTarget" => zoom::op_target(request),
        "zoomBegin" => zoom::op_begin(request),
        "zoomEnd" => zoom::op_end(request),
        "zoomSame" => zoom::op_same(request),
        "target" => targeting::op_target(request),
        "cycled" => targeting::op_cycled(request),
        // Launch
        "launchDisplayParse" => launch::op_display_parse(request),
        "launchDisplayScreenIndex" => launch::op_display_screen_index(request),
        "launchSettle" => launch::op_settle(request),
        "launchSettleMarkName" => launch::op_mark_name(request),
        "launchRecordRequest" => launch::op_record_request(request),
        "frameStripKeyRepeat" => launch::op_key_repeat(request),
        // Diagnostics and debug probes
        "switchKeyChanges" => diagnostics::op_switch_key_changes(request),
        "syntheticScroll" => diagnostics::op_synthetic_scroll(request),
        "sweepSchedule" => diagnostics::op_sweep_schedule(request),
        "sweepFoundation" => diagnostics::op_sweep_foundation(request),
        "pointerMove" => diagnostics::op_pointer_move(request),
        "topAlignment" => diagnostics::op_top_alignment(request),
        // Surface fill
        "compensatedFill" => fill::op_compensated_fill(request),
        _ => Err(OpError::Unknown),
    }
}

/// Reads a request, runs `f`, writes its reply.
pub(crate) fn run<T: serde::de::DeserializeOwned, R: Serialize>(
    request: &Value,
    f: impl FnOnce(T) -> R,
) -> OpResult {
    let parsed: T = ops::parse(request)?;
    ops::reply(&f(parsed))
}
