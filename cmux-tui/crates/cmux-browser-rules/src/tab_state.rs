//! The tab state machine: the pure reducer from an engine's navigation events to the state the
//! chrome renders, for both engines.
//!
//! Ported 1:1 from the app's Swift (`CmuxNextBrowser`): `BrowserTabStateMachine` and
//! `BrowserNavigationEvent` (Core/BrowserTabStateMachine.swift), `BrowserTabState`,
//! `BrowserLoadPhase` and `BrowserSecurityState` (Core/BrowserTabState.swift),
//! `BrowserNavigationID` and `BrowserLoadError` (Core/BrowserNavigation.swift),
//! `BrowserScrollReport` (Core/BrowserScrollReport.swift), `BrowserMediaFrames`
//! (Core/BrowserMediaFrames.swift), and from `CmuxNextBrowserCore`: `BrowserMediaState` and its
//! `settled` rule, `BrowserMediaAction`, `BrowserZoom.clamp`, `BrowserProcessExit` and
//! `BrowserEngineKind`. Swift keeps the engines, which translate their native callbacks
//! (WKNavigationDelegate, KVO, CEF handlers) into [`NavigationEvent`]s.
//!
//! The wire is the shape Swift's synthesized `Codable` gives those types (see [`crate::links`]):
//! camelCase names, an enum case with values as `{"case": {"label": value}}` (`_0`, `_1` for
//! unlabeled ones), a case without values as `{"case": {}}`, a raw-value enum as its raw value, a
//! nil optional left out, a `URL` as its absolute string (`JSONEncoder`'s URL rule) and a `Date`
//! as its seconds since 2001-01-01 (`JSONEncoder`'s default date rule). The machine's private
//! stored properties are on the wire too, so a machine round-trips through the app.

use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// A URL, as its absolute string. Two URLs are equal when their strings are (`URL ==`).
pub type Url = String;

/// Swift's `max(_:_:)`: `y >= x ? y : x` (a NaN `x` survives, a NaN `y` does not).
fn swift_max(x: f64, y: f64) -> f64 {
    if y >= x { y } else { x }
}

/// Swift's `min(_:_:)`: `y < x ? y : x`.
fn swift_min(x: f64, y: f64) -> f64 {
    if y < x { y } else { x }
}

/// The parts of a URL the rules read: `URL.scheme`, `URL.host()` and `URL.port`, as RFC 3986
/// splits an absolute URL. A URL without an authority (`about:blank`, `data:`) has no host, and
/// neither has an empty authority (`file:///`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UrlParts<'a> {
    pub scheme: Option<&'a str>,
    pub host: Option<&'a str>,
    pub port: Option<u32>,
}

impl<'a> UrlParts<'a> {
    pub fn of(url: &'a str) -> Self {
        let mut parts = Self { scheme: None, host: None, port: None };
        let rest = match url.split_once(':') {
            Some((scheme, rest)) if is_scheme(scheme) => {
                parts.scheme = Some(scheme);
                rest
            }
            _ => url,
        };
        let Some(after) = rest.strip_prefix("//") else { return parts };
        let authority = after.split(['/', '?', '#']).next().unwrap_or(after);
        let host_port = authority.rsplit_once('@').map_or(authority, |(_, host_port)| host_port);
        let (host, port) = if let Some(bracketed) = host_port.strip_prefix('[') {
            match bracketed.split_once(']') {
                Some((host, tail)) => (host, tail.strip_prefix(':')),
                None => (bracketed, None),
            }
        } else {
            match host_port.rsplit_once(':') {
                Some((host, port)) => (host, Some(port)),
                None => (host_port, None),
            }
        };
        if !host.is_empty() {
            parts.host = Some(host);
        }
        parts.port = port.and_then(|port| {
            if port.is_empty() || !port.bytes().all(|b| b.is_ascii_digit()) {
                None
            } else {
                port.parse().ok()
            }
        });
        parts
    }
}

