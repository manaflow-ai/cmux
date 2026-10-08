//! The host core against a fake shim: what a viewer's control and input make
//! the host call, and what the viewer gets back.

use cmux_remote_browser::proto::{
    Control, CursorShape, Dialog, DialogKind, Disposition, HistoryOp, InputEvent, Menu, MenuChoice,
    MenuItem, MenuKind, PointerKind, Rect, ScreenInfo, SessionState, SurfaceKind, ViewerCaps,
};
use cmux_remote_browser::rp_input::{InputReject, RpCall};
use cmux_remote_browser::session::ScreenSize;
use cmux_remote_browser_host::tab::{HostTab, PageChange, Presentation, SurfaceOut};

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
    fake.ui.clear();
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

fn rect(x: f64, y: f64, width: f64, height: f64) -> Rect {
    Rect { x, y, width, height }
}

fn show(surface: u32, stream: u16, anchor: Rect, width: u32, height: u32) -> SurfaceOut {
    SurfaceOut::Control(Control::SurfaceShow {
        surface,
        stream,
        kind: SurfaceKind::PagePopup,
        anchor,
        width,
        height,
    })
}

#[test]
fn a_page_popup_gets_its_own_stream_on_its_first_frame_and_goes_with_its_widget() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let at = rect(10.0, 20.0, 200.0, 150.0);
    let out = tab.surface_changed(5, SurfaceKind::PagePopup, true, at, &mut fake);
    assert!(out.is_empty(), "nothing to show before the surface has pixels: {out:?}");
    assert_eq!(fake.ui, vec!["surface_capture 5"]);
    // The first frame gives it a stream; the stream exists before the show.
    let out = tab.surface_frame(5, 400, 300);
    assert_eq!(
        out,
        vec![
            SurfaceOut::AddStream { surface: 5, stream: 1, width: 400, height: 300 },
            show(5, 1, at, 400, 300),
        ]
    );
    assert_eq!(tab.surface_stream(5), Some(1));
    assert!(tab.surface_frame(5, 400, 300).is_empty(), "same size: same stream");
    // Pointer input to the surface goes to the surface.
    assert_eq!(tab.input(&pointer(5, PointerKind::Down, 30.0, 40.0, 0), &mut fake), Ok(true));
    assert!(matches!(fake.sent.last(), Some(RpCall::SurfaceMouse { surface: 5, kind: 1, .. })));
    // The widget moved.
    let moved = rect(12.0, 22.0, 200.0, 150.0);
    let out = tab.surface_changed(5, SurfaceKind::PagePopup, true, moved, &mut fake);
    assert_eq!(
        out,
        vec![SurfaceOut::Control(Control::SurfaceUpdate {
            surface: 5,
            anchor: moved,
            width: 400,
            height: 300
        })]
    );
    // The page closed it: hide, drop the stream, forget its held button.
    let out = tab.surface_changed(5, SurfaceKind::PagePopup, false, moved, &mut fake);
    assert_eq!(
        out,
        vec![
            SurfaceOut::Control(Control::SurfaceHide { surface: 5 }),
            SurfaceOut::RemoveStream { stream: 1 },
        ]
    );
    assert_eq!(tab.surface_stream(5), None);
    assert_eq!(tab.held(), (0, 0), "a gone surface holds no button");
    fake.sent.clear();
    assert_eq!(tab.input(&pointer(5, PointerKind::Up, 30.0, 40.0, 0), &mut fake), Ok(false));
    assert!(fake.sent.is_empty(), "input to a gone surface is dropped");
    assert!(tab.surface_frame(5, 400, 300).is_empty(), "a late frame of a gone surface");
}

