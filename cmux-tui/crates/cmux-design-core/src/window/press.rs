//! Press routing: `WindowPressRouter`'s key-neutral press, `FullScreenTitlebarPress`,
//! `ResizeBands`, `KeyWindowRepaint.showsFocus` and `FocusRoute`'s description.
//!
//! The app hit-tests and delivers; these decide who gets the press. Windows and views are ids.

use super::{EventKind, Point, Rect, run};
use crate::ops::OpResult;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `WindowPressRouter`'s state: the view that took a key-neutral press, and whether one is claimed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyNeutralState {
    #[serde(default)]
    pub pressed: Option<u64>,
    #[serde(default)]
    pub claimed: bool,
}

/// What the app read for a left mouse down in a window that is not key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyNeutralFacts {
    pub app_is_active: bool,
    pub app_is_modal: bool,
    pub window: u64,
    pub window_is_key: bool,
    pub window_has_attached_sheet: bool,
    #[serde(default)]
    pub key_window: Option<u64>,
    #[serde(default)]
    pub key_window_has_sheet_parent: bool,
    /// [`is_page`] for the key window and this window.
    pub key_window_is_page: bool,
    /// The hit view's nearest `KeyNeutralPressTarget` ancestor, when it keeps the key for this press.
    #[serde(default)]
    pub target: Option<u64>,
}

/// What the router does with one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyNeutralOutcome {
    /// The router took the event (AppKit does not send it on).
    pub routed: bool,
    /// The view to hand the event to (`mouseDown`, `mouseDragged`, `mouseUp` or `pressureChange` by kind).
    pub deliver_to: Option<u64>,
}

impl KeyNeutralState {
    /// One event. `facts` matters only for a left mouse down; `pressed_is_live` says whether the
    /// pressed view is still in this window (drag, up, pressure).
    pub fn step(
        &mut self,
        kind: EventKind,
        facts: &KeyNeutralFacts,
        pressed_is_live: bool,
    ) -> KeyNeutralOutcome {
        let live = if pressed_is_live { self.pressed } else { None };
        match kind {
            EventKind::LeftMouseDown => {
                self.pressed = None;
                self.claimed = false;
                let f = facts;
                let takes = f.app_is_active
                    && !f.app_is_modal
                    && !f.window_is_key
                    && !f.window_has_attached_sheet
                    && f.key_window.is_some_and(|k| k != f.window)
                    && !f.key_window_has_sheet_parent
                    && f.key_window_is_page;
                match (takes, f.target) {
                    (true, Some(view)) => {
                        self.pressed = Some(view);
                        self.claimed = true;
                        KeyNeutralOutcome { routed: true, deliver_to: Some(view) }
                    }
                    _ => KeyNeutralOutcome::default(),
                }
            }
            EventKind::LeftMouseDragged | EventKind::Pressure => {
                if !self.claimed {
                    return KeyNeutralOutcome::default();
                }
                KeyNeutralOutcome { routed: true, deliver_to: live }
            }
            EventKind::LeftMouseUp => {
                if !self.claimed {
                    return KeyNeutralOutcome::default();
                }
                self.pressed = None;
                self.claimed = false;
                KeyNeutralOutcome { routed: true, deliver_to: live }
            }
            _ => KeyNeutralOutcome::default(),
        }
    }
}

/// A window on the key window's parent chain.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChainWindow {
    pub id: u64,
    /// `WindowOverlayHost.isPageWindow`.
    pub is_page: bool,
    #[serde(default)]
    pub parent: Option<u64>,
}

/// Whether `key_window` is a page window (through page windows only) of `window`.
pub fn is_page(key_window: u64, window: u64, chain: &[ChainWindow]) -> bool {
    let find = |id: u64| chain.iter().find(|w| w.id == id);
    let mut current = key_window;
    for _ in 0..=chain.len() {
        let Some(link) = find(current) else { return false };
        let Some(parent) = link.parent else { return false };
        if !link.is_page {
            return false;
        }
        if parent == window {
            return true;
        }
        current = parent;
    }
    false
}

/// `FullScreenTitlebarPress`'s state: the covered window's button held, and the titlebar window pressed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FullScreenTitlebarState {
    #[serde(default)]
    pub pressed: Option<u64>,
    #[serde(default)]
    pub source: Option<u64>,
}

/// What the full-screen titlebar press does with one event.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FullScreenTitlebarOutcome {
    pub taken: bool,
    /// The button to `performClick`.
    pub click: Option<u64>,
}

impl FullScreenTitlebarState {
    /// One event in `window` (none: not taken). `button_under` is [`full_screen_titlebar_button`] at the event.
    pub fn step(
        &mut self,
        kind: EventKind,
        window: Option<u64>,
        button_under: Option<u64>,
    ) -> FullScreenTitlebarOutcome {
        let Some(window) = window else { return FullScreenTitlebarOutcome::default() };
        match kind {
            EventKind::LeftMouseDown => {
                self.pressed = None;
                self.source = None;
                let Some(button) = button_under else {
                    return FullScreenTitlebarOutcome::default();
                };
                self.pressed = Some(button);
                self.source = Some(window);
                FullScreenTitlebarOutcome { taken: true, click: None }
            }
            EventKind::LeftMouseDragged => FullScreenTitlebarOutcome {
                taken: self.source == Some(window) && self.pressed.is_some(),
                click: None,
            },
            EventKind::LeftMouseUp => {
                let (Some(button), true) = (self.pressed, self.source == Some(window)) else {
                    return FullScreenTitlebarOutcome::default();
                };
                self.pressed = None;
                self.source = None;
                FullScreenTitlebarOutcome {
                    taken: true,
                    click: (button_under == Some(button)).then_some(button),
                }
            }
            _ => FullScreenTitlebarOutcome::default(),
        }
    }
}