/// RFC 3986 `scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`.
fn is_scheme(text: &str) -> bool {
    let mut bytes = text.bytes();
    bytes.next().is_some_and(|b| b.is_ascii_alphabetic())
        && bytes.all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'-' | b'.'))
}

fn host(url: Option<&str>) -> Option<&str> {
    url.and_then(|url| UrlParts::of(url).host)
}

/// A navigation attempt (`BrowserNavigationID`). Engines assign one per started navigation so
/// that late callbacks for a superseded navigation are ignored.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NavigationId {
    pub raw_value: u64,
}

impl NavigationId {
    pub const fn new(raw_value: u64) -> Self {
        Self { raw_value }
    }
}

/// `NSURLErrorDomain`.
pub const NSURL_ERROR_DOMAIN: &str = "NSURLErrorDomain";
/// `NSURLErrorCancelled`.
pub const NSURL_ERROR_CANCELLED: i64 = -999;

/// A load failure reported by an engine (`BrowserLoadError`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoadError {
    pub domain: String,
    pub code: i64,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "failingURL")]
    pub failing_url: Option<Url>,
    /// The engine draws its own page for this failure, so the pane shows no cmux view over it:
    /// Chromium's net error pages and certificate interstitial in a Chromium tab (Lawrence
    /// 2026-10-13). WebKit draws none, so its tabs show cmux's pages; so does an agent-driven
    /// Chromium tab for a certificate error.
    #[serde(default)]
    pub engine_shows_page: bool,
}

impl LoadError {
    pub fn new(domain: &str, code: i64, message: &str, failing_url: Option<&str>) -> Self {
        Self {
            domain: domain.to_owned(),
            code,
            message: message.to_owned(),
            failing_url: failing_url.map(str::to_owned),
            engine_shows_page: false,
        }
    }

    /// True for failures that are not user-visible errors: a cancelled load (Stop, or a new
    /// navigation replacing this one) or WebKit's "frame load interrupted" when a response
    /// becomes a download.
    pub fn is_benign_interruption(&self) -> bool {
        (self.domain == NSURL_ERROR_DOMAIN && self.code == NSURL_ERROR_CANCELLED)
            || (self.domain == "WebKitErrorDomain" && self.code == 102)
    }
}

/// Where the current page load is (`BrowserLoadPhase`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LoadPhase {
    /// Nothing loaded yet.
    Idle {},
    /// A navigation started; the old page is still on screen.
    Provisional {},
    /// The new document replaced the old one and is still loading.
    Committed {},
    /// The last navigation finished or was stopped after it committed.
    Finished {},
    /// The last navigation failed.
    Failed {
        #[serde(rename = "_0")]
        error: LoadError,
    },
}

impl LoadPhase {
    /// The load ended: finished, stopped after it committed, or failed.
    pub fn has_ended(&self) -> bool {
        matches!(self, Self::Finished {} | Self::Failed { .. })
    }
}

/// Transport security of the committed page, as shown by the address bar and the page info
/// bubble (Chromium `security_state::SecurityLevel`; `BrowserSecurityState`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SecurityState {
    None {},
    /// HTTPS with a valid certificate and no insecure subresources.
    Secure {},
    /// Plain HTTP.
    Insecure {},
    /// HTTPS that loaded insecure subresources ("not fully secure").
    MixedContent {},
    /// HTTPS with a certificate error (Chromium `DANGEROUS` for a bad cert).
    Broken {},
    /// A site the engine flagged as malware or phishing.
    Dangerous {},
    Local {},
}

/// The engine of a tab (`BrowserEngineKind`, raw values).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EngineKind {
    Webkit,
    Cef,
}

/// Why a content process ended (`BrowserProcessExit.Reason`, raw values).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ProcessExitReason {
    /// The process crashed (a signal such as SIGSEGV, or a CHECK).
    Crashed,
    /// Something outside the page ended it (`kill`, Activity Monitor, the system, or "Exit page"
    /// on a hung page).
    Killed,
    OutOfMemory,
    /// The process could not start.
    LaunchFailed,
    /// Code signature or integrity check failed (Windows in Chromium; kept so every status maps).
    IntegrityFailure,
    /// Ended with a non-zero exit code for another reason.
    Abnormal,
}

