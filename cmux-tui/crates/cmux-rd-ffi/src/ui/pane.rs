//! The viewer pane's rules (`MacScreenPane.swift`): whether the screen takes input, where the
//! toolbar, the screen, the card and the veil go, and what a session's phase change does. Swift
//! measures (the toolbar's height, the card's fitting size) and runs the effects. See `ui/mod.rs`.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{Answer, answer, args};

pub(crate) fn handle(name: &str, raw: &Value) -> Answer {
    Some(match name {
        "takesInput" => args::<InputArgs>(raw).and_then(|a| answer(&takes_input(&a))),
        "toolbarFrame" => args::<ToolbarArgs>(raw).and_then(|a| answer(&toolbar_frame(&a))),
        "screenRect" => args::<ScreenArgs>(raw).and_then(|a| answer(&screen_rect(&a))),
        "layout" => args::<LayoutArgs>(raw).and_then(|a| answer(&layout(&a))),
        "phaseChange" => args::<PhaseArgs>(raw).and_then(|a| answer(&phase_change(&a))),
        "displayRefresh" => args::<RefreshArgs>(raw).and_then(|a| answer(&display_refresh(&a))),
        "relayOnly" => args::<RelayArgs>(raw).and_then(|a| answer(&relay_only(&a))),
        "start" => args::<StartArgs>(raw).and_then(|a| answer(&start(&a))),
        "close" => args::<CloseArgs>(raw).and_then(|a| answer(&close(&a))),
        _ => return None,
    })
}

#[derive(Serialize, Debug, PartialEq, Clone, Copy, Default)]
pub(crate) struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct InputArgs {
    /// `MacScreenPaneModel.Gate`: "open" or "unsupported".
    gate: String,
    /// A live card shows over the screen.
    has_card: bool,
    #[serde(default)]
    view_only: bool,
}