#[test]
fn a_popup_that_changes_size_moves_to_a_new_stream_and_each_popup_has_its_own() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let at = rect(0.0, 0.0, 100.0, 50.0);
    tab.surface_changed(5, SurfaceKind::PagePopup, true, at, &mut fake);
    tab.surface_frame(5, 200, 100);
    let out = tab.surface_frame(5, 200, 160);
    assert_eq!(
        out,
        vec![
            SurfaceOut::Control(Control::SurfaceHide { surface: 5 }),
            SurfaceOut::RemoveStream { stream: 1 },
            SurfaceOut::AddStream { surface: 5, stream: 2, width: 200, height: 160 },
            show(5, 2, at, 200, 160),
        ]
    );
    tab.surface_changed(6, SurfaceKind::PagePopup, true, at, &mut fake);
    let out = tab.surface_frame(6, 64, 64);
    let add = SurfaceOut::AddStream { surface: 6, stream: 3, width: 64, height: 64 };
    assert_eq!(out.first(), Some(&add));
}

#[test]
fn the_tab_is_active_while_captured_and_a_hidden_tab_closes_its_popups() {
    let mut fake = Fake::default();
    let mut tab = HostTab::new(1, 41, "https://example.com/");
    tab.control("v1", &open("v1", screen(1200, 800, 2.0)), &mut fake);
    tab.tab_created(7, &mut fake);
    assert_eq!(fake.ui, vec!["set_active 7 true"], "page popups open only in an active tab");
    tab.first_frame(&mut fake);
    tab.surface_changed(5, SurfaceKind::PagePopup, true, rect(0.0, 0.0, 10.0, 10.0), &mut fake);
    fake.ui.clear();
    tab.control("v1", &Control::Visibility { visible: false }, &mut fake);
    assert_eq!(fake.ui, vec!["surface_close 5", "set_active 7 false"]);
}

#[test]
fn release_all_releases_a_button_held_on_a_popup_surface() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    tab.surface_changed(5, SurfaceKind::PagePopup, true, rect(0.0, 0.0, 10.0, 10.0), &mut fake);
    tab.surface_frame(5, 20, 20);
    tab.input(&pointer(5, PointerKind::Down, 3.0, 4.0, 0), &mut fake).expect("valid");
    fake.sent.clear();
    tab.release_all(&mut fake);
    assert_eq!(
        fake.sent,
        vec![RpCall::SurfaceMouse {
            surface: 5,
            kind: 2,
            x: 3.0,
            y: 4.0,
            button: 0,
            click_count: 1,
            modifiers: 0
        }]
    );
}

#[test]
fn navigate_loads_the_url_in_the_main_frame() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let out = tab.control(
        "v1",
        &Control::Navigate { request: None, url: "https://cmux.com/".into() },
        &mut fake,
    );
    assert!(out.is_empty());
    assert_eq!(fake.calls, vec!["load_url 7 https://cmux.com/"]);
}

#[test]
fn navigate_before_the_browser_exists_loads_once_it_does() {
    let mut fake = Fake::default();
    let mut tab = HostTab::new(1, 41, "https://example.com/");
    tab.control("v1", &open("v1", screen(1200, 800, 2.0)), &mut fake);
    tab.control(
        "v1",
        &Control::Navigate { request: None, url: "https://cmux.com/".into() },
        &mut fake,
    );
    assert!(!fake.calls.iter().any(|c| c.starts_with("load_url")));
    tab.tab_created(7, &mut fake);
    assert!(fake.calls.iter().any(|c| c == "load_url 7 https://cmux.com/"), "{:?}", fake.calls);
}

#[test]
fn history_ops_reach_the_shim() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    for op in [
        HistoryOp::Back,
        HistoryOp::Forward,
        HistoryOp::Reload,
        HistoryOp::ReloadNoCache,
        HistoryOp::Stop,
    ] {
        assert!(tab.control("v1", &Control::History { op }, &mut fake).is_empty());
    }
    assert_eq!(
        fake.calls,
        vec![
            "history 7 Back",
            "history 7 Forward",
            "history 7 Reload",
            "history 7 ReloadNoCache",
            "history 7 Stop",
        ]
    );
}