/// Why a tab's content process ended while the page was open (the "sad tab" case;
/// `BrowserProcessExit`). The tab keeps its URL and history; Reload starts a new process.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ProcessExit {
    pub reason: ProcessExitReason,
    /// Exit code or signal number, when the engine reports one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<i64>,
    /// The engine whose content process ended: the sad tab uses that browser's wording.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub engine: Option<EngineKind>,
}

/// A `navigator.mediaSession` action a page can handle (`BrowserMediaAction`, raw values).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaAction {
    Play,
    Pause,
    Previoustrack,
    Nexttrack,
}

fn one() -> f64 {
    1.0
}

/// What a page plays now, as Edge's media hub shows it (`BrowserMediaState`): the
/// `navigator.mediaSession` metadata when the page sets it, else the page title, and the playing
/// element's state.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaState {
    pub title: String,
    #[serde(default)]
    pub artist: String,
    #[serde(default)]
    pub album: String,
    /// The largest artwork the page lists, resolved against the page.
    #[serde(default, skip_serializing_if = "Option::is_none", rename = "artworkURL")]
    pub artwork_url: Option<Url>,
    pub is_playing: bool,
    /// Muted, or at volume 0.
    #[serde(default)]
    pub is_muted: bool,
    #[serde(default)]
    pub is_video: bool,
    /// The page's video floats in Picture in Picture; it plays on while the tab is hidden.
    #[serde(default)]
    pub is_picture_in_picture: bool,
    /// The reporting frame keeps the tab muted (`BrowserAudioMuting`).
    #[serde(default)]
    pub is_tab_muted: bool,
    /// Sound with no media element behind it (Web Audio): the tab's speaker shows it, the media
    /// hub and Now Playing do not.
    #[serde(default)]
    pub is_sound_only: bool,
    /// Sound besides the reported element: Web Audio in its frame, or another frame's sound
    /// ([`MediaFrames`]). The tab's speaker shows it; the reported element stays the session.
    #[serde(default)]
    pub is_other_sound: bool,
    /// The `mediaSession` actions the page handles.
    #[serde(default)]
    pub actions: BTreeSet<MediaAction>,
    /// The element's position in seconds when reported (`position_date`); nil from a page that
    /// did not say.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<f64>,
    /// The element's length in seconds; nil while unknown or for a live stream.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
    /// The element's playback rate (1 is normal speed).
    #[serde(default = "one")]
    pub rate: f64,
    /// When `position` was read, in seconds since 2001-01-01.
    #[serde(default)]
    pub position_date: f64,
}

impl MediaState {
    /// A report of `title`, playing or not, with every other field at its Swift default (the
    /// date is the reference date).
    pub fn new(title: &str, is_playing: bool) -> Self {
        Self {
            title: title.to_owned(),
            artist: String::new(),
            album: String::new(),
            artwork_url: None,
            is_playing,
            is_muted: false,
            is_video: false,
            is_picture_in_picture: false,
            is_tab_muted: false,
            is_sound_only: false,
            is_other_sound: false,
            actions: BTreeSet::new(),
            position: None,
            duration: None,
            rate: 1.0,
            position_date: 0.0,
        }
    }

    /// Sound is coming out of the tab (the tab's speaker indicator).
    pub fn is_audible(&self) -> bool {
        self.is_playing && !self.is_muted
    }

    /// Sound is coming out of the tab, from the element or besides it (the tab's speaker).
    pub fn is_sounding(&self) -> bool {
        self.is_audible() || self.is_other_sound
    }

    /// The position at `date`: it moves on while playing, kept inside the length.
    pub fn position_at(&self, date: f64) -> Option<f64> {
        let position = self.position?;
        let moved = if self.is_playing {
            position + swift_max(0.0, date - self.position_date) * self.rate
        } else {
            position
        };
        Some(swift_min(swift_max(0.0, moved), self.duration.unwrap_or(f64::INFINITY)))
    }

