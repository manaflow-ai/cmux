//! Control messages (rd control stream, JSON, tag `t`) and input events
//! (payload of the rd input event tag `service`, tag `e`) of `cmux.rb/1`.
//! `schemas/remote-tab/messages.json` holds one example of each message.

use serde::{Deserialize, Serialize};

/// A rectangle in the surface's CSS pixels.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// A point in the surface's CSS pixels.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// The viewer pane and its screen.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScreenInfo {
    /// Pane size in CSS pixels (points on macOS).
    pub css_width: u32,
    pub css_height: u32,
    /// Backing scale of the pane's screen (2.0 on Retina).
    pub scale: f64,
    pub refresh_hz: u32,
    /// `srgb`, `display_p3`, ...
    pub color_space: String,
}

/// What the viewer can decode and show.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ViewerCaps {
    /// `h264`, `hevc`, `hevc_444`, ...
    pub codecs: Vec<String>,
    /// Tile codecs for the lossless top-off.
    pub tile_codecs: Vec<String>,
    pub max_fps: u32,
}

/// Why a host refused `rb.open`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefuseReason {
    NotRuntimeHost,
    NotAllowed,
    RelayDenied,
    ProfileMissing,
    Busy,
}

/// Session state as the viewer sees it (`rb.state`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionState {
    Idle,
    Opening,
    Live,
    Paused,
    Crashed,
    Closed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum HistoryOp {
    Back,
    Forward,
    Reload,
    ReloadNoCache,
    Stop,
}

/// Cursor shape. Standard shapes use their CSS name in `kind`; a custom
/// image uses `kind: "custom"` and the image hash.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CursorShape {
    pub kind: String,
    pub hash: Option<String>,
}