fn page(url: &str, title: &str, loading: bool, back: bool, forward: bool) -> Control {
    Control::Page {
        url: url.into(),
        title: title.into(),
        loading,
        can_go_back: back,
        can_go_forward: forward,
    }
}

#[test]
fn every_page_fact_change_sends_rb_page_and_a_repeat_sends_nothing() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let loading = PageChange::Loading { loading: true, can_go_back: false, can_go_forward: false };
    assert_eq!(tab.page_changed(loading.clone()), Some(page("", "", true, false, false)));
    let url = PageChange::Url("https://cmux.com/".into());
    assert_eq!(
        tab.page_changed(url.clone()),
        Some(page("https://cmux.com/", "", true, false, false))
    );
    assert_eq!(tab.page_changed(url), None, "the same URL again");
    assert_eq!(
        tab.page_changed(PageChange::Title("cmux".into())),
        Some(page("https://cmux.com/", "cmux", true, false, false))
    );
    let done = PageChange::Loading { loading: false, can_go_back: true, can_go_forward: false };
    assert_eq!(tab.page_changed(done), Some(page("https://cmux.com/", "cmux", false, true, false)));
    assert_eq!(
        tab.page_changed(loading.clone()),
        Some(page("https://cmux.com/", "cmux", true, false, false))
    );
}

#[test]
fn a_reopen_by_the_same_viewer_applies_its_screen_without_a_second_opened() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    let out = tab.control("v1", &open("v1", screen(1000, 700, 2.0)), &mut fake);
    assert!(!out.iter().any(|c| matches!(c, Control::Opened { .. })), "{out:?}");
    assert!(
        out.contains(&Control::ScreenApplied {
            seq: 0,
            pixel_width: 2000,
            pixel_height: 1400,
            scale: 2.0
        }),
        "{out:?}"
    );
    assert_eq!(fake.calls, vec!["set_screen 1000x700@2"]);
}

#[test]
fn a_viewer_that_opens_after_the_page_loaded_gets_rb_page() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    tab.page_changed(PageChange::Url("https://cmux.com/".into()));
    tab.page_changed(PageChange::Title("cmux".into()));
    let out = tab.control("v2", &open("v2", screen(1200, 800, 2.0)), &mut fake);
    assert!(out.contains(&page("https://cmux.com/", "cmux", false, false, false)), "{out:?}");
}

#[test]
fn an_unhandled_key_names_the_seq_of_the_last_key_down_once() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    assert_eq!(tab.input_seq(&key_event(true, "KeyJ", "j"), Some(41), &mut fake), Ok(true));
    assert_eq!(tab.input_seq(&key_event(false, "KeyJ", "j"), Some(42), &mut fake), Ok(true));
    assert_eq!(tab.key_unhandled(), Some(Control::KeyUnhandled { input_seq: 41 }));
    assert_eq!(tab.key_unhandled(), None, "reported once");
    assert_eq!(tab.input_seq(&key_event(true, "KeyK", "k"), None, &mut fake), Ok(true));
    assert_eq!(tab.key_unhandled(), None, "an unknown seq is never guessed");
}

fn cursor(kind: &str) -> Control {
    Control::Cursor { cursor: CursorShape { kind: kind.into(), hash: None } }
}

#[test]
fn cursor_changes_map_cef_types_to_css_names_once_per_change() {
    let mut fake = Fake::default();
    let mut tab = live_tab(&mut fake);
    // cef_cursor_type_t: CT_HAND 2, CT_IBEAM 3, CT_POINTER 0, CT_GRABBING 42.
    assert_eq!(tab.cursor_changed(2), Some(cursor("pointer")));
    assert_eq!(tab.cursor_changed(2), None);
    assert_eq!(tab.cursor_changed(3), Some(cursor("text")));
    assert_eq!(tab.cursor_changed(42), Some(cursor("grabbing")));
    assert_eq!(tab.cursor_changed(0), Some(cursor("default")));
    assert_eq!(tab.cursor_changed(9999), None, "an unknown type keeps the last shape");
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