    /// The state a tab keeps after `report`: the earlier one when the report changes nothing but
    /// a position that moved on as expected (the page's heartbeat), so a playing tab does not
    /// change state every few seconds; else the report, whole (a pause, a resume or a speed
    /// change takes its own position and time).
    pub fn settled(earlier: Option<&Self>, report: Option<&Self>) -> Option<Self> {
        let (Some(earlier), Some(report)) = (earlier, report) else { return report.cloned() };
        let on_course = match (earlier.position_at(report.position_date), report.position) {
            (None, None) => true,
            (Some(expected), Some(reported)) => (reported - expected).abs() < 1.5,
            _ => false,
        };
        let mut same = report.clone();
        same.position = earlier.position;
        same.position_date = earlier.position_date;
        Some(if on_course && same == *earlier { earlier.clone() } else { report.clone() })
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
struct MediaEntry {
    media: MediaState,
    /// When the entry began or last changed between playing, paused and floating.
    order: u64,
}

/// The latest media report of each frame of one document, and the one the tab shows
/// (`BrowserMediaFrames`).
///
/// Every frame of a page reports on its own: an ad iframe that stops reports null for itself, and
/// that must not erase the main frame's paused video. So a report replaces only its own frame's
/// entry, and the tab shows, in order: a video in Picture in Picture, then the frame that started
/// playing last, then the frame that reported last; a frame's sound with no element (Web Audio,
/// `is_sound_only`) shows only when no frame has an element, and otherwise marks the shown one
/// `is_other_sound` (the speaker), so it never hides a video from the media hub. A null report, or
/// the frame's `pagehide`, drops its entry; a new main document (`committed`) or a process exit
/// drops them all.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaFrames {
    entries: BTreeMap<String, MediaEntry>,
    counter: u64,
}

impl MediaFrames {
    /// Takes `frame`'s report (`None`: it plays nothing now) and returns what the tab shows.
    pub fn apply(&mut self, media: Option<MediaState>, frame: &str) -> Option<MediaState> {
        match media {
            Some(media) => match self.entries.get_mut(frame) {
                Some(old)
                    if old.media.is_playing == media.is_playing
                        && old.media.is_picture_in_picture == media.is_picture_in_picture =>
                {
                    old.media = media;
                }
                _ => {
                    self.counter = self.counter.wrapping_add(1);
                    self.entries
                        .insert(frame.to_owned(), MediaEntry { media, order: self.counter });
                }
            },
            None => {
                self.entries.remove(frame);
            }
        }
        self.current()
    }

    /// What the tab shows: the floating video, else the frame that started playing last, else
    /// the frame that reported last; `None` when no frame plays anything.
    pub fn current(&self) -> Option<MediaState> {
        let mut shown = self.entries.values().max_by_key(|entry| Self::rank(entry))?.media.clone();
        if !shown.is_sounding() && self.entries.values().any(|entry| entry.media.is_sounding()) {
            shown.is_other_sound = true;
        }
        Some(shown)
    }

    fn rank(entry: &MediaEntry) -> (u8, u8, u8, u64) {
        let element = if entry.media.is_sound_only { 0 } else { 1 };
        (
            u8::from(entry.media.is_picture_in_picture),
            if entry.media.is_playing { element } else { 0 },
            element,
            entry.order,
        )
    }
}

/// How far down the shown page was when its scrolling last settled, as the page itself reported
/// it (`BrowserScrollReport`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScrollReport {
    /// The address the page had when it reported; a report applies only to that page.
    pub url: Url,
    /// The page's `window.scrollY`, in CSS pixels.
    pub y: f64,
}

/// Chromium's page zoom ladder's ends (`BrowserZoom.minimum`, `.maximum`).
pub const ZOOM_MINIMUM: f64 = 0.25;
pub const ZOOM_MAXIMUM: f64 = 5.0;

/// `BrowserZoom.clamp`: a zoom inside the ladder; 1 for a value that is not finite.
pub fn clamp_zoom(zoom: f64) -> f64 {
    if !zoom.is_finite() {
        return 1.0;
    }
    swift_min(swift_max(zoom, ZOOM_MINIMUM), ZOOM_MAXIMUM)
}

