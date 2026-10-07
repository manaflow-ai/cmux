//! The host core against a fake shim: what a viewer's control and input make
//! the host call, and what the viewer gets back.

use cmux_remote_browser::proto::{
    Control, Dialog, DialogKind, InputEvent, Menu, MenuChoice, MenuItem, MenuKind, PointerKind,
    Rect, ScreenInfo, SessionState, ViewerCaps,
};
use cmux_remote_browser::rp_input::{InputReject, RpCall};
use cmux_remote_browser::session::ScreenSize;
use cmux_remote_browser_host::tab::{HostTab, Presentation};

#[derive(Default)]
struct Fake {
    calls: Vec<String>,
    /// The shim refuses capture (the browser has no view yet).
    refuse_capture: bool,
    /// Every input call, as sent.
    sent: Vec<RpCall>,
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
    // rb.open carries the viewer's first screen as seq 0 (remote-tab-protocol.md section 2).
    assert_eq!(
        out,
        vec![
            Control::Opened { session: 41, main_stream: 0 },
            Control::ScreenApplied { seq: 0, pixel_width: 2400, pixel_height: 1600, scale: 2.0 },
        ]
    );
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
        kind: PointerKind::Down,
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

#[test]
fn each_viewer_gets_its_own_last_screen_seq() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    tab.control("v1", &Control::Screen { seq: 4, screen: screen(1000, 800, 2.0) }, &mut fake);
    // A second viewer joins with a smaller screen: its reply echoes its seq 0,
    // and v1 is owed the new size under v1's own last seq (4).
    let out = tab.control("v2", &open("v2", screen(800, 600, 1.0)), &mut fake);
    assert_eq!(
        out.last(),
        Some(&Control::ScreenApplied { seq: 0, pixel_width: 1600, pixel_height: 1200, scale: 2.0 })
    );
    assert_eq!(
        tab.screen_applied("v1"),
        Some(Control::ScreenApplied { seq: 4, pixel_width: 1600, pixel_height: 1200, scale: 2.0 })
    );
    assert_eq!(tab.screen_applied("v3"), None);
}

#[test]
fn an_invalid_menu_choice_cancels_the_menu_in_chromium_and_on_the_viewer() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let menu = Menu {
        kind: MenuKind::Context,
        anchor: Rect { x: 10.0, y: 20.0, width: 0.0, height: 0.0 },
        surface: 0,
        items: vec![item(50150, "Copy", "command")],
        selected: None,
        multiple: false,
        right_aligned: false,
    };
    tab.menu_opened(900, menu, &mut fake);
    // A command the menu never showed: the host does not leave Chromium
    // waiting on a viewer that sends bad answers.
    let out = tab.control(
        "v1",
        &Control::MenuResult { token: 1, choice: MenuChoice::Command { id: 999 } },
        &mut fake,
    );
    assert_eq!(fake.calls, vec!["context_menu_result 900 None"]);
    assert_eq!(out, vec![Control::MenuCancel { token: 1 }]);
    tab.control(
        "v1",
        &Control::MenuResult { token: 1, choice: MenuChoice::Command { id: 50150 } },
        &mut fake,
    );
    assert_eq!(fake.calls.len(), 1, "an answer after the cancel reached the shim");
}

fn dialog(kind: DialogKind, message: &str) -> Dialog {
    Dialog {
        kind,
        origin: "https://example.com".into(),
        message: message.into(),
        default_text: None,
        is_reload: false,
    }
}

#[test]
fn a_dialog_round_trips_with_tokens_and_a_late_answer_does_nothing() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let prompt = dialog(DialogKind::Prompt, "Name?");
    let out = tab.dialog_opened(77, prompt.clone(), &mut fake);
    assert_eq!(out, vec![Control::DialogShow { token: 1, dialog: prompt }]);
    let answer = Control::DialogResult { token: 1, accept: true, text: Some("Grace".into()) };
    tab.control("v1", &answer, &mut fake);
    assert_eq!(fake.calls, vec![r#"dialog_result 77 true Some("Grace")"#]);
    tab.control("v1", &answer, &mut fake);
    assert_eq!(fake.calls.len(), 1, "a duplicate answer reached the shim");
}

#[test]
fn navigating_away_with_a_dialog_open_cancels_it_on_the_viewer() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    tab.dialog_opened(77, dialog(DialogKind::Alert, "Saved"), &mut fake);
    // Chromium reset its dialog state (the page navigated away): its
    // callback is gone, so the shim gets nothing and the viewer closes the sheet.
    assert_eq!(tab.dialog_reset(), vec![Control::DialogCancel { token: 1 }]);
    assert!(fake.calls.is_empty());
    tab.control("v1", &Control::DialogResult { token: 1, accept: true, text: None }, &mut fake);
    assert!(fake.calls.is_empty(), "an answer after the cancel reached the shim");
    assert_eq!(tab.dialog_reset(), vec![]);
    // The next dialog gets a new token.
    let out = tab.dialog_opened(78, dialog(DialogKind::Confirm, "Leave?"), &mut fake);
    assert_eq!(
        out,
        vec![Control::DialogShow { token: 2, dialog: dialog(DialogKind::Confirm, "Leave?") }]
    );
}

