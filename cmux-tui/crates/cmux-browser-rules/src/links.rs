//! Where a link opens, for both engines.
//!
//! Ported 1:1 from the app's Swift (`CmuxNextBrowser`): `BrowserLinkGesture`, `BrowserLinkAction`
//! and `BrowserLinkClickMapping` (Core/BrowserLinkClicks.swift), `CEFLinkClicks.placement`
//! (CEF/CEFLinkClicks.swift) and `CEFWindowPolicy` (CEF/CEFWindowPolicy.swift). Swift keeps the
//! event reading and the engines; these are the decisions.
//!
//! The wire is the shape Swift's synthesized `Codable` gives the app's own types, so the app
//! declares `Codable` and writes no mapping: camelCase names, an enum case with values as
//! `{"case": {"label": value}}` (`_0` for an unlabeled one), a case without values as
//! `{"case": {}}`, and a raw-value enum as its raw value.

use serde::{Deserialize, Serialize};

/// A click on a link, by its modifiers and button.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Gesture {
    /// No modifier, left button.
    Plain,
    Cmd,
    CmdShift,
    /// Shift alone.
    Shift,
    /// Option alone.
    Option,
    /// The middle button.
    Middle,
    /// The middle button with Shift.
    MiddleShift,
}

/// The modifiers a link click reads (Control and the rest are ignored, as in Chrome).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct Modifiers {
    pub command: bool,
    pub shift: bool,
    pub option: bool,
}

impl Gesture {
    /// The gesture of a click with `modifiers` on `button` (2 is the middle button). Command wins
    /// over Shift alone and Option.
    pub fn of(modifiers: Modifiers, button: i64) -> Self {
        let Modifiers { command, shift, option } = modifiers;
        if command {
            if shift { Self::CmdShift } else { Self::Cmd }
        } else if button == 2 {
            if shift { Self::MiddleShift } else { Self::Middle }
        } else if shift && !option {
            Self::Shift
        } else if option && !shift {
            Self::Option
        } else {
            Self::Plain
        }
    }
}

/// Where a page-requested tab opens (`BrowserNewTabDisposition`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewTabDisposition {
    /// A new selected tab next to the opener (plain `target=_blank`).
    ForegroundTab,
    /// A new unselected tab.
    BackgroundTab,
    /// Where the host puts every link the person opens (`layout.linkPlacement`).
    LinkPlacement,
    /// `window.open` with window features.
    Popup,
    /// A new cmux window.
    NewWindow,
}

/// What a link click does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkAction {
    /// Loads the link in the tab that shows it.
    CurrentTab,
    BackgroundTab,
    ForegroundTab,
    LinkPlacement,
    NewWindow,
    /// Downloads the link target.
    Download,
}

impl LinkAction {
    /// The new tab's disposition; `None` when no new tab opens.
    pub fn new_tab_disposition(self) -> Option<NewTabDisposition> {
        match self {
            Self::BackgroundTab => Some(NewTabDisposition::BackgroundTab),
            Self::ForegroundTab => Some(NewTabDisposition::ForegroundTab),
            Self::LinkPlacement => Some(NewTabDisposition::LinkPlacement),
            Self::NewWindow => Some(NewTabDisposition::NewWindow),
            Self::CurrentTab | Self::Download => None,
        }
    }
}

/// What each modified link click does (cmux.json `browser.links.*`). A plain click always loads
/// the link in the current tab. The default is Chrome's (what a script's request without a user
/// gesture follows).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct ClickMapping {
    pub cmd_click: LinkAction,
    pub cmd_shift_click: LinkAction,
    pub shift_click: LinkAction,
    pub option_click: LinkAction,
    pub middle_click: LinkAction,
}

impl ClickMapping {
    /// Chrome's defaults.
    pub const CHROME: Self = Self {
        cmd_click: LinkAction::BackgroundTab,
        cmd_shift_click: LinkAction::ForegroundTab,
        shift_click: LinkAction::NewWindow,
        option_click: LinkAction::Download,
        middle_click: LinkAction::BackgroundTab,
    };