/// Everything the chrome needs to render a tab (`BrowserTabState`). One value type shared by all
/// engines; engines produce it through [`TabStateMachine`].
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TabState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub url: Option<Url>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "faviconURL")]
    pub favicon_url: Option<Url>,
    pub phase: LoadPhase,
    /// Load progress in `0...1`. Meaningful only while `is_loading`.
    pub progress: f64,
    pub can_go_back: bool,
    pub can_go_forward: bool,
    /// The session history around the current entry: back URLs oldest first, forward URLs
    /// nearest first. `None` when the engine does not report them.
    #[serde(skip_serializing_if = "Option::is_none", rename = "backURLs")]
    pub back_urls: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none", rename = "forwardURLs")]
    pub forward_urls: Option<Vec<String>>,
    /// Page zoom factor, 1.0 = 100 %.
    pub zoom: f64,
    /// True while page content is "fullscreen" inside the pane.
    pub is_content_fullscreen: bool,
    pub security: SecurityState,
    /// The navigation whose callbacks are currently accepted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_navigation: Option<NavigationId>,
    /// Set when the page's content process ended (the "sad tab"). Cleared when a navigation
    /// starts (Reload).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub process_exit: Option<ProcessExit>,
    /// The page stopped handling input ("Page unresponsive").
    pub is_unresponsive: bool,
    /// What the page plays; `None` when nothing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub media: Option<MediaState>,
    /// The tab is muted (`BrowserAudioMuting`); kept across navigations.
    pub is_audio_muted: bool,
    /// A load ended in this tab (finished, stopped or failed): any later load is one the page or
    /// the user started, never the tab's own opening load.
    pub has_ended_load: bool,
    /// Where the shown page last said its scrolling settled ([`ScrollReport`]); `None` until it
    /// scrolls.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scroll_report: Option<ScrollReport>,
}

impl Default for TabState {
    fn default() -> Self {
        Self {
            url: None,
            title: None,
            favicon_url: None,
            phase: LoadPhase::Idle {},
            progress: 0.0,
            can_go_back: false,
            can_go_forward: false,
            back_urls: None,
            forward_urls: None,
            zoom: 1.0,
            is_content_fullscreen: false,
            security: SecurityState::None {},
            active_navigation: None,
            process_exit: None,
            is_unresponsive: false,
            media: None,
            is_audio_muted: false,
            has_ended_load: false,
            scroll_report: None,
        }
    }
}

impl TabState {
    pub fn is_loading(&self) -> bool {
        matches!(self.phase, LoadPhase::Provisional {} | LoadPhase::Committed {})
    }

    /// The request is out and no response committed yet (Chromium's waiting throbber state).
    pub fn is_waiting(&self) -> bool {
        matches!(self.phase, LoadPhase::Provisional {})
    }

    pub fn load_error(&self) -> Option<&LoadError> {
        match &self.phase {
            LoadPhase::Failed { error } => Some(error),
            _ => None,
        }
    }
}

