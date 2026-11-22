//! The platform seam. One implementation per desktop (macOS, Windows, X11,
//! Wayland); tests use [`crate::desktop::fake::FakeDesktop`].
//!
//! Rules every implementation keeps (lessons from cua-driver, which we
//! pin only as the eval baseline):
//!
//! 1. Window-scoped: every mutation names `(app, window)`; the result's
//!    evidence must come from that window, never a sibling of the same app.
//! 2. Background-first: never activate an app, raise a window, switch a
//!    Space or move the person's pointer. Order of routes: semantic
//!    accessibility action, then events delivered to the target process or
//!    window, and only with `Delivery::Foreground` (asked for explicitly) a
//!    system-wide event.
//! 3. Refuse rather than guess: a target that cannot be resolved returns
//!    [`DesktopError::TargetNotFound`] or [`DesktopError::Unsupported`]
//!    before any input is sent.
//! 4. Coordinates are global desktop points, top-left origin (macOS points,
//!    X11 root pixels, Windows virtual-screen pixels of a per-monitor DPI
//!    aware process). The engine maps the agent's screenshot pixels to them
//!    ([`crate::frame::Geometry`]).

use serde::{Deserialize, Serialize};

/// What the desktop reports about itself.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct PlatformInfo {
    /// `macos`, `windows`, `linux`.
    pub os: String,
    /// `quartz`, `win32`, `x11`, `wayland-portal`, `wayland-wlroots`, `headless-x11`.
    pub display_server: String,
    /// Free text: OS version, desktop environment, compositor.
    pub detail: String,
}