    /// What `gesture` does. Chrome treats the middle button like Command, so a Shift-middle click
    /// follows `cmd_shift_click`.
    pub fn action(&self, gesture: Gesture) -> LinkAction {
        match gesture {
            Gesture::Plain => LinkAction::CurrentTab,
            Gesture::Cmd => self.cmd_click,
            Gesture::CmdShift | Gesture::MiddleShift => self.cmd_shift_click,
            Gesture::Shift => self.shift_click,
            Gesture::Option => self.option_click,
            Gesture::Middle => self.middle_click,
        }
    }
}

impl Default for ClickMapping {
    fn default() -> Self {
        Self::CHROME
    }
}

/// `cef_window_open_disposition_t` (`include/internal/cef_types.h`), by its raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CefDisposition {
    Unknown,
    CurrentTab,
    SingletonTab,
    NewForegroundTab,
    NewBackgroundTab,
    NewPopup,
    NewWindow,
    SaveToDisk,
    OffTheRecord,
    IgnoreAction,
    SwitchToTab,
    NewPictureInPicture,
    NewSplitView,
}

impl CefDisposition {
    /// The disposition of a raw value; anything unknown is [`CefDisposition::Unknown`].
    pub fn from_raw(raw: i64) -> Self {
        match raw {
            1 => Self::CurrentTab,
            2 => Self::SingletonTab,
            3 => Self::NewForegroundTab,
            4 => Self::NewBackgroundTab,
            5 => Self::NewPopup,
            6 => Self::NewWindow,
            7 => Self::SaveToDisk,
            8 => Self::OffTheRecord,
            9 => Self::IgnoreAction,
            10 => Self::SwitchToTab,
            11 => Self::NewPictureInPicture,
            12 => Self::NewSplitView,
            _ => Self::Unknown,
        }
    }

    /// True for the dispositions a modified link click produces.
    pub fn is_link_click(self) -> bool {
        matches!(
            self,
            Self::NewBackgroundTab | Self::NewForegroundTab | Self::NewWindow | Self::SaveToDisk
        )
    }
}

impl<'de> Deserialize<'de> for CefDisposition {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Ok(Self::from_raw(i64::deserialize(deserializer)?))
    }
}

/// Where a tab Chromium wants to open goes (`CEFLinkPlacement`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkPlacement {
    /// A cmux tab (or window) with this disposition.
    Tab {
        #[serde(rename = "_0")]
        disposition: NewTabDisposition,
    },
    /// No new tab: the opener loads the URL.
    Opener {},
    /// No new tab: the opener downloads the URL.
    Download {},
    /// Chromium handles it alone: no cmux tab.
    Chromium {},
}

impl LinkPlacement {
    const fn tab(disposition: NewTabDisposition) -> Self {
        Self::Tab { disposition }
    }
}

/// The last mouse-up on a Chromium page.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct ClickRecord {
    pub gesture: Gesture,
    /// Seconds since boot, as `NSEvent.timestamp`.
    pub timestamp: f64,
}

/// A click older than this (seconds) did not cause the request.
pub const CLICK_LIFETIME: f64 = 1.0;