/// Input to [`TabStateMachine`] (`BrowserNavigationEvent`). Engines translate their native
/// callbacks (WKNavigationDelegate, KVO, CEF handlers) into these events.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NavigationEvent {
    Started {
        #[serde(rename = "_0")]
        id: NavigationId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<Url>,
    },
    /// The address a page will load once its engine has a page for it (a Chromium tab no pane
    /// showed yet): the address shows, and nothing loads or commits until the engine starts the
    /// load (`Started`).
    AddressPending {
        #[serde(rename = "_0")]
        url: Url,
    },
    Redirected {
        #[serde(rename = "_0")]
        id: NavigationId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<Url>,
    },
    Committed {
        #[serde(rename = "_0")]
        id: NavigationId,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        url: Option<Url>,
    },
    Finished {
        #[serde(rename = "_0")]
        id: NavigationId,
    },
    Failed {
        #[serde(rename = "_0")]
        id: NavigationId,
        #[serde(rename = "_1")]
        error: LoadError,
    },
    /// The user or the engine stopped the active load.
    Stopped {},
    Progress {
        #[serde(rename = "_0")]
        value: f64,
    },
    /// URL change without a navigation (pushState, fragment, KVO echo).
    UrlChanged {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        url: Option<Url>,
    },
    TitleChanged {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    HistoryChanged { can_go_back: bool, can_go_forward: bool },
    /// The URLs of the back and forward lists (engines that expose them).
    HistoryListed { back: Vec<String>, forward: Vec<String> },
    FaviconChanged {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        url: Option<Url>,
    },
    ZoomChanged {
        #[serde(rename = "_0")]
        zoom: f64,
    },
    ContentFullscreenChanged {
        #[serde(rename = "_0")]
        on: bool,
    },
    SecurityChanged {
        #[serde(rename = "_0")]
        security: SecurityState,
    },
    /// The content process ended; the page is gone until the next load.
    ProcessExited {
        #[serde(rename = "_0")]
        exit: ProcessExit,
    },
    /// The content process stopped (true) or resumed (false) handling input.
    UnresponsiveChanged {
        #[serde(rename = "_0")]
        unresponsive: bool,
    },
    /// One frame's media report; `None` when that frame plays nothing. `frame` is the id the
    /// frame's observer picked for its document: a report replaces only its own frame's
    /// ([`MediaFrames`]).
    MediaChanged {
        #[serde(rename = "_0", default, skip_serializing_if = "Option::is_none")]
        media: Option<MediaState>,
        #[serde(default)]
        frame: String,
    },
    /// The tab was muted (true) or unmuted (`BrowserAudioMuting`).
    AudioMutedChanged {
        #[serde(rename = "_0")]
        muted: bool,
    },
    /// The shown page's scrolling settled at `y` CSS pixels (`BrowserScrollReportScript`).
    PageScrolled {
        #[serde(rename = "_0")]
        y: f64,
    },
}

/// Pure reducer from engine events to [`TabState`] (`BrowserTabStateMachine`).
///
/// Rules that every engine gets for free:
/// - Callbacks for a navigation other than the active one are ignored, so a late failure from a
///   superseded load never overwrites the new load.
/// - Progress is clamped, never goes backwards within a navigation, and is ignored when nothing
///   is loading.
/// - Cancellation and download interruptions end the load without an error.
/// - Committing to another host clears the favicon and title.
/// - A process exit ends any load and marks the page gone; the next navigation (Reload) clears
///   it. A gone page is never unresponsive.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct TabStateMachine {
    state: TabState,
    /// URL of the last committed document. A load stopped before it commits reverts the address
    /// to this.
    #[serde(skip_serializing_if = "Option::is_none", rename = "committedURL")]
    committed_url: Option<Url>,
    /// The error page showing when the current navigation started: a load cancelled before it
    /// commits shows it again (Chromium retries a network error on its own and may cancel that
    /// retry).
    #[serde(skip_serializing_if = "Option::is_none")]
    error_before_start: Option<LoadError>,
    /// The active navigation's own address (its start, then its redirects). The address moving
    /// off it before the load commits is a newer load's.
    #[serde(skip_serializing_if = "Option::is_none", rename = "startedURL")]
    started_url: Option<Url>,
    /// Each frame's latest media report; `state.media` is the one the tab shows.
    media_frames: MediaFrames,
}

/// Progress shown as soon as a navigation starts, so the bar is visible.
pub const INITIAL_PROGRESS: f64 = 0.1;

impl TabStateMachine {
    pub fn new(state: TabState) -> Self {
        let committed_url =
            if state.phase == (LoadPhase::Idle {}) { None } else { state.url.clone() };
        Self {
            state,
            committed_url,
            error_before_start: None,
            started_url: None,
            media_frames: MediaFrames::default(),
        }
    }

    pub fn state(&self) -> &TabState {
        &self.state
    }