/// A button the covered full-screen window has under the press.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoveredButton {
    pub id: u64,
    pub enabled: bool,
    /// `isHiddenOrHasHiddenAncestor`.
    pub hidden: bool,
}

/// The covered window's button a titlebar press means: only when the titlebar window covers a
/// full-screen window, has no control of its own there, and the button is enabled and shown.
pub fn full_screen_titlebar_button(
    covers: bool,
    titlebar_has_control: bool,
    button: Option<CoveredButton>,
) -> Option<u64> {
    if !covers || titlebar_has_control {
        return None;
    }
    button.filter(|b| b.enabled && !b.hidden).map(|b| b.id)
}

/// A registered resize band: its window, whether it is hidden, its frame in window points.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResizeBand {
    pub window: u64,
    pub hidden: bool,
    pub frame: Rect,
}

/// Whether a resize band of `window` claims the window point.
pub fn resize_bands_claim(bands: &[ResizeBand], window: u64, point: Point) -> bool {
    bands.iter().any(|b| b.window == window && !b.hidden && b.frame.contains(point))
}

/// `KeyWindowRepaint.showsFocus`: focus shows only in the key window (no window: shows).
pub fn shows_focus(focused: bool, window_is_key: Option<bool>) -> bool {
    focused && window_is_key.unwrap_or(true)
}

/// Who asked for a focus move.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FocusOrigin {
    Person,
    System,
}

impl FocusOrigin {
    pub fn raw(self) -> &'static str {
        match self {
            FocusOrigin::Person => "person",
            FocusOrigin::System => "system",
        }
    }
}

/// `FocusRoute.description`: `origin file:line reason`.
pub fn focus_route_description(origin: FocusOrigin, reason: &str, file: &str, line: u64) -> String {
    format!("{} {file}:{line} {reason}", origin.raw())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct KeyNeutralRequest {
    #[serde(default)]
    state: KeyNeutralState,
    kind: EventKind,
    #[serde(default)]
    facts: KeyNeutralFacts,
    #[serde(default)]
    pressed_is_live: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct KeyNeutralReply {
    state: KeyNeutralState,
    #[serde(flatten)]
    outcome: KeyNeutralOutcome,
}

/// `window.keyNeutralStep` `{state?, kind, facts?, pressedIsLive?}` → `{state, routed, deliverTo}`.
pub(super) fn op_key_neutral_step(request: &Value) -> OpResult {
    run(request, |r: KeyNeutralRequest| {
        let mut state = r.state;
        let outcome = state.step(r.kind, &r.facts, r.pressed_is_live);
        KeyNeutralReply { state, outcome }
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IsPageRequest {
    key_window: u64,
    window: u64,
    chain: Vec<ChainWindow>,
}

/// `window.isPage` `{keyWindow, window, chain}` → bool.
pub(super) fn op_is_page(request: &Value) -> OpResult {
    run(request, |r: IsPageRequest| is_page(r.key_window, r.window, &r.chain))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FullScreenRequest {
    #[serde(default)]
    state: FullScreenTitlebarState,
    kind: EventKind,
    #[serde(default)]
    window: Option<u64>,
    #[serde(default)]
    button_under: Option<u64>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct FullScreenReply {
    state: FullScreenTitlebarState,
    #[serde(flatten)]
    outcome: FullScreenTitlebarOutcome,
}

/// `window.fullScreenTitlebarStep` `{state?, kind, window?, buttonUnder?}` → `{state, taken, click}`.
pub(super) fn op_full_screen_step(request: &Value) -> OpResult {
    run(request, |r: FullScreenRequest| {
        let mut state = r.state;
        let outcome = state.step(r.kind, r.window, r.button_under);
        FullScreenReply { state, outcome }
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FullScreenButtonRequest {
    covers: bool,
    titlebar_has_control: bool,
    #[serde(default)]
    button: Option<CoveredButton>,
}

/// `window.fullScreenTitlebarButton` `{covers, titlebarHasControl, button?}` → id or null.
pub(super) fn op_full_screen_button(request: &Value) -> OpResult {
    run(request, |r: FullScreenButtonRequest| {
        full_screen_titlebar_button(r.covers, r.titlebar_has_control, r.button)
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ResizeBandsRequest {
    bands: Vec<ResizeBand>,
    window: u64,
    point: Point,
}

/// `window.resizeBandsClaim` `{bands, window, point}` → bool.
pub(super) fn op_resize_bands_claim(request: &Value) -> OpResult {
    run(request, |r: ResizeBandsRequest| resize_bands_claim(&r.bands, r.window, r.point))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShowsFocusRequest {
    focused: bool,
    #[serde(default)]
    window_is_key: Option<bool>,
}

/// `window.showsFocus` `{focused, windowIsKey?}` → bool.
pub(super) fn op_shows_focus(request: &Value) -> OpResult {
    run(request, |r: ShowsFocusRequest| shows_focus(r.focused, r.window_is_key))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FocusRouteRequest {
    origin: FocusOrigin,
    reason: String,
    file: String,
    line: u64,
}

/// `window.focusRouteDescription` `{origin, reason, file, line}` → string.
pub(super) fn op_focus_route_description(request: &Value) -> OpResult {
    run(request, |r: FocusRouteRequest| {
        focus_route_description(r.origin, &r.reason, &r.file, r.line)
    })
}