/// The one decision for Chromium link dispositions (`CEFLinkClicks.placement`), through the same
/// mapping WebKit uses. Chromium reports NEW_BACKGROUND_TAB for Cmd-click and middle click,
/// NEW_WINDOW for Shift-click, SAVE_TO_DISK for Option-click, and NEW_FOREGROUND_TAB for both
/// Shift-Cmd-click and a plain `target=_blank` link. `click`, the last mouse-up on the requesting
/// page when it is at most [`CLICK_LIFETIME`] old at `now`, is read only to tell those apart. A
/// request without a user gesture (a script) never follows a modified-click setting.
pub fn cef_placement(
    disposition: CefDisposition,
    user_gesture: bool,
    click: Option<ClickRecord>,
    now: f64,
    mapping: &ClickMapping,
) -> LinkPlacement {
    let mapping = if user_gesture { *mapping } else { ClickMapping::CHROME };
    let click = if user_gesture { click } else { None };
    let recent = click.and_then(|record| {
        (now >= record.timestamp && now - record.timestamp <= CLICK_LIFETIME)
            .then_some(record.gesture)
    });
    let gesture = match disposition {
        CefDisposition::NewBackgroundTab => {
            Some(if recent == Some(Gesture::Middle) { Gesture::Middle } else { Gesture::Cmd })
        }
        CefDisposition::NewForegroundTab => {
            recent.filter(|gesture| matches!(gesture, Gesture::CmdShift | Gesture::MiddleShift))
        }
        CefDisposition::NewWindow => Some(Gesture::Shift),
        CefDisposition::SaveToDisk => Some(Gesture::Option),
        CefDisposition::NewPopup => return LinkPlacement::tab(NewTabDisposition::Popup),
        CefDisposition::SingletonTab
        | CefDisposition::SwitchToTab
        | CefDisposition::NewSplitView
        | CefDisposition::Unknown
        | CefDisposition::OffTheRecord => {
            return LinkPlacement::tab(NewTabDisposition::ForegroundTab);
        }
        CefDisposition::CurrentTab
        | CefDisposition::IgnoreAction
        | CefDisposition::NewPictureInPicture => return LinkPlacement::Chromium {},
    };
    let Some(gesture) = gesture else {
        return LinkPlacement::tab(NewTabDisposition::ForegroundTab);
    };
    match mapping.action(gesture) {
        LinkAction::CurrentTab => LinkPlacement::Opener {},
        LinkAction::Download => LinkPlacement::Download {},
        action => LinkPlacement::tab(
            action.new_tab_disposition().unwrap_or(NewTabDisposition::ForegroundTab),
        ),
    }
}

/// What Chromium wanted to create (`cmux_window_request_kind_t` of the fork), by its raw value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowKind {
    Tab,
    Window,
    Popup,
    OffTheRecord,
    App,
}

impl<'de> Deserialize<'de> for WindowKind {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        match i64::deserialize(deserializer)? {
            0 => Ok(Self::Tab),
            1 => Ok(Self::Window),
            2 => Ok(Self::Popup),
            3 => Ok(Self::OffTheRecord),
            4 => Ok(Self::App),
            other => Err(serde::de::Error::custom(format!("window request kind {other}"))),
        }
    }
}

/// A window Chromium wants to open (`CEFWindowRequest`).
#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowRequest {
    pub kind: WindowKind,
    pub disposition: CefDisposition,
    /// The tab that asked, or 0.
    #[serde(default)]
    pub source_browser: i32,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub user_gesture: bool,
    #[serde(default)]
    pub profile_path: String,
    #[serde(default = "yes")]
    pub persistent_profile: bool,
}

fn yes() -> bool {
    true
}

/// A pane window the request can go to (`CEFWindowCandidate`).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowCandidate {
    pub anchor: i32,
    pub profile_path: String,
    #[serde(default)]
    pub holds_source: bool,
    #[serde(default)]
    pub last_shown: bool,
    #[serde(default)]
    pub visible: bool,
}

/// What the runtime knows when it places a tab (`CEFLinkContext`): the person's mapping, the
/// source page's last click and the current time.
#[derive(Clone, Copy, Debug, Default, PartialEq, Deserialize)]
#[serde(default)]
pub struct LinkContext {
    pub mapping: ClickMapping,
    /// The source page's last mouse-up, if any.
    pub click: Option<ClickRecord>,
    pub now: f64,
}

impl LinkContext {
    fn placement(
        &self,
        disposition: CefDisposition,
        source: i32,
        user_gesture: bool,
    ) -> LinkPlacement {
        let click = if source != 0 { self.click } else { None };
        cef_placement(disposition, user_gesture, click, self.now, &self.mapping)
    }
}

/// Why Chromium opens nothing and cmux tells the person.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WindowRefusal {
    /// The request's store has no Chromium window and is off the record.
    NoWindow,
}