    /// Applies one event. Returns true when the state changed.
    pub fn apply(&mut self, event: NavigationEvent) -> bool {
        let before = self.state.clone();
        self.reduce(event);
        if before.is_loading() && !self.state.is_loading() {
            self.state.has_ended_load = true;
        }
        self.state != before
    }

    fn reduce(&mut self, event: NavigationEvent) {
        use NavigationEvent as E;
        let state = &mut self.state;
        match event {
            E::Started { id, url } => {
                self.error_before_start = state.load_error().cloned();
                state.process_exit = None;
                state.is_unresponsive = false;
                state.active_navigation = Some(id);
                state.phase = LoadPhase::Provisional {};
                state.progress = INITIAL_PROGRESS;
                if let Some(url) = url {
                    state.url = Some(url);
                }
                self.started_url = state.url.clone();
            }
            E::AddressPending { url } => {
                // Not a navigation: no phase, progress or committed address moves (an unloaded
                // tab is not loading).
                if state.is_loading() {
                    return;
                }
                state.url = Some(url);
            }
            E::Redirected { id, url } => {
                let Some(url) = url else { return };
                if Some(id) != state.active_navigation {
                    return;
                }
                state.url = Some(url.clone());
                self.started_url = Some(url);
            }
            E::Committed { id, url } => {
                if Some(id) != state.active_navigation {
                    return;
                }
                let previous_host = host(self.committed_url.as_deref()).map(str::to_owned);
                if let Some(url) = url {
                    state.url = Some(url);
                }
                if host(state.url.as_deref()) != previous_host.as_deref() {
                    state.favicon_url = None;
                }
                state.title = None;
                self.error_before_start = None;
                // A new document plays nothing until its script reports.
                state.media = None;
                self.media_frames = MediaFrames::default();
                state.phase = LoadPhase::Committed {};
                state.security = security(state.url.as_deref());
                self.committed_url = state.url.clone();
            }
            E::Finished { id } => {
                if Some(id) != state.active_navigation {
                    return;
                }
                state.phase = LoadPhase::Finished {};
                state.progress = 1.0;
                state.active_navigation = None;
            }
            E::Failed { id, error } => {
                if Some(id) != state.active_navigation {
                    return;
                }
                if error.is_benign_interruption() {
                    // Only a cancelled retry of the failed address shows its error again; a
                    // cancelled load replaced by another does not. A load whose replacement's
                    // address already arrived (WebKit's URL KVO before the cancellation) keeps
                    // that address; one WebKit already moved back to the committed page is not a
                    // replacement.
                    let replaced = state.url != self.started_url && state.url != self.committed_url;
                    let before_failing =
                        self.error_before_start.as_ref().and_then(|e| e.failing_url.as_ref());
                    let restores_error = !replaced && error.failing_url.as_ref() == before_failing;
                    self.end_without_error(restores_error, replaced);
                } else {
                    state.phase = LoadPhase::Failed { error };
                    state.progress = 0.0;
                    state.active_navigation = None;
                }
            }
            E::Stopped {} => {
                if !state.is_loading() {
                    return;
                }
                self.end_without_error(true, false);
            }
            E::Progress { value } => {
                if !state.is_loading() {
                    return;
                }
                let clamped = swift_min(swift_max(value, 0.0), 1.0);
                state.progress = swift_max(state.progress, clamped);
            }
            E::UrlChanged { url } => {
                let Some(url) = url else { return };
                let previous = state.url.replace(url.clone());
                if state.phase != (LoadPhase::Provisional {}) {
                    self.committed_url = Some(url.clone());
                }
                // A same-document change (pushState, a fragment) cannot change the origin and
                // keeps the engine's refinement (mixed content, a certificate error, a dangerous
                // site); only a new origin resets the indicator to the scheme level.
                if !state.is_loading() && !same_origin(previous.as_deref(), Some(&url)) {
                    state.security = security(Some(&url));
                }
            }
            E::TitleChanged { title } => {
                state.title = title
                    .as_deref()
                    .map(str::trim)
                    .filter(|trimmed| !trimmed.is_empty())
                    .map(str::to_owned);
            }
            E::HistoryChanged { can_go_back, can_go_forward } => {
                state.can_go_back = can_go_back;
                state.can_go_forward = can_go_forward;
            }
            E::HistoryListed { back, forward } => {
                state.back_urls = Some(back);
                state.forward_urls = Some(forward);
            }
            E::FaviconChanged { url } => state.favicon_url = url,
            E::ZoomChanged { zoom } => state.zoom = clamp_zoom(zoom),
            E::ContentFullscreenChanged { on } => state.is_content_fullscreen = on,
            E::SecurityChanged { security } => state.security = security,
            E::ProcessExited { exit } => {
                // Keeps the URL even when the load had not committed, so Reload opens what the
                // user asked for.
                state.process_exit = Some(exit);
                state.is_unresponsive = false;
                state.media = None;
                self.media_frames = MediaFrames::default();
                state.progress = 0.0;
                state.active_navigation = None;
                if state.phase != (LoadPhase::Finished {}) {
                    state.phase = if state.url.is_none() {
                        LoadPhase::Idle {}
                    } else {
                        LoadPhase::Finished {}
                    };
                }
            }
            E::UnresponsiveChanged { unresponsive } => {
                if state.process_exit.is_some() {
                    return;
                }
                state.is_unresponsive = unresponsive;
            }
            E::MediaChanged { media, frame } => {
                let shown = self.media_frames.apply(media, &frame);
                state.media = MediaState::settled(state.media.as_ref(), shown.as_ref());
            }
            E::AudioMutedChanged { muted } => state.is_audio_muted = muted,
            E::PageScrolled { y } => {
                let Some(url) = state.url.clone() else { return };
                state.scroll_report = Some(ScrollReport { url, y });
            }
        }
    }

