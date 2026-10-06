//! The host core against a fake shim: what a viewer's control and input make
//! the host call, and what the viewer gets back.

use cmux_remote_browser::proto::{
    Control, InputEvent, Menu, MenuChoice, MenuItem, MenuKind, Rect, ScreenInfo, SessionState,
    ViewerCaps,
};
use cmux_remote_browser::rp_input::{InputReject, RpCall};
use cmux_remote_browser::session::ScreenSize;
use cmux_remote_browser_host::tab::{HostTab, Presentation};

#[derive(Default)]
struct Fake {
    calls: Vec<String>,
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
        true
    }
    fn input(&mut self, browser: i32, call: &RpCall) -> bool {
        let name = match call {
            RpCall::SendKey { code, commands, .. } => format!("key {code} {}", commands.len()),
            RpCall::PageMouse { kind, .. } => format!("mouse {kind}"),
            other => format!("{other:?}"),
        };
        self.calls.push(format!("input {browser} {name}"));
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

fn item(id: i64, label: &str, item_type: &str) -> MenuItem {
    MenuItem {
        id,
        item_type: item_type.into(),
        label: label.into(),
        enabled: true,
        checked: false,
        items: vec![],
    }
}

fn live_tab(fake: &mut Fake) -> HostTab {
    let mut tab = HostTab::new(1, 41, "https://example.com/");
    tab.control("v1", &open("v1", screen(1200, 800, 2.0)), fake);
    tab.tab_created(7, fake);
    tab.first_frame(fake);
    fake.calls.clear();
    tab
}

#[test]
fn open_sets_the_screen_before_the_window_and_captures_once_the_browser_exists() {
    let mut fake = Fake::default();
    let mut tab = HostTab::new(1, 41, "https://example.com/");
    let out = tab.control("v1", &open("v1", screen(1200, 800, 2.0)), &mut fake);
    assert_eq!(out, vec![Control::Opened { session: 41, main_stream: 0 }]);
    assert_eq!(
        fake.calls,
        vec!["set_screen 1200x800@2", "open_tab 1 https://example.com/ 1200x800"]
    );
    tab.tab_created(7, &mut fake);
    assert_eq!(fake.calls.last().map(String::as_str), Some("capture 7 true"));
    let out = tab.first_frame(&mut fake);
    assert_eq!(out, vec![Control::State { state: SessionState::Live }]);
}

#[test]
fn a_hidden_pane_stops_capture_and_a_screen_change_reports_its_pixel_size() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let out = tab.control("v1", &Control::Visibility { visible: false }, &mut fake);
    assert_eq!(fake.calls, vec!["capture 7 false"]);
    assert_eq!(out, vec![Control::State { state: SessionState::Paused }]);
    fake.calls.clear();
    let out =
        tab.control("v1", &Control::Screen { seq: 3, screen: screen(900, 700, 2.0) }, &mut fake);
    assert_eq!(fake.calls, vec!["set_screen 900x700@2"]);
    assert_eq!(
        out,
        vec![Control::ScreenApplied { seq: 3, pixel_width: 1800, pixel_height: 1400, scale: 2.0 }]
    );
}

#[test]
fn input_maps_to_shim_calls_and_refuses_what_blink_would_drop() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let key = |text: &str| InputEvent::Key {
        surface: 0,
        down: true,
        code: "KeyA".into(),
        key: "a".into(),
        text: text.into(),
        unmodified_text: "a".into(),
        modifiers: 0,
        repeat: false,
        location: 0,
        edit_commands: vec![],
    };
    assert_eq!(tab.input(&key("a"), &mut fake), Ok(true));
    assert_eq!(fake.calls, vec!["input 7 key KeyA 0"]);
    assert_eq!(tab.input(&key("abcd"), &mut fake), Err(InputReject::TextTooLong));
    assert_eq!(fake.calls.len(), 1);
}

#[test]
fn input_before_the_browser_exists_is_not_sent() {
    let mut fake = Fake::default();
    let mut tab = HostTab::new(1, 41, "https://example.com/");
    let click = InputEvent::Pointer {
        surface: 0,
        kind: cmux_remote_browser::proto::PointerKind::Down,
        x: 1.0,
        y: 2.0,
        button: 0,
        buttons: 1,
        click_count: 1,
        modifiers: 0,
        pointer_type: "mouse".into(),
    };
    assert_eq!(tab.input(&click, &mut fake), Ok(false));
    assert!(fake.calls.is_empty());
}

#[test]
fn a_context_menu_round_trips_with_tokens_and_a_late_answer_does_nothing() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let menu = Menu {
        kind: MenuKind::Context,
        anchor: Rect { x: 10.0, y: 20.0, width: 0.0, height: 0.0 },
        surface: 0,
        items: vec![item(50150, "Copy", "command"), item(0, "", "separator")],
        selected: None,
        multiple: false,
        right_aligned: false,
    };
    let out = tab.menu_opened(900, menu.clone(), &mut fake);
    assert_eq!(out, vec![Control::MenuShow { token: 1, menu }]);
    tab.control(
        "v1",
        &Control::MenuResult { token: 1, choice: MenuChoice::Command { id: 50150 } },
        &mut fake,
    );
    assert_eq!(fake.calls, vec!["context_menu_result 900 Some(50150)"]);
    tab.control("v1", &Control::MenuResult { token: 1, choice: MenuChoice::Cancel }, &mut fake);
    assert_eq!(fake.calls.len(), 1, "a duplicate answer reached the shim");
}

#[test]
fn a_select_popup_cancels_the_open_context_menu_in_chromium_and_on_the_viewer() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let context = Menu {
        kind: MenuKind::Context,
        anchor: Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 },
        surface: 0,
        items: vec![item(1, "A", "command")],
        selected: None,
        multiple: false,
        right_aligned: false,
    };
    tab.menu_opened(900, context, &mut fake);
    let select = Menu {
        kind: MenuKind::Select,
        anchor: HostTab::anchor(20, 80, 200, 30),
        surface: 0,
        items: vec![item(0, "Red", "option"), item(1, "Green", "option")],
        selected: Some(1),
        multiple: false,
        right_aligned: false,
    };
    let out = tab.menu_opened(5, select.clone(), &mut fake);
    assert_eq!(fake.calls, vec!["context_menu_result 900 None"]);
    assert_eq!(
        out,
        vec![Control::MenuCancel { token: 1 }, Control::MenuShow { token: 2, menu: select }]
    );
    tab.control(
        "v1",
        &Control::MenuResult { token: 2, choice: MenuChoice::Indices { indices: vec![0] } },
        &mut fake,
    );
    assert_eq!(fake.calls.last().map(String::as_str), Some("popup_menu_result 5 Some([0])"));
}

#[test]
fn the_last_viewer_closing_pauses_and_close_reports_closed() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let out = tab.control("v1", &Control::Close, &mut fake);
    assert_eq!(fake.calls, vec!["capture 7 false"]);
    assert_eq!(
        out,
        vec![
            Control::State { state: SessionState::Paused },
            Control::Closed { reason: "viewer_closed".into() }
        ]
    );
    assert_eq!(tab.state(), SessionState::Paused);
}
