//! The host core against a fake shim: what a viewer's control and input make
//! the host call, and what the viewer gets back.

use cmux_remote_browser::proto::{
    Control, CursorShape, Dialog, DialogKind, Disposition, HistoryOp, InputEvent, Menu, MenuChoice,
    MenuItem, MenuKind, PointerKind, Rect, ScreenInfo, SessionState, SurfaceKind, ViewerCaps,
};
use cmux_remote_browser::rp_input::{InputReject, RpCall};
use cmux_remote_browser::session::ScreenSize;
use cmux_remote_browser_host::tab::{
    HostTab, PageChange, Presentation, SurfaceOut, fork_surface_kind,
};

#[derive(Default)]
struct Fake {
    calls: Vec<String>,
    /// The shim refuses capture (the browser has no view yet).
    refuse_capture: bool,
    /// Every input call, as sent.
    sent: Vec<RpCall>,
    /// Activation and popup surface calls (kept apart from `calls`).
    ui: Vec<String>,
}

impl Presentation for Fake {
    fn set_screen(&mut self, s: ScreenSize) -> bool {
        self.calls.push(format!("set_screen {}x{}@{}", s.css_width, s.css_height, s.scale));
        true
    }
    fn open_tab(&mut self, request: i32, url: &str, s: ScreenSize) -> bool {
        self.calls.push(format!("open_tab {request} {url} {}x{}", s.css_width, s.css_height));
        true
    }
    fn close_tab(&mut self, browser: i32) {
        self.calls.push(format!("close_tab {browser}"));
    }
    fn capture(&mut self, browser: i32, on: bool) -> bool {
        self.calls.push(format!("capture {browser} {on}"));
        !self.refuse_capture
    }
    fn input(&mut self, browser: i32, call: &RpCall) -> bool {
        let name = match call {
            RpCall::SendKey { code, commands, .. } => format!("key {code} {}", commands.len()),
            RpCall::PageMouse { kind, .. } => format!("mouse {kind}"),
            other => format!("{other:?}"),
        };
        self.calls.push(format!("input {browser} {name}"));
        self.sent.push(call.clone());
        true
    }
    fn context_menu_result(&mut self, fork_token: i64, command: Option<i64>) -> bool {
        self.calls.push(format!("context_menu_result {fork_token} {command:?}"));
        true
    }
    fn popup_menu_result(&mut self, fork_token: i64, indices: Option<&[u32]>) -> bool {
        self.calls.push(format!("popup_menu_result {fork_token} {indices:?}"));
        true
    }
    fn dialog_result(&mut self, fork_token: i64, accept: bool, text: Option<&str>) -> bool {
        self.calls.push(format!("dialog_result {fork_token} {accept} {text:?}"));
        true
    }
    fn set_active(&mut self, browser: i32, active: bool) -> bool {
        self.ui.push(format!("set_active {browser} {active}"));
        true
    }
    fn surface_capture(&mut self, surface: u32) -> bool {
        self.ui.push(format!("surface_capture {surface}"));
        true
    }
    fn surface_close(&mut self, surface: u32) {
        self.ui.push(format!("surface_close {surface}"));
    }
    fn surface_refresh(&mut self, surface: u32) -> bool {
        self.ui.push(format!("surface_refresh {surface}"));
        true
    }
    fn load_url(&mut self, browser: i32, url: &str) -> bool {
        self.calls.push(format!("load_url {browser} {url}"));
        true
    }
    fn history(&mut self, browser: i32, op: HistoryOp) -> bool {
        self.calls.push(format!("history {browser} {op:?}"));
        true
    }
}

fn screen(w: u32, h: u32, scale: f64) -> ScreenInfo {
    ScreenInfo { css_width: w, css_height: h, scale, refresh_hz: 60, color_space: "srgb".into() }
}

fn open(viewer: &str, s: ScreenInfo) -> Control {
    Control::Open {
        tab: "tab-1".into(),
        profile: "remote".into(),
        viewer: viewer.into(),
        screen: s,
        caps: ViewerCaps { codecs: vec!["h264".into()], tile_codecs: vec![], max_fps: 60 },
    }
}

fn live_tab(fake: &mut Fake) -> HostTab {
    let mut tab = HostTab::new(1, 41, "https://example.com/");
    tab.control("v1", &open("v1", screen(1200, 800, 2.0)), fake);
    tab.tab_created(7, fake);
    tab.first_frame(fake);
    fake.calls.clear();
    fake.ui.clear();
    tab
}

#[test]
fn a_page_popup_asks_the_app_for_a_tab_with_rising_requests() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    // cef_window_open_disposition_t: 3 foreground tab, 4 background tab,
    // 5 popup, 6 new window, 7 save to disk.
    assert_eq!(
        tab.popup_requested("https://a.example/", 4, true),
        Some(Control::OpenTab {
            request: 1,
            url: "https://a.example/".into(),
            disposition: Disposition::BackgroundTab,
            user_gesture: true,
        })
    );
    let popup = tab.popup_requested("https://b.example/", 5, false);
    assert!(
        matches!(popup, Some(Control::OpenTab { request: 2, disposition: Disposition::Popup, .. })),
        "{popup:?}"
    );
    let window = tab.popup_requested("https://c.example/", 6, true);
    assert!(
        matches!(window, Some(Control::OpenTab { disposition: Disposition::NewWindow, .. })),
        "{window:?}"
    );
    assert_eq!(tab.popup_requested("https://d.example/", 7, true), None, "save to disk");
    // CEF_WOD_OFF_THE_RECORD (8): an incognito open never becomes a normal tab.
    assert_eq!(tab.popup_requested("https://e.example/", 8, true), None, "off the record");
    let answer = Control::OpenTabResult { request: 1, tab: Some("tab-2".into()), refused: None };
    assert!(tab.control("v1", &answer, &mut fake).is_empty());
    assert!(fake.calls.is_empty());
}