#[test]
fn a_new_dialog_cancels_the_one_still_open_on_the_viewer() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    tab.dialog_opened(77, dialog(DialogKind::Alert, "One"), &mut fake);
    let two = dialog(DialogKind::Alert, "Two");
    let out = tab.dialog_opened(78, two.clone(), &mut fake);
    assert_eq!(
        out,
        vec![Control::DialogCancel { token: 1 }, Control::DialogShow { token: 2, dialog: two }]
    );
}

#[test]
fn a_refused_capture_is_retried_until_the_shim_accepts_it() {
    let mut fake = Fake { refuse_capture: true, ..Fake::default() };
    let mut tab = HostTab::new(1, 7, "https://example.com/");
    tab.control("v1", &open("v1", screen(800, 600, 2.0)), &mut fake);
    tab.tab_created(42, &mut fake);
    assert!(!tab.capturing(), "the shim refused: no capture yet");
    fake.calls.clear();
    fake.refuse_capture = false;
    tab.retry_capture(&mut fake);
    assert_eq!(fake.calls, vec!["capture 42 true".to_string()]);
    assert!(tab.capturing());
    fake.calls.clear();
    tab.retry_capture(&mut fake);
    assert!(fake.calls.is_empty(), "a running capture is not started twice");
}

#[test]
fn a_select_popup_the_page_closed_is_cancelled_on_the_viewer_only() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let menu = Menu {
        kind: MenuKind::Select,
        anchor: Rect { x: 0.0, y: 0.0, width: 10.0, height: 10.0 },
        surface: 0,
        items: vec![item(0, "Red", "option"), item(1, "Green", "option")],
        selected: Some(0),
        multiple: false,
        right_aligned: false,
    };
    let shown = tab.menu_opened(77, menu, &mut fake);
    let Some(Control::MenuShow { token, .. }) = shown.first().cloned() else {
        panic!("menu shown: {shown:?}");
    };
    fake.calls.clear();
    assert!(tab.menu_closed_by_page(76).is_empty(), "another fork token is stale");
    assert_eq!(tab.menu_closed_by_page(77), vec![Control::MenuCancel { token }]);
    assert!(fake.calls.is_empty(), "Chromium closed it: no answer goes back");
    let late = Control::MenuResult { token, choice: MenuChoice::Indices { indices: vec![1] } };
    tab.control("v1", &late, &mut fake);
    assert!(fake.calls.is_empty(), "a late viewer answer reaches nothing");
}

fn key_event(down: bool, code: &str, key: &str) -> InputEvent {
    InputEvent::Key {
        surface: 0,
        down,
        code: code.into(),
        key: key.into(),
        // Named keys (Shift) carry no text.
        text: if down && key.chars().count() == 1 { key.into() } else { String::new() },
        unmodified_text: if down && key.chars().count() == 1 { key.into() } else { String::new() },
        modifiers: 0,
        repeat: false,
        location: 0,
        edit_commands: vec![],
    }
}

fn pointer(surface: u32, kind: PointerKind, x: f64, y: f64, button: u8) -> InputEvent {
    InputEvent::Pointer {
        surface,
        kind,
        x,
        y,
        button,
        buttons: if kind == PointerKind::Down { 1 } else { 0 },
        click_count: 1,
        modifiers: 0,
        pointer_type: "mouse".into(),
    }
}

fn key_up(code: &str, key: &str) -> RpCall {
    RpCall::SendKey {
        down: false,
        code: code.into(),
        key: key.into(),
        text: String::new(),
        unmodified_text: String::new(),
        modifiers: 0,
        commands: vec![],
    }
}

fn page_up(x: f64, y: f64, button: i32) -> RpCall {
    RpCall::PageMouse { kind: 2, x, y, button, click_count: 1, modifiers: 0 }
}

#[test]
fn release_all_releases_every_held_key_and_button_once() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    for event in [
        key_event(true, "ShiftLeft", "Shift"),
        key_event(true, "KeyA", "A"),
        key_event(true, "KeyB", "B"),
        key_event(false, "KeyB", ""),
        pointer(0, PointerKind::Down, 10.0, 20.0, 0),
        pointer(0, PointerKind::Move, 30.0, 40.0, 0),
        pointer(0, PointerKind::Down, 30.0, 40.0, 2),
        pointer(0, PointerKind::Up, 31.0, 41.0, 2),
    ] {
        assert_eq!(tab.input(&event, &mut fake), Ok(true));
    }
    fake.sent.clear();
    tab.release_all(&mut fake);
    // KeyB and the right button were released by the viewer; the left
    // button goes up where the pointer was last.
    assert_eq!(
        fake.sent,
        vec![key_up("KeyA", "A"), key_up("ShiftLeft", "Shift"), page_up(31.0, 41.0, 0)]
    );
    fake.sent.clear();
    tab.release_all(&mut fake);
    assert!(fake.sent.is_empty(), "a second release_all sends nothing: {:?}", fake.sent);
}

#[test]
fn a_key_repeat_holds_one_key_and_a_viewer_closing_releases_what_it_held() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    for _ in 0..3 {
        assert_eq!(tab.input(&key_event(true, "KeyW", "w"), &mut fake), Ok(true));
    }
    fake.sent.clear();
    tab.control("v1", &Control::Close, &mut fake);
    assert_eq!(fake.sent, vec![key_up("KeyW", "w")]);
}