    fn end_without_error(&mut self, restores_error: bool, keeps_address: bool) {
        let state = &mut self.state;
        if state.phase == (LoadPhase::Provisional {}) {
            if !keeps_address {
                state.url = self.committed_url.clone();
            }
            let restored = if restores_error { self.error_before_start.clone() } else { None };
            state.phase = match restored {
                Some(error) => LoadPhase::Failed { error },
                None if self.committed_url.is_none() => LoadPhase::Idle {},
                None => LoadPhase::Finished {},
            };
        } else {
            state.phase = LoadPhase::Finished {};
        }
        state.progress = 0.0;
        state.active_navigation = None;
    }
}

/// Same scheme, host (both case-insensitive) and port; false when either URL is missing.
pub fn same_origin(a: Option<&str>, b: Option<&str>) -> bool {
    let (Some(a), Some(b)) = (a, b) else { return false };
    let (a, b) = (UrlParts::of(a), UrlParts::of(b));
    let lower = |text: Option<&str>| text.map(str::to_lowercase);
    lower(a.scheme) == lower(b.scheme) && lower(a.host) == lower(b.host) && a.port == b.port
}

/// Scheme-level security. Engines refine it with `SecurityChanged` when they know about mixed
/// content or certificate problems.
pub fn security(url: Option<&str>) -> SecurityState {
    let scheme = url.and_then(|url| UrlParts::of(url).scheme).map(str::to_lowercase);
    match scheme.as_deref() {
        Some("https") => SecurityState::Secure {},
        Some("http") => SecurityState::Insecure {},
        Some("file" | "about" | "data" | "blob") => SecurityState::Local {},
        _ => SecurityState::None {},
    }
}

/// The security of a committed page from what the engine knows: mixed content, and a page loaded
/// past an untrusted certificate the user proceeded through, which is broken ("Not secure"), as
/// in Chrome.
pub fn committed_security(
    url: Option<&str>,
    has_only_secure_content: bool,
    certificate_bypassed: bool,
) -> SecurityState {
    let security = security(url);
    if security != (SecurityState::Secure {}) {
        return security;
    }
    if certificate_bypassed {
        return SecurityState::Broken {};
    }
    if has_only_secure_content { SecurityState::Secure {} } else { SecurityState::MixedContent {} }
}