/// The OS grants Computer Use needs, as the desktop sees them now.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
pub struct Permissions {
    pub accessibility: Grant,
    pub screen_capture: Grant,
    pub input: Grant,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Grant {
    Granted,
    Denied,
    #[default]
    NotNeeded,
    Unknown,
}

/// A running app. `id` is the stable identity policy matches on: the bundle
/// id on macOS, the executable file name on Windows, the desktop file id or
/// WM_CLASS on Linux.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct App {
    pub id: String,
    pub name: String,
    pub pid: u32,
    #[serde(default)]
    pub frontmost: bool,
    #[serde(default)]
    pub hidden: bool,
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub fn intersects(&self, other: &Rect) -> bool {
        self.x < other.x + other.width
            && other.x < self.x + self.width
            && self.y < other.y + other.height
            && other.y < self.y + self.height
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A top-level window. `id` is the platform window id (CGWindowID, HWND,
/// X11 window, portal stream node) as a string.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct Window {
    pub id: String,
    pub app_id: String,
    pub pid: u32,
    pub title: String,
    /// In global desktop points.
    pub frame: Rect,
    #[serde(default)]
    pub on_screen: bool,
    #[serde(default)]
    pub focused: bool,
    #[serde(default)]
    pub minimized: bool,
}

/// What a screenshot covers.
#[derive(Clone, Debug, PartialEq)]
pub enum CaptureTarget {
    /// One window, even when covered by others (where the platform can).
    Window(String),
    /// One display (`None`: the main one).
    Display(Option<String>),
}

/// Raw pixels from the desktop. The engine owns encoding (see [`crate::frame`]).
#[derive(Clone, Debug)]
pub struct RawFrame {
    pub width: u32,
    pub height: u32,
    /// Tightly packed RGBA8, `width * height * 4` bytes.
    pub rgba: Vec<u8>,
    /// Pixels per desktop point (2.0 on a Retina display).
    pub scale: f64,
    /// Where the frame's top-left is, in global desktop points.
    pub origin: Point,
}

/// One accessibility node. `id` is valid for the window's current tree
/// generation; a stale id gives [`DesktopError::StaleElement`]. The engine
/// gives agents small ids that stay the same across trees of a window
/// ([`crate::observe`]) and maps them back to these.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct Element {
    pub id: String,
    pub role: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub value: String,
    /// In global desktop points (the engine rewrites it to screenshot pixels).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub frame: Option<Rect>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub actions: Vec<String>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub focused: bool,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub disabled: bool,
    /// The app's own name for the element (macOS AXIdentifier, Windows
    /// AutomationId), when it has one.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub identifier: String,
    /// A menu item's keyboard shortcut as press_key takes it (`cmd+shift+s`).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub shortcut: String,
    /// A menu item shows a check mark (or another mark).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub checked: bool,
    /// A row, tab or item is selected.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub selected: bool,
    /// The platform's identity for the element, equal across two trees of a
    /// window exactly when it is the same element (macOS: the AXUIElement's
    /// hash; Linux: its AT-SPI object). The engine matches elements by it to
    /// keep their ids; never sent.
    #[serde(skip)]
    pub identity: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub children: Vec<Element>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct UiTree {
    pub window_id: String,
    pub root: Element,
    /// True when the walk hit `max_nodes` or `max_depth`.
    #[serde(default)]
    pub truncated: bool,
}

/// What the policy says about an app a menu item would open or hand data to.
pub trait MenuGuard: Send + Sync {
    /// The app (bundle id and/or name) is protected or on the deny list.
    fn app_blocked(&self, id: &str, name: &str) -> bool;
    /// Any app at all is denied (an item whose app cannot be told is then refused).
    fn denies_any(&self) -> bool;
    /// The bundle ids the guard blocks (the deny list's exact and `prefix*`
    /// entries, and the protected apps), for naming them before the full
    /// app-name index is built. `name:` entries are names already.
    fn blocked_ids(&self) -> Vec<String> {
        Vec::new()
    }
}

#[derive(Clone, Copy, Debug)]
pub struct TreeOptions {
    pub max_nodes: usize,
    pub max_depth: usize,
    /// Add the app's menu bar after the window (macOS), within max_nodes.
    /// Off for the state an action returns.
    pub menus: bool,
}

impl Default for TreeOptions {
    fn default() -> Self {
        Self { max_nodes: 1500, max_depth: 30, menus: true }
    }
}

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Button {
    #[default]
    Left,
    Right,
    Middle,
}

/// How input reaches the target.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Delivery {
    /// Never take focus or move the person's pointer (the default).
    #[default]
    Background,
    /// System-wide events, raising the window first. Only when asked for,
    /// and only when the policy allows it (it can disturb the person).
    Foreground,
}

/// Where a pointer action lands: an element, or a point in the window.
#[derive(Clone, Debug, PartialEq)]
pub enum PointerTarget {
    Element { window_id: String, element_id: String },
    Point { window_id: String, point: Point },
}

impl PointerTarget {
    pub fn window_id(&self) -> &str {
        match self {
            PointerTarget::Element { window_id, .. } | PointerTarget::Point { window_id, .. } => {
                window_id
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClickSpec {
    pub button: Button,
    pub count: u8,
    pub modifiers: Vec<crate::keys::Modifier>,
    pub delivery: Delivery,
    /// Between the clicks of a double or triple click (Anthropic's reference
    /// tool: 10 ms; zero: back to back).
    pub gap: std::time::Duration,
    /// For a click that opens a menu (a right click or control-click, a
    /// pop-up or menu button): the title of the item to choose. The menu
    /// opens, the item is pressed and the menu closes in this one call, so
    /// it is never left open.
    pub menu_item: Option<String>,
}

/// What an action did, as far as the desktop could tell.
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct ActionOutcome {
    /// The route used: `ax_press`, `ax_set_value`, `pid_event`, `window_message`,
    /// `xtest`, `uia_invoke`, `send_input`, `libei`, ...
    pub route: String,
    /// `confirmed` when the target's own state shows the effect,
    /// `delivered` when the input was delivered but not verified,
    /// `no_visible_change` when the engine watched the window through a real
    /// settle wait and nothing it shows (or of the app's windows) changed.
    pub evidence: String,
    /// Where the agent cursor should be drawn (global points), when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor_at: Option<Point>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub note: String,
    /// The menu the action opened, picked from or cancelled ([`crate::menus`]).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub menu: Option<crate::menus::MenuReport>,
    /// Where the intended effect must show when it happens, so seeing
    /// nothing there means it did not: `value` (the element's value),
    /// `selection`, `text` (typed into a text element), `scroll`. `None`: the
    /// effect may not show at all (a button, a menu item, a chord, a click on
    /// a canvas), so seeing nothing proves nothing. The engine reads it to
    /// decide the outcome and drops it from the result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows: Option<String>,
    /// A read-back of the intended effect the platform can do once the
    /// action has settled ([`Desktop::read_back`]): typed keys and scrolls
    /// land a little after they are posted. The engine drops it from the
    /// result.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expect: Option<Expect>,
}

/// A pending read-back ([`ActionOutcome::expect`]): the platform's handle
/// and what it checks (`text`: the typed text is in the element's value;
/// `scroll`: the scrolled view moved).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Expect {
    pub token: u64,
    pub what: String,
    /// The state already matched before the action (the caret was there,
    /// everything was selected, the value was the one asked for).
    #[serde(default)]
    pub already: bool,
    /// The intended change the read-back checks: the state before the
    /// action, read when the check was built, and the state wanted. The
    /// engine confirms only a change: `before != wanted`.
    #[serde(default)]
    pub before: String,
    #[serde(default)]
    pub wanted: String,
}

impl Expect {
    /// Whether the read-back states a change (its wanted state did not
    /// already hold before the action).
    pub fn states_change(&self) -> bool {
        !self.already && self.before != self.wanted
    }
}

impl ActionOutcome {
    pub fn delivered(route: &str) -> Self {
        Self { route: route.into(), evidence: "delivered".into(), ..Self::default() }
    }
    pub fn confirmed(route: &str) -> Self {
        Self { route: route.into(), evidence: "confirmed".into(), ..Self::default() }
    }
    pub fn at(mut self, point: Point) -> Self {
        self.cursor_at = Some(point);
        self
    }
    /// Where the intended effect must show ([`Self::shows`]).
    pub fn showing(mut self, place: &str) -> Self {
        self.shows = Some(place.into());
        self
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum DesktopError {
    /// The OS grant is missing (`accessibility`, `screen_capture`, `input`).
    PermissionMissing(String),
    TargetNotFound(String),
    StaleElement(String),
    /// The platform cannot do this safely here (for example a raw key to a
    /// multi-window app in the background). Says what would work instead.
    Unsupported(String),
    Failed(String),
    /// The screen is locked, so the call did nothing ([`crate::locked`]).
    Locked(String),
}

impl std::fmt::Display for DesktopError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DesktopError::PermissionMissing(p) => write!(f, "the {p} permission is not granted"),
            DesktopError::TargetNotFound(t) => write!(f, "not found: {t}"),
            DesktopError::StaleElement(e) => {
                write!(f, "element {e} is stale; call get_ui_tree again")
            }
            DesktopError::Unsupported(m) => write!(f, "unsupported: {m}"),
            DesktopError::Failed(m) | DesktopError::Locked(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for DesktopError {}

impl DesktopError {
    pub fn code(&self) -> &'static str {
        match self {
            DesktopError::PermissionMissing(_) => "permission_missing",
            DesktopError::TargetNotFound(_) => "target_not_found",
            DesktopError::StaleElement(_) => "stale_element",
            DesktopError::Unsupported(_) => "unsupported",
            DesktopError::Failed(_) => "failed",
            DesktopError::Locked(_) => crate::locked::CODE,
        }
    }
}

pub type DResult<T> = Result<T, DesktopError>;

/// Where the person's focus is: the frontmost app, its key window and the
/// top app window on screen. The engine takes one before every acting call
/// and compares it after acting and after settling ([`Desktop::focus_snapshot`]).
#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
pub struct FocusSnapshot {
    /// The frontmost app's pid (where the person's keys go).
    pub pid: u32,
    /// Its policy identity (bundle id, `.exe` name, desktop id).
    pub app_id: String,
    /// The frontmost app's key window (platform window id), when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window_id: Option<String>,
    /// The pid owning the top normal window on screen, when known: an app
    /// that orders a window above the person's without activating shows here.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_pid: Option<u32>,
    /// The person's pointer (global points), when known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pointer: Option<Point>,
}

/// Accessibility signals an app sent while an action ran and settled: what
/// changed by the app's own account (a value, a title, a selection, focus, a
/// window or sheet, a menu), counted in the target window and elsewhere
/// (another window, a menu, a popover, the app itself).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Signals {
    /// Signals from elements of the target window.
    pub in_window: u32,
    /// Signals from anywhere else in the app.
    pub elsewhere: u32,
    /// Count per notification name (`AXValueChanged`, ...).
    pub kinds: std::collections::BTreeMap<String, u32>,
    /// When the last one came, ms after the watch started.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_ms: Option<u64>,
    /// How long ago the last one came, ms (when the signals were read).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub since_last_ms: Option<u64>,
}

impl Signals {
    pub fn total(&self) -> u32 {
        self.in_window + self.elsewhere
    }
}

/// [`World::changes_since`]'s words for a new front app.
pub const FRONT_APP_CHANGED: &str = "the front app changed";

/// What outside the target window could show an action's effect, read before
/// and after it: the on-screen windows of every process (a window, panel,
/// menu or another app it opened), the pasteboard (a copy) and the front app.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct World {
    pub windows: Vec<String>,
    pub pasteboard: Option<i64>,
    pub front_pid: Option<u32>,
}

impl World {
    /// What changed from `before` to `self`, in words (empty: nothing).
    pub fn changes_since(&self, before: &World) -> Vec<String> {
        let mut out = Vec::new();
        let opened = self.windows.iter().filter(|w| !before.windows.contains(w)).count();
        let closed = before.windows.iter().filter(|w| !self.windows.contains(w)).count();
        if opened > 0 {
            out.push(format!("{opened} window(s) opened on screen"));
        }
        if closed > 0 {
            out.push(format!("{closed} window(s) closed"));
        }
        if self.pasteboard != before.pasteboard {
            out.push("the pasteboard changed".into());
        }
        if self.front_pid != before.front_pid {
            out.push(FRONT_APP_CHANGED.into());
        }
        out
    }
}

/// A watch on an app's accessibility signals; stops when dropped.
pub trait Watch: Send {
    /// The signals so far.
    fn signals(&self) -> Signals;
    /// Whether the watch is really listening (the app took the observer).
    fn listening(&self) -> bool;
    /// Blocks until the app sends a signal past `seen` (a [`Signals::total`])
    /// or `limit` passes; true when one came. The default cannot block and
    /// answers at once, so a caller sleeps the rest itself.
    fn wait_for_signal(&self, _seen: u32, _limit: std::time::Duration) -> bool {
        false
    }
}

/// One desktop. Calls block; the engine runs them off any UI thread.
pub trait Desktop: Send + Sync {
    fn info(&self) -> PlatformInfo;
    fn permissions(&self) -> Permissions;
    /// Whether the session's screen is locked now (macOS: the lock screen or
    /// a display that dimmed into it). The engine reads it before every call
    /// ([`crate::locked`]); a desktop with no lock screen says false.
    fn screen_locked(&self) -> bool {
        false
    }
    fn list_apps(&self) -> DResult<Vec<App>>;
    /// All top-level windows (the engine filters by app and policy).
    fn list_windows(&self) -> DResult<Vec<Window>>;
    /// One window by id, `None` when there is none: what most calls need,
    /// without reading every window. The default filters [`Self::list_windows`].
    fn window(&self, id: &str) -> DResult<Option<Window>> {
        Ok(self.list_windows()?.into_iter().find(|w| w.id == id))
    }
    /// The ids of the on-screen windows over `frame`, from any process:
    /// sheets, panels and popovers included where the platform lists them,
    /// one served by another process too (to tell whether an action opened
    /// one). The default filters [`Self::list_windows`].
    fn window_ids_over(&self, frame: &Rect) -> DResult<Vec<String>> {
        let mut ids: Vec<String> = self
            .list_windows()?
            .into_iter()
            .filter(|w| w.on_screen && !w.minimized && w.frame.intersects(frame))
            .map(|w| w.id)
            .collect();
        ids.sort();
        Ok(ids)
    }
    /// Starts watching the app of `window_id` for accessibility signals
    /// ([`Signals`]) until the returned watch is dropped. `None`: the
    /// platform cannot watch (then nothing is known about effects outside the
    /// window's pixels and elements).
    fn watch(&self, _window_id: &str) -> Option<Box<dyn Watch>> {
        None
    }
    /// The [`World`] now; `None` when the platform cannot read it.
    fn world(&self) -> Option<World> {
        None
    }
    /// Reads back an action's intended effect after it settled
    /// ([`ActionOutcome::expect`]), once: `Some(true)` it shows, `Some(false)`
    /// it does not (yet), `None` unknown.
    fn read_back(&self, _expect: &Expect) -> Option<bool> {
        None
    }
    /// Reads `expect`'s check now and keeps it for a later
    /// [`Self::read_back`] (a batch step: right after the step, then after
    /// the batch's settle). `None`: unreadable.
    fn peek_back(&self, _expect: &Expect) -> Option<bool> {
        None
    }
    /// Whether the app of `window_id` answers an accessibility request now
    /// (a stalled app shows nothing new because it does nothing at all).
    /// `None`: unknown.
    fn responsive(&self, _window_id: &str) -> Option<bool> {
        None
    }
    /// Whether the app of `window` is the frontmost app (where the person's
    /// keys go). The default looks it up in [`Self::list_apps`].
    fn is_frontmost_app(&self, window: &Window) -> bool {
        self.list_apps()
            .map(|apps| apps.iter().any(|a| a.pid == window.pid && a.frontmost))
            .unwrap_or(true)
    }
    /// Where the person's pointer is now (global points), when the desktop
    /// can tell.
    fn pointer(&self) -> Option<Point> {
        None
    }
    /// The name the person knows the app of `window` by, when known. The
    /// default looks it up in [`Self::list_apps`].
    fn app_name(&self, window: &Window) -> Option<String> {
        let apps = self.list_apps().ok()?;
        apps.into_iter().find(|a| a.id.eq_ignore_ascii_case(&window.app_id)).map(|a| a.name)
    }
    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame>;
    /// Whether a window capture holds only that window's own pixels, never a
    /// window drawn over it. When false (a composited crop of the screen), the
    /// engine paints denied windows that overlap the target out of the shot.
    fn window_capture_isolated(&self) -> bool {
        false
    }
    /// Whether a display capture can leave out whole processes' windows (the
    /// compositor draws what is behind them), so denied apps need no painting.
    fn excludes_apps_from_display_capture(&self) -> bool {
        false
    }
    /// A display capture without the windows of `exclude_pids`, at every
    /// window level. Only when [`Desktop::excludes_apps_from_display_capture`].
    fn capture_display_excluding(
        &self,
        _display: Option<&str>,
        _exclude_pids: &[u32],
    ) -> DResult<RawFrame> {
        Err(DesktopError::Unsupported("this desktop cannot leave apps out of a capture".into()))
    }
    /// The apps a display capture sees, from the capture system itself (every
    /// app with a window at any level), for [`Desktop::capture_display_excluding`].
    fn capture_apps(&self) -> DResult<Vec<App>> {
        Err(DesktopError::Unsupported("this desktop lists no capture apps".into()))
    }
    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree>;
    /// The policy's view of apps that menu items could open or hand data to
    /// (Recent Items, Open With, Services); the engine sets it once.
    fn set_menu_guard(&self, _guard: std::sync::Arc<dyn MenuGuard>) {}
    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome>;
    /// Types `text` into the window's focused element (or `element_id`).
    fn type_text(
        &self,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> DResult<ActionOutcome>;
    fn press_keys(
        &self,
        window_id: &str,
        combo: &crate::keys::KeyCombo,
        delivery: Delivery,
    ) -> DResult<ActionOutcome>;
    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome>;
    fn drag(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        button: Button,
        delivery: Delivery,
    ) -> DResult<ActionOutcome>;
    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome>;
    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome>;
    /// Starts an app without bringing it to the front where the platform allows.
    fn launch_app(&self, app_id: &str) -> DResult<App>;
    /// Every app identity `launch_app(app_id)` could start, as policy matches
    /// them (the resolved bundle id, `.exe` name or desktop-file id), so a
    /// launch is checked against what would really run, never only against
    /// the agent's words. The first is the app's own id (approvals are saved
    /// under it). Refuses an id the platform would not launch.
    fn launch_identities(&self, app_id: &str) -> DResult<Vec<String>> {
        Ok(vec![app_id.to_string()])
    }
    /// Whether launch_app takes one of launch_identities' answers as is (macOS:
    /// a bundle id), so the engine launches exactly what policy checked.
    fn launches_by_identity(&self) -> bool {
        false
    }
    /// Asks the OS for a missing grant (shows the OS prompt or settings pane).
    fn request_permission(&self, _which: &str) -> DResult<()> {
        Err(DesktopError::Unsupported("this desktop has no permission prompt".into()))
    }
    /// Where the person's focus is now, or `None` when the desktop cannot
    /// tell (the focus guard then stays out of the way).
    fn focus_snapshot(&self) -> Option<FocusSnapshot> {
        None
    }
    /// Puts the person's focus back as `prior` had it: their app frontmost,
    /// its key window key and in front of any window an action raised. Only
    /// the engine's focus guard calls it, and only for a change the person
    /// did not make. True when the focus reads back as `prior`.
    fn restore_focus(&self, _prior: &FocusSnapshot) -> DResult<bool> {
        Ok(false)
    }
    /// The menu setting and the deny list's app names, before every acting
    /// call ([`crate::menus`]). A desktop that opens no menus ignores it.
    fn set_menu_policy(&self, _policy: crate::menus::MenuPolicy) {}

    /// Whether windows have title bars the desktop draws (macOS), where a
    /// background click does nothing; elsewhere (Wayland's client-side
    /// decorations, custom frames) the top of a window may be the app's own.
    fn draws_title_bars(&self) -> bool {
        false
    }

    /// Whether `click` can open a menu, choose `ClickSpec::menu_item` and
    /// close it in one call.
    fn picks_menu_items(&self) -> bool {
        false
    }
}

pub mod fake;

/// Pixels and OS prompts from the process that hosts the engine, where the
/// platform's capture API lives outside Rust (ScreenCaptureKit in the macOS
/// worker).
pub trait HostServices: Send + Sync {
    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame>;
    /// A display capture without the windows of `exclude_pids` (ScreenCaptureKit's
    /// application filter in the macOS worker).
    fn capture_display_excluding(
        &self,
        _display: Option<&str>,
        _exclude_pids: &[u32],
    ) -> DResult<RawFrame> {
        Err(DesktopError::Unsupported("the host cannot leave apps out of a capture".into()))
    }
    /// Every app the capture sees (any window, any level).
    fn capture_apps(&self) -> DResult<Vec<App>> {
        Err(DesktopError::Unsupported("the host lists no capture apps".into()))
    }
    fn request_permission(&self, which: &str) -> DResult<()>;
    /// Screen Recording as this host reads it, or None to leave the read to the engine. The
    /// macOS worker reads it in a fresh process when its own answer is no, because a running
    /// process keeps an old denial after the person grants it in System Settings.
    fn screen_capture_granted(&self) -> Option<bool> {
        None
    }
}