/// One menu entry (the CEF menu model as the local shim serializes it).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MenuItem {
    pub id: i64,
    /// `command`, `check`, `radio`, `separator`, `submenu`, `group` (select optgroup), `option`.
    #[serde(rename = "type")]
    pub item_type: String,
    pub label: String,
    pub enabled: bool,
    pub checked: bool,
    pub items: Vec<MenuItem>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MenuKind {
    /// Page context menu; the choice is a command id.
    Context,
    /// `<select>` popup; the choice is a list of option indices.
    Select,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Menu {
    pub kind: MenuKind,
    /// Where the menu opens, in the surface's CSS pixels.
    pub anchor: Rect,
    pub surface: u32,
    pub items: Vec<MenuItem>,
    /// `<select>` only: the selected option index, or null.
    pub selected: Option<u32>,
    /// `<select multiple>`.
    pub multiple: bool,
    pub right_aligned: bool,
}

/// The user's answer to a menu.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "choice", rename_all = "snake_case")]
pub enum MenuChoice {
    Cancel,
    Command { id: i64 },
    Indices { indices: Vec<u32> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DialogKind {
    Alert,
    Confirm,
    Prompt,
    Beforeunload,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Dialog {
    pub kind: DialogKind,
    pub origin: String,
    pub message: String,
    pub default_text: Option<String>,
    pub is_reload: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FileChooserMode {
    Open,
    OpenMultiple,
    Folder,
    Save,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct UploadRef {
    pub upload: u64,
    pub name: String,
    pub size: u64,
    pub mime: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DownloadStatus {
    Complete,
    Cancelled,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PermissionKind {
    Camera,
    Microphone,
    Geolocation,
    Notifications,
    ClipboardRead,
    Midi,
    StorageAccess,
    WindowManagement,
}

/// One pasteboard item. `data` is UTF-8 text for text types and base64 for
/// binary types (`base64` says which).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ClipboardItem {
    pub mime: String,
    pub base64: bool,
    pub data: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Disposition {
    ForegroundTab,
    BackgroundTab,
    NewWindow,
    Popup,
}

/// Why a host refused `rb.navigate` (cap `navigate`, c2-browser-stream.md).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NavigateRefusal {
    /// Not an http or https URL.
    Scheme,
    /// Not a URL, or no host.
    Invalid,
    /// The viewer's session may not act (revoked).
    NotAllowed,
    /// The page owner failed to start the load.
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SurfaceKind {
    PagePopup,
    ExtensionPopup,
    Autofill,
    Bubble,
}

/// A cookie version as the profile owners exchange it (section 5.4).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CookieVersion {
    pub value: String,
    pub last_update_us: u64,
    /// Install or host id of the machine that wrote this version.
    pub origin: String,
    pub deleted: bool,
    pub expires_us: Option<u64>,
}

/// The identity of a cookie (name, domain, path, partition key).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CookieKey {
    pub name: String,
    pub domain: String,
    pub path: String,
    pub partition_key: Option<String>,
    pub http_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CookieChange {
    pub key: CookieKey,
    pub version: CookieVersion,
}

/// Every `cmux.rb/1` control message. The tag `t` always starts with `rb.`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t")]
pub enum Control {
    #[serde(rename = "rb.open")]
    Open { tab: String, profile: String, viewer: String, screen: ScreenInfo, caps: ViewerCaps },
    #[serde(rename = "rb.opened")]
    Opened { session: u64, main_stream: u16 },
    #[serde(rename = "rb.refused")]
    Refused { reason: RefuseReason },
    #[serde(rename = "rb.close")]
    Close,
    #[serde(rename = "rb.closed")]
    Closed { reason: String },
    #[serde(rename = "rb.state")]
    State { state: SessionState },
    #[serde(rename = "rb.visibility")]
    Visibility { visible: bool },
    #[serde(rename = "rb.screen")]
    Screen { seq: u32, screen: ScreenInfo },
    #[serde(rename = "rb.screen_applied")]
    ScreenApplied { seq: u32, pixel_width: u32, pixel_height: u32, scale: f64 },
    #[serde(rename = "rb.vsync")]
    Vsync { timebase_us: u64, interval_us: u32 },
    #[serde(rename = "rb.page")]
    Page { url: String, title: String, loading: bool, can_go_back: bool, can_go_forward: bool },
    #[serde(rename = "rb.history")]
    History { op: HistoryOp },
    /// The viewer's omnibar or an opened tab: load `url` in the page.
    #[serde(rename = "rb.navigate")]
    Navigate { url: String },
    #[serde(rename = "rb.key_unhandled")]
    KeyUnhandled { input_seq: u32 },
    #[serde(rename = "rb.cursor")]
    Cursor { cursor: CursorShape },
    #[serde(rename = "rb.cursor_image")]
    CursorImage {
        hash: String,
        width: u32,
        height: u32,
        hotspot_x: u32,
        hotspot_y: u32,
        scale: f64,
        png_base64: String,
    },
    #[serde(rename = "rb.tooltip")]
    Tooltip { text: Option<String> },
    #[serde(rename = "rb.status_url")]
    StatusUrl { url: Option<String> },
    #[serde(rename = "rb.text_input")]
    TextInput { input_type: String, composition_rects: Vec<Rect>, caret: Option<Rect> },
    #[serde(rename = "rb.menu.show")]
    MenuShow { token: u64, menu: Menu },
    #[serde(rename = "rb.menu.result")]
    MenuResult { token: u64, choice: MenuChoice },
    #[serde(rename = "rb.menu.cancel")]
    MenuCancel { token: u64 },
    #[serde(rename = "rb.dialog.show")]
    DialogShow { token: u64, dialog: Dialog },
    #[serde(rename = "rb.dialog.result")]
    DialogResult { token: u64, accept: bool, text: Option<String> },
    /// The page closed the dialog itself (it navigated away or went away):
    /// the viewer closes the sheet and sends no answer.
    #[serde(rename = "rb.dialog.cancel")]
    DialogCancel { token: u64 },
    #[serde(rename = "rb.file_chooser.show")]
    FileChooserShow {
        token: u64,
        mode: FileChooserMode,
        accept: Vec<String>,
        default_name: Option<String>,
    },
    #[serde(rename = "rb.file_chooser.result")]
    FileChooserResult { token: u64, files: Option<Vec<UploadRef>> },
    #[serde(rename = "rb.upload.end")]
    UploadEnd { upload: u64, sha256: String },
    #[serde(rename = "rb.download.begin")]
    DownloadBegin {
        download: u64,
        url: String,
        suggested_name: String,
        mime: String,
        total: Option<u64>,
    },
    #[serde(rename = "rb.download.end")]
    DownloadEnd { download: u64, status: DownloadStatus },
    #[serde(rename = "rb.download.cancel")]
    DownloadCancel { download: u64 },
    #[serde(rename = "rb.permission.request")]
    PermissionRequest { token: u64, origin: String, kinds: Vec<PermissionKind> },
    #[serde(rename = "rb.permission.result")]
    PermissionResult { token: u64, grant: bool },
    #[serde(rename = "rb.clipboard.push")]
    ClipboardPush { seq: u32, items: Vec<ClipboardItem> },
    #[serde(rename = "rb.clipboard.write")]
    ClipboardWrite { items: Vec<ClipboardItem> },
    #[serde(rename = "rb.open_tab")]
    OpenTab { request: u64, url: String, disposition: Disposition, user_gesture: bool },
    #[serde(rename = "rb.open_tab.result")]
    OpenTabResult { request: u64, tab: Option<String>, refused: Option<String> },
    /// Viewer asks the page owner to load a URL (cap `navigate`). Hosts
    /// refuse every scheme except http and https before the page sees it.
    #[serde(rename = "rb.navigate")]
    Navigate { request: u64, url: String },
    #[serde(rename = "rb.navigate.result")]
    NavigateResult { request: u64, refused: Option<NavigateRefusal> },
    #[serde(rename = "rb.surface.show")]
    SurfaceShow {
        surface: u32,
        stream: u16,
        kind: SurfaceKind,
        anchor: Rect,
        width: u32,
        height: u32,
    },
    #[serde(rename = "rb.surface.update")]
    SurfaceUpdate { surface: u32, anchor: Rect, width: u32, height: u32 },
    #[serde(rename = "rb.surface.hide")]
    SurfaceHide { surface: u32 },
    #[serde(rename = "rb.find")]
    Find { query: String, forward: bool, match_case: bool, next: bool },
    #[serde(rename = "rb.find.stop")]
    FindStop { keep_selection: bool },
    #[serde(rename = "rb.find.result")]
    FindResult { matches: u32, active: u32 },
    #[serde(rename = "rb.scroll.claim")]
    ScrollClaim { scroller: u64, gesture: u32 },
    #[serde(rename = "rb.scroll.update")]
    ScrollUpdate { scroller: u64, gesture: u32, offset: Point },
    #[serde(rename = "rb.scroll.release")]
    ScrollRelease { scroller: u64, gesture: u32, offset: Point },
    #[serde(rename = "rb.scroll.offset")]
    ScrollOffset { scroller: u64, offset: Point, seq: u32 },
    #[serde(rename = "rb.cookie.change")]
    CookieChange { site: String, change: CookieChange },
}

impl Control {
    /// Parses one control message.
    pub fn from_json(text: &str) -> Result<Self, serde_json::Error> {
        serde_json::from_str(text)
    }

    /// Serializes one control message.
    pub fn to_json(&self) -> String {
        // Every field is a plain value or string, so serialization cannot fail.
        serde_json::to_string(self).unwrap_or_default()
    }
}

/// Modifier bits of input events.
pub mod modifiers {
    pub const SHIFT: u32 = 1;
    pub const CONTROL: u32 = 1 << 1;
    pub const OPTION: u32 = 1 << 2;
    pub const COMMAND: u32 = 1 << 3;
    pub const CAPS_LOCK: u32 = 1 << 4;
    pub const FUNCTION: u32 = 1 << 5;
}

/// A macOS edit command that the viewer's key bindings produced for a key
/// (`moveWordLeft:` and so on, as Chromium names them: `MoveWordLeft`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct EditCommand {
    pub name: String,
    pub value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PointerKind {
    Move,
    Down,
    Up,
    Enter,
    Leave,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    None,
    MayBegin,
    Began,
    Changed,
    Ended,
    Cancelled,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Underline {
    pub start: u32,
    pub end: u32,
    pub thick: bool,
}

/// One browser input event. Production carries a binary form in rd input
/// datagrams (r3); the JSON form is the reference.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "e", rename_all = "snake_case")]
pub enum InputEvent {
    Key {
        surface: u32,
        down: bool,
        code: String,
        key: String,
        text: String,
        unmodified_text: String,
        modifiers: u32,
        repeat: bool,
        location: u8,
        edit_commands: Vec<EditCommand>,
    },
    Pointer {
        surface: u32,
        kind: PointerKind,
        x: f64,
        y: f64,
        button: u8,
        buttons: u8,
        click_count: u8,
        modifiers: u32,
        pointer_type: String,
    },
    Wheel {
        surface: u32,
        x: f64,
        y: f64,
        dx: f64,
        dy: f64,
        precise: bool,
        phase: Phase,
        momentum_phase: Phase,
        modifiers: u32,
    },
    Pinch {
        surface: u32,
        phase: Phase,
        scale: f64,
        x: f64,
        y: f64,
    },
    ImeSetComposition {
        surface: u32,
        text: String,
        underlines: Vec<Underline>,
        selection_start: u32,
        selection_end: u32,
        replacement: Option<[u32; 2]>,
    },
    ImeCommit {
        surface: u32,
        text: String,
        replacement: Option<[u32; 2]>,
    },
    ImeFinish {
        surface: u32,
        keep_selection: bool,
    },
    ImeCancel {
        surface: u32,
    },
}