/// Open, no card (live, with a picture), and not View Only.
fn takes_input(a: &InputArgs) -> bool {
    a.gate == "open" && !a.has_card && !a.view_only
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToolbarArgs {
    /// "topBar" or "floating".
    placement: String,
    width: f64,
    #[serde(default)]
    inset: f64,
    /// The toolbar's ``floatingWidth`` (floating only).
    #[serde(default)]
    floating_width: f64,
}

/// The toolbar's x, y and width (Swift measures its height at that width): a top bar spans the pane;
/// a floating bar is centred at its floating width, inset from the top.
fn toolbar_frame(a: &ToolbarArgs) -> Rect {
    if a.placement == "floating" {
        let width = (a.width - a.inset * 2.0).min(a.floating_width).max(0.0);
        Rect { x: (a.width - width) / 2.0, y: a.inset, width, height: 0.0 }
    } else {
        Rect { x: 0.0, y: 0.0, width: a.width, height: 0.0 }
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenArgs {
    placement: String,
    width: f64,
    height: f64,
    /// The toolbar's height (look B's strip's, or the toolbar's at its width).
    toolbar_height: f64,
}

/// Below a top bar; the whole pane under a floating one.
fn screen_rect(a: &ScreenArgs) -> Rect {
    let reserved = if a.placement == "topBar" { a.toolbar_height } else { 0.0 };
    Rect { x: 0.0, y: reserved, width: a.width, height: (a.height - reserved).max(0.0) }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LayoutArgs {
    screen: ScreenArgsInner,
    scale: Option<f64>,
    /// The session's `paneWidthPixels` now (nil: no session).
    pane_width_pixels: Option<i64>,
    picture_shadow: bool,
    /// The video's frame is empty (no picture).
    video_empty: bool,
    /// `layoutStatusStrip` answered show the card.
    strip_shows_card: bool,
    quiet_outage: bool,
    gate: String,
    card_veil_opacity: f64,
    /// The card's fitting size.
    #[serde(default)]
    card_width: f64,
    #[serde(default)]
    card_height: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ScreenArgsInner {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Layout {
    /// Set the session's `paneWidthPixels` to this (nil: leave it).
    #[serde(skip_serializing_if = "Option::is_none")]
    pane_width_pixels: Option<i64>,
    picture_shadow_hidden: bool,
    card_hidden: bool,
    capture_hidden: bool,
    /// The card's frame, centred on the screen and integral.
    #[serde(skip_serializing_if = "Option::is_none")]
    card: Option<Rect>,
    veil_hidden: bool,
}

/// `CGRect.integral`: the smallest whole rect holding it.
fn integral(x: f64, y: f64, width: f64, height: f64) -> Rect {
    let (x0, y0) = (x.floor(), y.floor());
    Rect { x: x0, y: y0, width: (x + width).ceil() - x0, height: (y + height).ceil() - y0 }
}

/// Auto streams at the pane's width in pixels; the card shows centred unless the outage is quiet;
/// the veil dims a picture only under a card.
fn layout(a: &LayoutArgs) -> Layout {
    let pixels = (a.screen.width * a.scale.unwrap_or(2.0)).ceil() as i64;
    let pane_width_pixels = match a.pane_width_pixels {
        Some(now) if pixels > 0 && now != pixels => Some(pixels),
        _ => None,
    };
    let shows_card = a.strip_shows_card && !a.quiet_outage;
    let s = &a.screen;
    let card = shows_card.then(|| {
        let (mid_x, mid_y) = (s.x + s.width / 2.0, s.y + s.height / 2.0);
        integral(
            mid_x - a.card_width / 2.0,
            mid_y - a.card_height / 2.0,
            a.card_width,
            a.card_height,
        )
    });
    Layout {
        pane_width_pixels,
        picture_shadow_hidden: !a.picture_shadow || a.video_empty,
        card_hidden: !shows_card,
        capture_hidden: a.gate != "open",
        card,
        veil_hidden: !shows_card || a.card_veil_opacity <= 0.0 || a.video_empty,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PhaseArgs {
    /// The session's phase: connecting, connected, failed, ended.
    phase: String,
    /// The hub streams a scope now.
    hub_streaming: bool,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct PhaseEffects {
    /// Set `everConnected`.
    ever_connected: bool,
    /// Clear `hasFrame` (no picture until the next frame).
    clear_frame: bool,
    stop_recording: bool,
    /// Tell the hub its stream failed.
    hub_stream_failed: bool,
}

/// What a session phase change does (Swift then tells the hub whether it stalls and lays out again).
fn phase_change(a: &PhaseArgs) -> PhaseEffects {
    let connected = a.phase == "connected";
    let failed = a.phase == "failed";
    PhaseEffects {
        ever_connected: connected,
        clear_frame: !connected,
        stop_recording: failed || a.phase == "ended",
        hub_stream_failed: failed && a.hub_streaming,
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RefreshArgs {
    fps: Option<i64>,
    has_session: bool,
    /// The session's `displayMaximumFrameRate`.
    session_fps: Option<i64>,
}

/// The display's rate to tell the session, or nil: no rate, no session, or the same.
fn display_refresh(a: &RefreshArgs) -> Option<i64> {
    let fps = a.fps.filter(|f| *f > 0)?;
    (a.has_session && a.session_fps != Some(fps)).then_some(fps)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayArgs {
    on: bool,
    /// The session's `relayOnly` (nil: no session).
    session_relay_only: Option<bool>,
    hub_streaming: bool,
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
struct RelayEffects {
    set: bool,
    /// Ask the hub again for the streaming scope (a ticket admits once).
    rerequest: bool,
}

fn relay_only(a: &RelayArgs) -> RelayEffects {
    let set = a.session_relay_only.is_some_and(|now| now != a.on);
    RelayEffects { set, rerequest: set && a.hub_streaming }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartArgs {
    /// The hub's phase name (nil: no hub).
    hub_phase: Option<String>,
    /// The hub's waiting scope.
    resume_scope: Option<String>,
}

/// The scope to request now (Swift clears `resumeScope` and asks), or nil.
fn start(a: &StartArgs) -> Option<String> {
    if a.hub_phase.as_deref() != Some("idle") {
        return None;
    }
    a.resume_scope.clone()
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CloseArgs {
    hub_phase: Option<String>,
}

/// Closing the tab: `hub` (the hub hears why, then the stream closes) or `session` (close it now).
fn close(a: &CloseArgs) -> &'static str {
    match a.hub_phase.as_deref() {
        Some(phase) if phase != "idle" => "hub",
        _ => "session",
    }
}

#[cfg(test)]
#[path = "pane_tests.rs"]
mod tests;