/// What the runtime does with a request (`CEFWindowDecision`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WindowDecision {
    Insert {
        anchor: i32,
        disposition: NewTabDisposition,
    },
    OpenInNewTab {
        url: String,
        disposition: NewTabDisposition,
    },
    LoadInSource {
        url: String,
    },
    DownloadInSource {
        url: String,
    },
    OpenOffTheRecord {
        url: String,
    },
    Refuse {
        #[serde(rename = "_0")]
        refusal: WindowRefusal,
    },
}

/// Where a request goes before a window is chosen (`CEFWindowPolicy.placement`). Popups keep
/// `popup`; a page's link request goes through the link mapping; everything else is a selected
/// tab. `opener` and `download` need the source tab and a URL.
pub fn window_placement(request: &WindowRequest, links: &LinkContext) -> LinkPlacement {
    let placement = match request.kind {
        WindowKind::Popup => return LinkPlacement::tab(NewTabDisposition::Popup),
        WindowKind::OffTheRecord => return LinkPlacement::tab(NewTabDisposition::ForegroundTab),
        WindowKind::Window | WindowKind::App => {
            if request.source_browser == 0 || !request.disposition.is_link_click() {
                return LinkPlacement::tab(NewTabDisposition::ForegroundTab);
            }
            links.placement(request.disposition, request.source_browser, request.user_gesture)
        }
        WindowKind::Tab => {
            links.placement(request.disposition, request.source_browser, request.user_gesture)
        }
    };
    if matches!(placement, LinkPlacement::Opener {} | LinkPlacement::Download {})
        && (request.source_browser == 0 || request.url.is_empty())
    {
        return LinkPlacement::tab(NewTabDisposition::ForegroundTab);
    }
    placement
}

/// The one decision for every window Chromium wants to open (`CEFWindowPolicy.decide`).
pub fn decide_window(
    request: &WindowRequest,
    candidates: &[WindowCandidate],
    links: &LinkContext,
) -> WindowDecision {
    if request.kind == WindowKind::OffTheRecord
        || request.disposition == CefDisposition::OffTheRecord
    {
        return WindowDecision::OpenOffTheRecord { url: request.url.clone() };
    }
    let disposition = match window_placement(request, links) {
        LinkPlacement::Tab { disposition } => disposition,
        LinkPlacement::Opener {} => {
            return WindowDecision::LoadInSource { url: request.url.clone() };
        }
        LinkPlacement::Download {} => {
            return WindowDecision::DownloadInSource { url: request.url.clone() };
        }
        LinkPlacement::Chromium {} => NewTabDisposition::ForegroundTab,
    };
    let same_profile =
        || candidates.iter().filter(|candidate| candidate.profile_path == request.profile_path);
    let chosen = same_profile()
        .find(|candidate| candidate.holds_source)
        .or_else(|| same_profile().find(|candidate| candidate.last_shown))
        .or_else(|| same_profile().find(|candidate| candidate.visible))
        .or_else(|| same_profile().next());
    match chosen {
        Some(chosen) => WindowDecision::Insert { anchor: chosen.anchor, disposition },
        None if !request.persistent_profile => {
            WindowDecision::Refuse { refusal: WindowRefusal::NoWindow }
        }
        None => WindowDecision::OpenInNewTab { url: request.url.clone(), disposition },
    }
}

/// What a link click with modifiers does in a WebKit tab (`WebKitLinkClick`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WebKitLinkClick {
    /// A plain click: the page's own behavior.
    PageDefault {},
    /// A modified click mapped to the current tab.
    Navigate {},
    Open {
        #[serde(rename = "_0")]
        disposition: NewTabDisposition,
    },
    Download {},
}

/// The modifiers of a WebKit link click (`button` 2 is the middle button) through `mapping`.
pub fn webkit_link_click(
    modifiers: Modifiers,
    button: i64,
    mapping: &ClickMapping,
) -> WebKitLinkClick {
    let gesture = Gesture::of(modifiers, button);
    if gesture == Gesture::Plain {
        return WebKitLinkClick::PageDefault {};
    }
    let action = mapping.action(gesture);
    match action.new_tab_disposition() {
        Some(disposition) => WebKitLinkClick::Open { disposition },
        None if action == LinkAction::Download => WebKitLinkClick::Download {},
        None => WebKitLinkClick::Navigate {},
    }
}
