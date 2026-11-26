//! Parity tests for the viewer rules (`view/`), ported from the Swift suites
//! they replace: MacScreenSystemShortcutTapTests, RemoteKeyTextDecisionTests,
//! RemoteLatencyHoldTests, RemotePaneQuietReconnectTests,
//! RemoteScrollAccumulatorTests and RemoteViewTabPolicyTests. The JSON tests
//! go through `cmux_rd_view_call`, as the Swift shell will.

use serde_json::{Value, json};

use crate::view::keyboard::{
    self, InputEvent, KeyboardMode, KeyboardState, ReleaseChord, Route, ScrollAccumulator,
    SystemShortcuts, TapConditions, TapKey, flags, phase,
};
use crate::view::pane::{
    self, CONNECT_NOTICE_DELAY_NS, ControlMode, LATENCY_SUSTAIN_NS, Overlay, PaneEvent, PaneState,
    RECONNECT_NOTICE_DELAY_NS, SessionEnd, SessionState, ViewStatus,
};
use crate::view::tab::{self, TabDecision, TabRecord, TabSource, Target, UnavailableReason};
use crate::{
    CMUX_RD_ERR_INVALID, CMUX_RD_ERR_NULL, CMUX_RD_OK, cmux_rd_view_call, cmux_rd_view_free,
    cmux_rd_view_new,
};

const CMD: u64 = flags::COMMAND;
const CTL: u64 = flags::CONTROL;
const OPT: u64 = flags::OPTION;
const SH: u64 = flags::SHIFT;

fn call(request: Value) -> Value {
    let view = cmux_rd_view_new();
    let bytes = request.to_string();
    let mut out: *const u8 = std::ptr::null();
    let mut len = 0usize;
    // SAFETY: a live handle and readable bytes; out pointers are writable.
    let code = unsafe { cmux_rd_view_call(view, bytes.as_ptr(), bytes.len(), &mut out, &mut len) };
    assert_eq!(code, CMUX_RD_OK, "{request}");
    // SAFETY: valid until the next call on `view`.
    let value = serde_json::from_slice(unsafe { std::slice::from_raw_parts(out, len) }).unwrap();
    // SAFETY: from cmux_rd_view_new, not used again.
    unsafe { cmux_rd_view_free(view) };
    value
}

fn key(usage: u32, down: bool) -> InputEvent {
    InputEvent::Key { usage, down }
}

// MARK: - MacScreenSystemShortcutTapTests

mod k {
    pub const SPACE: u16 = 0x31;
    pub const TAB: u16 = 0x30;
    pub const GRAVE: u16 = 0x32;
    pub const ESCAPE: u16 = 0x35;
    pub const UP: u16 = 0x7E;
    pub const DOWN: u16 = 0x7D;
    pub const LEFT: u16 = 0x7B;
    pub const RIGHT: u16 = 0x7C;
    pub const THREE: u16 = 0x14;
    pub const FOUR: u16 = 0x15;
    pub const FIVE: u16 = 0x17;
    pub const Q: u16 = 0x0C;
    pub const W: u16 = 0x0D;
    pub const H: u16 = 0x04;
    pub const M: u16 = 0x2E;
    pub const T: u16 = 0x11;
    pub const A: u16 = 0x00;
    pub const C: u16 = 0x08;
    pub const RETURN: u16 = 0x24;
}

#[test]
fn installs_only_while_every_condition_holds() {
    let all = TapConditions {
        setting: true,
        accessibility: true,
        has_keyboard: true,
        live: true,
        window_key: true,
        app_active: true,
    };
    assert!(all.installs());
    for i in 0..6 {
        let mut c = all;
        let field = match i {
            0 => &mut c.setting,
            1 => &mut c.accessibility,
            2 => &mut c.has_keyboard,
            3 => &mut c.live,
            4 => &mut c.window_key,
            _ => &mut c.app_active,
        };
        *field = false;
        assert!(!c.installs());
    }
    assert!(!TapConditions::default().installs());
    assert_eq!(
        call(json!({"op": "shortcuts.installs", "conditions": {"setting": true}})),
        json!(false)
    );
}

#[test]
fn takes_system_chords_and_passes_everything_else() {
    let policy = SystemShortcuts::default();
    let system = [
        (k::SPACE, CMD),
        (k::SPACE, CMD | OPT),
        (k::SPACE, CTL),
        (k::TAB, CMD),
        (k::TAB, CMD | SH),
        (k::GRAVE, CMD),
        (k::UP, CTL),
        (k::DOWN, CTL),
        (k::LEFT, CTL),
        (k::RIGHT, CTL),
        (k::THREE, CMD | SH),
        (k::FOUR, CMD | SH),
        (k::FIVE, CMD | SH),
        (k::Q, CTL | CMD),
        (k::Q, CMD),
        (k::W, CMD),
        (k::H, CMD),
        (k::M, CMD),
    ];
    for (code, mods) in system {
        assert!(policy.takes(code, mods), "key {code} modifiers {mods}");
    }
    let other = [
        (k::A, 0),
        (k::A, SH),
        (k::SPACE, 0),
        (k::TAB, 0),
        (k::RETURN, 0),
        (k::UP, 0),
        (k::C, CMD),
        (k::T, CMD),
        (k::T, CMD | SH),
    ];
    for (code, mods) in other {
        assert!(!policy.takes(code, mods), "key {code} modifiers {mods}");
    }
}

#[test]
fn never_takes_the_release_chord() {
    let policy = SystemShortcuts::default();
    assert!(!policy.takes(k::ESCAPE, CTL | OPT));
    let rebound = SystemShortcuts {
        release_chord: ReleaseChord { key_code: k::UP, modifiers: CTL },
        ..Default::default()
    };
    assert!(!rebound.takes(k::UP, CTL));
    assert!(rebound.takes(k::DOWN, CTL));
}

#[test]
fn a_taken_chord_sends_its_key_and_its_up() {
    let mut policy = SystemShortcuts::default();
    let mut keyboard = KeyboardState::default();
    assert_eq!(keyboard::usage(k::SPACE), Some(0x0007_002C));
    let tap =
        |key_code, modifiers, down, is_repeat| TapKey { key_code, modifiers, down, is_repeat };
    assert_eq!(
        policy.route(tap(k::SPACE, CMD, true, false), &mut keyboard),
        Some(vec![key(0x0007_002C, true)])
    );
    assert_eq!(policy.route(tap(k::SPACE, CMD, true, true), &mut keyboard), Some(vec![]));
    assert_eq!(
        policy.route(tap(k::SPACE, 0, false, false), &mut keyboard),
        Some(vec![key(0x0007_002C, false)])
    );
    assert!(keyboard.held_keys.is_empty());
    assert_eq!(policy.route(tap(k::A, 0, true, false), &mut keyboard), None);
    assert_eq!(policy.route(tap(k::A, 0, false, false), &mut keyboard), None);
    assert_eq!(policy.route(tap(k::ESCAPE, CTL | OPT, true, false), &mut keyboard), None);
}

#[test]
fn shortcuts_route_round_trips_its_state_as_json() {
    let down = call(
        json!({"op": "shortcuts.route", "key": {"keyCode": k::TAB, "modifiers": CMD | SH, "down": true}}),
    );
    assert_eq!(down["events"], json!([{"kind": "key", "usage": 0x0007_002B, "down": true}]));
    assert_eq!(down["shortcuts"]["heldByTap"], json!([k::TAB]));
    let up = call(json!({
        "op": "shortcuts.route", "shortcuts": down["shortcuts"], "keyboard": down["keyboard"],
        "key": {"keyCode": k::TAB, "modifiers": 0, "down": false},
    }));
    assert_eq!(up["events"], json!([{"kind": "key", "usage": 0x0007_002B, "down": false}]));
    assert_eq!(up["keyboard"]["heldKeys"], json!([]));
    let passed = call(
        json!({"op": "shortcuts.route", "key": {"keyCode": k::A, "modifiers": 0, "down": true}}),
    );
    assert_eq!(passed["events"], Value::Null);
}

// MARK: - RemoteKeyTextDecisionTests

#[test]
fn policy_keeps_chords_dead_keys_and_control_characters_physical() {
    assert!(keyboard::sends_as_text(Some("é"), Some("a"), 0));
    assert!(keyboard::sends_as_text(Some("😀"), Some("a"), 0));
    assert!(!keyboard::sends_as_text(Some("A"), Some("A"), SH));
    assert!(!keyboard::sends_as_text(Some("x"), Some("a"), CMD));
    assert!(!keyboard::sends_as_text(Some(""), Some("´"), OPT));
    assert!(!keyboard::sends_as_text(Some("\r"), Some("a"), 0));
    assert!(!keyboard::sends_as_text(Some("\u{F702}"), None, 0));
    assert!(!keyboard::sends_as_text(Some("x"), None, 0));
    assert_eq!(
        call(json!({"op": "keyboard.sendsAsText", "characters": "x", "layoutCharacters": "a"})),
        json!(true)
    );
}

// MARK: - RemoteKeyboardPolicy

#[test]
fn route_follows_release_chord_then_system_then_text_mode() {
    let chord = ReleaseChord::default();
    let r = |code, mods, mode, send, ascii, local| {
        keyboard::route(code, mods, mode, send, ascii, chord, local)
    };
    assert_eq!(
        r(k::ESCAPE, CTL | OPT | flags::CAPS_LOCK, KeyboardMode::Auto, true, true, false),
        Route::ReleaseKeyboard
    );
    assert_eq!(r(k::TAB, CMD, KeyboardMode::Auto, false, true, false), Route::Local);
    assert_eq!(r(k::TAB, CMD, KeyboardMode::Auto, true, true, false), Route::Physical);
    assert_eq!(r(k::T, CMD, KeyboardMode::Auto, false, true, true), Route::Local);
    assert_eq!(r(k::T, CMD, KeyboardMode::Auto, true, true, true), Route::Physical);
    assert_eq!(r(k::A, 0, KeyboardMode::Auto, false, true, false), Route::Physical);
    assert_eq!(r(k::A, 0, KeyboardMode::Auto, false, false, false), Route::TextInput);
    assert_eq!(r(k::A, 0, KeyboardMode::Text, false, true, false), Route::TextInput);
    assert_eq!(r(k::A, 0, KeyboardMode::Physical, false, false, false), Route::Physical);
    assert_eq!(r(k::RETURN, 0, KeyboardMode::Text, false, true, false), Route::Physical);
    assert_eq!(r(k::A, CTL, KeyboardMode::Text, false, true, false), Route::Physical);
    assert_eq!(
        call(json!({"op": "keyboard.route", "keyCode": k::A, "mode": "text"})),
        json!("textInput")
    );
}

#[test]
fn system_shortcuts_and_text_keys() {
    assert!(keyboard::is_system_shortcut(0xA0, 0));
    assert!(keyboard::is_system_shortcut(0x83, SH));
    assert!(keyboard::is_system_shortcut(k::SPACE, CTL));
    assert!(!keyboard::is_system_shortcut(k::SPACE, CTL | SH));
    assert!(keyboard::is_system_shortcut(k::GRAVE, CMD | SH));
    assert!(keyboard::is_system_shortcut(k::Q, CMD | OPT));
    assert!(!keyboard::is_system_shortcut(k::Q, CMD | SH));
    assert!(!keyboard::is_system_shortcut(k::UP, CTL | SH));
    // letters, digits, punctuation and keypad type; editing, arrows, F-keys do not
    for code in [k::A, 0x12, 0x2C, 0x53, 0x41, 0x0A, 0x5F, 0x5E, 0x5D, 0x51] {
        assert!(keyboard::types_text(code, SH), "{code:#x}");
    }
    for code in [k::RETURN, k::ESCAPE, 0x33, k::TAB, k::UP, 0x7A, 0x4C, 0x47, 0x3B, 0x3F] {
        assert!(!keyboard::types_text(code, 0), "{code:#x}");
    }
    assert!(!keyboard::types_text(k::A, CMD));
}

// MARK: - RemoteHIDKeyMap

#[test]
fn hid_table_maps_both_ways() {
    let table = keyboard::hid_table();
    assert_eq!(table.len(), 0x80);
    assert_eq!(keyboard::usage(k::A), Some(0x0007_0004));
    assert_eq!(keyboard::usage(0x3F), None, "fn has no HID usage");
    assert_eq!(keyboard::usage(0xFF), None);
    assert_eq!(keyboard::key_code(0x0007_0004), Some(k::A));
    assert_eq!(keyboard::key_code(0x000C_0004), None);
    for (code, id) in table.iter().enumerate() {
        if *id != 0 {
            assert_eq!(keyboard::key_code(0x0007_0000 | u32::from(*id)), Some(code as u16));
        }
    }
    assert_eq!(table.iter().filter(|&&v| v != 0).count(), 119);
    assert_eq!(call(json!({"op": "hid.usage", "keyCode": 0x3F})), Value::Null);
}

// MARK: - RemoteKeyboardState

#[test]
fn keyboard_state_tracks_held_keys_modifiers_and_buttons() {
    let mut s = KeyboardState::default();
    let a = 0x0007_0004;
    assert_eq!(s.key_down(k::A, false), vec![key(a, true)]);
    assert_eq!(s.key_down(k::A, true), vec![], "a repeat of a held key sends nothing");
    assert_eq!(s.key_up(k::A), vec![key(a, false)]);
    assert_eq!(s.key_up(k::A), vec![]);
    assert_eq!(s.key_down(0x3F, false), vec![]);
    // caps lock taps
    assert_eq!(
        s.flags_changed(0x39, flags::CAPS_LOCK),
        vec![key(0x0007_0039, true), key(0x0007_0039, false)]
    );
    // left and right shift; releasing the family flag releases both, sorted
    assert_eq!(s.flags_changed(0x38, SH), vec![key(0x0007_00E1, true)]);
    assert_eq!(s.flags_changed(0x3C, SH), vec![key(0x0007_00E5, true)]);
    assert_eq!(s.flags_changed(0x3C, 0), vec![key(0x0007_00E1, false), key(0x0007_00E5, false)]);
    // a held modifier whose flag stays on goes up
    s.flags_changed(0x37, CMD);
    s.flags_changed(0x36, CMD);
    assert_eq!(s.flags_changed(0x36, CMD), vec![key(0x0007_00E7, false)]);
    assert_eq!(s.button_down(3), vec![InputEvent::Button { button: 3, down: true }]);
    assert_eq!(s.button_down(1), vec![InputEvent::Button { button: 1, down: true }]);
    assert_eq!(s.button_up(2), vec![]);
    s.key_down(k::A, false);
    assert_eq!(
        s.release_all(),
        vec![
            key(a, false),
            key(0x0007_00E3, false),
            InputEvent::Button { button: 1, down: false },
            InputEvent::Button { button: 3, down: false },
        ]
    );
    assert_eq!(s, KeyboardState::default());
    let r = call(json!({"op": "keys.keyDown", "keyCode": k::A}));
    assert_eq!(
        r,
        json!({"state": {"heldKeys": [0], "heldButtons": []}, "events": [{"kind": "key", "usage": a, "down": true}]})
    );
    assert_eq!(keyboard::button_from_appkit(1), Some(3));
    assert_eq!(keyboard::button_from_appkit(4), Some(9));
    assert_eq!(keyboard::button_from_appkit(5), None);
}

// MARK: - RemoteScrollAccumulatorTests

#[test]
fn scroll_accumulator_parity() {
    let scroll = |dx, dy, precise| Some(InputEvent::Scroll { dx, dy, precise });
    let mut a = ScrollAccumulator::default();
    assert_eq!(a.add(0.004, 0.0, true, 0, 0), None);
    assert_eq!(a.add(0.006, 0.0, true, 0, 0), scroll(1, 0, true));

    let mut a = ScrollAccumulator::default();
    assert_eq!(a.add(0.009, 0.0, false, 0, 0), None);
    assert_eq!(a.add(0.002, 0.0, false, phase::BEGAN, 0), None);
    assert_eq!(a.add(0.008, 0.0, false, 0, 0), scroll(1, 0, false));

    let mut a = ScrollAccumulator::default();
    assert_eq!(a.add(0.009, 0.0, true, 0, 0), None);
    assert_eq!(a.add(0.002, 0.0, true, 0, phase::BEGAN), None);
    assert_eq!(a.add(0.008, 0.0, true, 0, 0), scroll(1, 0, true));

    let mut a = ScrollAccumulator::default();
    assert_eq!(a.add(0.009, 0.0, true, phase::ENDED, 0), None);
    assert_eq!(a.add(0.002, 0.0, true, 0, 0), None);
    assert_eq!(a.add(0.008, 0.0, true, 0, 0), scroll(1, 0, true));

    let mut a = ScrollAccumulator::default();
    assert_eq!(
        a.add(f64::from(i32::MAX) * 2.0, f64::from(i32::MIN) * 2.0, false, 0, 0),
        scroll(i32::MAX, i32::MIN, false)
    );

    let r = call(json!({"op": "scroll.add", "dx": -0.015, "dy": 0.0}));
    assert_eq!(r["event"], json!({"kind": "scroll", "dx": -1, "dy": 0, "precise": false}));
}

// MARK: - RemoteInputEvent.textEvents

#[test]
fn text_splits_on_character_boundaries() {
    assert_eq!(keyboard::text_events(""), vec![]);
    let long = "é".repeat(200); // 400 bytes
    let events = keyboard::text_events(&long);
    assert_eq!(events.len(), 2);
    let InputEvent::Text { text } = &events[0] else { panic!() };
    assert_eq!(text.len(), 256);
    // a family emoji (ZWJ sequence, 25 bytes) is never cut
    let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦";
    let text = format!("{}{family}", "a".repeat(250));
    let events = keyboard::text_events(&text);
    assert_eq!(
        events,
        vec![
            InputEvent::Text { text: "a".repeat(250) },
            InputEvent::Text { text: family.to_owned() }
        ]
    );
    // flags pair, combining accent
    let text = format!("{}🇯🇵e\u{301}", "a".repeat(252));
    let events = keyboard::text_events(&text);
    assert_eq!(events[0], InputEvent::Text { text: "a".repeat(252) });
}

// MARK: - RemoteLatencyHoldTests

fn streaming(state: &PaneState, rtt: i64, at_seconds: f64) -> PaneState {
    let status =
        ViewStatus { rtt_ms: Some(rtt), state: SessionState::Streaming, ..Default::default() };
    pane::reduce(state, &PaneEvent::Status { status }, (at_seconds * 1e9) as i64)
}

fn control_box() -> PaneState {
    PaneState {
        host_name: "box".into(),
        requested_mode: ControlMode::Control,
        interactive_max_rtt_ms: 80,
        ..Default::default()
    }
}

#[test]
fn one_slow_sample_shows_nothing() {
    let mut s = control_box();
    s = streaming(&s, 20, 0.0);
    s = streaming(&s, 400, 1.0);
    assert!(!s.view().shows_latency_banner);
    assert_eq!(s.effective_mode(), ControlMode::Control);
    s = streaming(&s, 20, 2.0);
    s = streaming(&s, 400, 3.5);
    assert!(!s.view().shows_latency_banner, "a dip under the limit starts the hold again");
}

#[test]
fn a_sustained_slow_path_shows_and_a_sustained_fast_one_hides() {
    let mut s = control_box();
    s = streaming(&s, 400, 0.0);
    s = streaming(&s, 400, 2.9);
    assert!(!s.view().shows_latency_banner);
    s = streaming(&s, 400, 3.0);
    assert!(s.view().shows_latency_banner);
    assert_eq!(s.effective_mode(), ControlMode::View);
    s = streaming(&s, 20, 4.0);
    assert!(s.view().shows_latency_banner);
    s = streaming(&s, 20, 6.9);
    assert!(s.view().shows_latency_banner);
    s = streaming(&s, 20, 7.0);
    assert!(!s.view().shows_latency_banner);
    assert_eq!(s.effective_mode(), ControlMode::Control);
}

#[test]
fn a_due_check_flips_with_no_new_sample() {
    let mut s = control_box();
    s = streaming(&s, 400, 0.0);
    assert_eq!(s.latency.due(), Some(LATENCY_SUSTAIN_NS));
    s = pane::reduce(&s, &PaneEvent::LatencyCheck, LATENCY_SUSTAIN_NS);
    assert!(s.view().shows_latency_banner);
    assert_eq!(s.latency.due(), None);
    s = pane::reduce(
        &pane::reduce(&s, &PaneEvent::Stop, 4_000_000_000),
        &PaneEvent::Reconnect,
        5_000_000_000,
    );
    assert!(!s.latency.high);
}

// MARK: - RemotePaneQuietReconnectTests

fn view_vm() -> PaneState {
    PaneState { host_name: "vm".into(), requested_mode: ControlMode::View, ..Default::default() }
}

fn status(state: SessionState) -> PaneEvent {
    PaneEvent::Status { status: ViewStatus { state, ..Default::default() } }
}

fn streaming_with_frame(now: i64) -> PaneState {
    let s = pane::reduce(&view_vm(), &status(SessionState::Streaming), now);
    pane::reduce(&s, &PaneEvent::FrameShown, now)
}

#[test]
fn a_restart_over_the_last_frame_shows_no_card() {
    let restarted = pane::reduce(&streaming_with_frame(0), &PaneEvent::RestartForMode, 0);
    assert_eq!(restarted.session_state(), SessionState::Connecting);
    assert_eq!(restarted.overlay(), None);
    let again = pane::reduce(&restarted, &status(SessionState::Streaming), 0);
    assert_eq!(again.overlay(), None, "streaming, before the new session's first frame");
}

#[test]
fn the_card_shows_only_once_the_reconnect_ran_for_the_bound() {
    let start = 1_000;
    let restarted = pane::reduce(&streaming_with_frame(start), &PaneEvent::RestartForMode, start);
    assert_eq!(restarted.reconnecting_since, Some(start));
    let early = pane::reduce(&restarted, &PaneEvent::ReconnectNoticeCheck, start + 9_000_000_000);
    assert_eq!(early.overlay(), None);
    let due = pane::reduce(
        &restarted,
        &PaneEvent::ReconnectNoticeCheck,
        start + RECONNECT_NOTICE_DELAY_NS,
    );
    assert_eq!(due.overlay(), Some(Overlay::Connecting));
    let back = pane::reduce(
        &pane::reduce(&due, &status(SessionState::Streaming), start),
        &PaneEvent::FrameShown,
        start,
    );
    assert_eq!(back.overlay(), None);
    assert_eq!(back.reconnecting_since, None);
    assert!(!back.reconnect_notice_due);
}

#[test]
fn a_first_connect_still_says_connecting() {
    assert_eq!(view_vm().overlay(), Some(Overlay::Connecting));
}

#[test]
fn a_new_pane_holds_its_connecting_card_for_the_coming_up_time() {
    let start = 42;
    let s = pane::reduce(&view_vm(), &PaneEvent::ConnectNoticeCheck, start);
    assert_eq!(s.connecting_since, Some(start));
    assert_eq!(s.overlay(), None);
    let due = pane::reduce(&s, &PaneEvent::ConnectNoticeCheck, start + CONNECT_NOTICE_DELAY_NS);
    assert_eq!(due.overlay(), Some(Overlay::Connecting));
    assert_eq!(due.connecting_since, Some(start));
}

#[test]
fn a_lost_cloud_desktop_reads_reconnecting_until_its_next_frame() {
    let mut s = PaneState {
        host_name: "graceful-amber-owl".into(),
        via_cloud_tunnel: true,
        ..Default::default()
    };
    s = pane::reduce(&s, &status(SessionState::Streaming), 0);
    s = pane::reduce(&s, &PaneEvent::FrameShown, 0);
    assert!(s.has_frame && !s.reconnecting);
    s = pane::reduce(&s, &status(SessionState::Ended { reason: SessionEnd::ConnectionLost }), 0);
    s = pane::reduce(&s, &status(SessionState::Connecting), 0);
    assert!(s.reconnecting);
    s = pane::reduce(&s, &status(SessionState::Streaming), 0);
    s = pane::reduce(&s, &PaneEvent::FrameShown, 0);
    assert!(!s.reconnecting, "the next frame clears it");
}

#[test]
fn a_lost_path_with_no_picture_yet_keeps_the_ended_card() {
    let s = pane::reduce(&view_vm(), &status(SessionState::Connecting), 0);
    let s =
        pane::reduce(&s, &status(SessionState::Ended { reason: SessionEnd::ConnectionLost }), 0);
    assert_eq!(s.overlay(), Some(Overlay::Ended { reason: SessionEnd::ConnectionLost }));
}

#[test]
fn stop_control_anyway_and_upstreams() {
    let mut s = control_box();
    s = pane::reduce(&s, &PaneEvent::ControlAnyway, 0);
    assert!(!s.control_despite_latency, "only while streaming over high latency");
    s = streaming(&s, 400, 0.0);
    s = streaming(&s, 400, 3.0);
    s = pane::reduce(&s, &PaneEvent::ControlAnyway, 3_000_000_000);
    assert!(s.control_despite_latency);
    assert_eq!(s.effective_mode(), ControlMode::Control);
    s = pane::reduce(&s, &PaneEvent::SelectMode { mode: ControlMode::View }, 3_000_000_000);
    assert!(!s.control_despite_latency);
    s = pane::reduce(&s, &PaneEvent::SetInteractiveMaxRtt { limit: -5 }, 0);
    assert_eq!(s.interactive_max_rtt_ms, 0);

    let mut st = ViewStatus { state: SessionState::Streaming, ..Default::default() };
    st.upstream.offered = true;
    st.upstream.active.extend([pane::UpstreamKind::Screen, pane::UpstreamKind::Microphone]);
    st.upstream.requested.insert(pane::UpstreamKind::Screen);
    let s = pane::reduce(&view_vm(), &PaneEvent::Status { status: st }, 0);
    let v = s.view();
    assert!(v.shows_upstream_buttons && v.shows_session_controls);
    assert_eq!(
        v.upstream_indicator,
        vec![pane::UpstreamKind::Microphone, pane::UpstreamKind::Screen]
    );
    let s2 = pane::reduce(&s, &PaneEvent::StopUpstream { upstream: pane::UpstreamKind::Screen }, 0);
    assert_eq!(s2.view().upstream_indicator, vec![pane::UpstreamKind::Microphone]);
    assert!(s2.status.as_ref().unwrap().upstream.requested.is_empty());
    let stopped = pane::reduce(&s, &PaneEvent::Stop, 0);
    assert_eq!(
        stopped.session_state(),
        SessionState::Ended { reason: SessionEnd::StoppedByViewer }
    );
    assert!(stopped.view().upstream_indicator.is_empty() && stopped.view().is_ended);
    let r = call(
        json!({"op": "pane.reduce", "state": {"hostName": "vm"}, "event": {"kind": "stop"}, "now": 0}),
    );
    assert_eq!(
        r["state"]["status"]["state"],
        json!({"kind": "ended", "reason": {"kind": "stoppedByViewer"}})
    );
    assert_eq!(
        r["view"]["overlay"],
        json!({"kind": "ended", "reason": {"kind": "stoppedByViewer"}})
    );
    assert_eq!(r["view"]["pinsToolbar"], json!(true));
}

// MARK: - RemoteViewTabPolicyTests

fn record(host: &str) -> TabRecord {
    TabRecord::new(host, Target::default(), ControlMode::View, None, false, false).unwrap()
}

#[test]
fn only_loopback_hosts_are_accepted_including_reserved_names() {
    assert!(tab::is_loopback("mock"));
    assert!(tab::is_loopback("LOCALHOST"));
    assert!(tab::is_loopback("127.0.0.1"));
    assert!(tab::is_loopback("127.255.255.255"));
    assert!(!tab::is_loopback("127.0.0.01"));
    assert!(!tab::is_loopback("128.0.0.1"));
    assert!(!tab::is_loopback("localhost.example"));
}

#[test]
fn remote_records_and_unavailable_builds_never_connect() {
    let r = record("local");
    let unavailable = |reason| TabDecision::Unavailable { reason };
    assert_eq!(
        tab::decide(Some(&r), TabSource::RemoteTree, true, false),
        unavailable(UnavailableReason::RemoteRecord)
    );
    assert_eq!(
        tab::decide(Some(&r), TabSource::Person, false, false),
        unavailable(UnavailableReason::NotInThisBuild)
    );
    assert_eq!(
        tab::decide(Some(&r), TabSource::Person, true, false),
        TabDecision::Connect { record: r.clone() }
    );
    assert_eq!(
        tab::decide(None, TabSource::Person, true, false),
        unavailable(UnavailableReason::InvalidAddress)
    );
    let s = record("server-1");
    assert_eq!(
        tab::decide(Some(&s), TabSource::Person, true, false),
        unavailable(UnavailableReason::NotLoopback { host: "server-1".into() })
    );
}

#[test]
fn a_cloud_desktop_record_round_trips_and_connects_only_for_a_person() {
    let cloud =
        TabRecord::new("vm-0dd1c008", Target::Virtual, ControlMode::Control, None, true, false)
            .unwrap();
    assert_eq!(
        cloud.url(),
        "cmux://remote-view?host=vm-0dd1c008&target=virtual&mode=control&via=cloud"
    );
    assert_eq!(TabRecord::parse(&cloud.url()), Some(cloud.clone()));
    assert_eq!(TabRecord::parse("cmux://remote-view?host=vm-1&via=cloud&port=5901"), None);
    assert_eq!(
        TabRecord::new("vm-1", Target::default(), ControlMode::View, Some(5901), true, false),
        None
    );
    let rd = TabRecord::new("vm-0dd1c008", Target::Virtual, ControlMode::Control, None, true, true)
        .unwrap();
    assert_eq!(
        rd.url(),
        "cmux://remote-view?host=vm-0dd1c008&target=virtual&mode=control&via=cloud-rd"
    );
    assert_eq!(TabRecord::parse(&rd.url()), Some(rd.clone()));
    assert_eq!(
        TabRecord::new("vm-1", Target::default(), ControlMode::View, None, false, true),
        None
    );
    assert_eq!(
        tab::decide(Some(&rd), TabSource::Person, true, false),
        TabDecision::Connect { record: rd.clone() }
    );
    let mut rd_view = rd.clone();
    rd_view.mode = ControlMode::View;
    assert_eq!(
        tab::decide(Some(&rd), TabSource::Unconfirmed, true, false),
        TabDecision::Confirm { record: rd_view }
    );
    assert_eq!(
        tab::decide(Some(&rd), TabSource::RemoteTree, true, false),
        TabDecision::Unavailable { reason: UnavailableReason::RemoteRecord }
    );
    // Cloud rd opens in a build without the pane only when Cloud rd is available.
    assert_eq!(
        tab::decide(Some(&rd), TabSource::Person, false, true),
        TabDecision::Connect { record: rd.clone() }
    );
    assert_eq!(
        tab::decide(Some(&cloud), TabSource::Person, false, true),
        TabDecision::Unavailable { reason: UnavailableReason::NotInThisBuild }
    );
}

#[test]
fn unconfirmed_records_require_confirmation_and_start_in_view_mode() {
    let control =
        TabRecord::new("local", Target::default(), ControlMode::Control, None, false, false)
            .unwrap();
    assert_eq!(
        tab::decide(Some(&control), TabSource::Unconfirmed, true, false),
        TabDecision::Confirm { record: record("local") }
    );
    let r = call(json!({
        "op": "tab.decide", "record": {"host": "local", "mode": "control"}, "source": "unconfirmed", "paneAvailable": true,
    }));
    assert_eq!(r["kind"], json!("confirm"));
    assert_eq!(r["record"]["mode"], json!("view"));
    let invalid = call(
        json!({"op": "tab.decide", "record": {"host": "-bad"}, "source": "person", "paneAvailable": true}),
    );
    assert_eq!(invalid, json!({"kind": "unavailable", "reason": {"kind": "invalidAddress"}}));
}

#[test]
fn vnc_records_need_a_private_network() {
    let vnc = |host: &str| {
        TabRecord::new(host, Target::default(), ControlMode::View, Some(5900), false, false)
            .unwrap()
    };
    for host in [
        "10.0.0.5",
        "192.168.1.2",
        "172.16.0.1",
        "172.31.255.255",
        "100.64.0.1",
        "100.127.1.1",
        "mini.local",
        "box.tail1.ts.net",
        "studio",
        "127.0.0.1",
    ] {
        assert!(tab::is_private_network(host), "{host}");
        assert!(matches!(
            tab::decide(Some(&vnc(host)), TabSource::Person, true, false),
            TabDecision::Connect { .. }
        ));
    }
    for host in [
        "8.8.8.8",
        "172.32.0.1",
        "100.128.0.1",
        "010.0.0.1",
        "134744072",
        "0x08080808",
        "example.com",
    ] {
        assert!(!tab::is_private_network(host), "{host}");
    }
    assert_eq!(
        tab::decide(Some(&vnc("example.com")), TabSource::Person, true, false),
        TabDecision::Unavailable {
            reason: UnavailableReason::NotPrivateNetwork { host: "example.com".into() }
        }
    );
}

// MARK: - RemoteViewTabRecord URL rules

#[test]
fn tab_urls_parse_strictly() {
    let r = TabRecord::parse("CMUX://Remote-View?host=local").unwrap();
    assert_eq!((r.target, r.mode, r.vnc_port), (Target::Display(1), ControlMode::View, None));
    let r = TabRecord::parse(
        "cmux://remote-view?host=mini&target=window:18446744073709551615&mode=control&via=vnc",
    )
    .unwrap();
    assert_eq!(
        (r.target, r.mode, r.vnc_port),
        (Target::Window(u64::MAX), ControlMode::Control, Some(5900))
    );
    assert_eq!(
        r.url(),
        "cmux://remote-view?host=mini&target=window:18446744073709551615&mode=control&via=vnc&port=5900"
    );
    assert_eq!(
        TabRecord::parse("cmux://remote-view?host=mini&via=vnc&port=5901").unwrap().vnc_port,
        Some(5901)
    );
    assert_eq!(TabRecord::parse("cmux://remote-view?host=local&via=rd").unwrap().vnc_port, None);
    assert_eq!(
        TabRecord::parse("cmux://remote-view?host=local&other=1&other=2").map(|r| r.host),
        Some("local".into())
    );
    assert_eq!(
        TabRecord::parse("cmux://remote-view?host=%6Cocal").map(|r| r.host),
        Some("local".into())
    );
    let invalid = [
        "cmux://remote-view",
        "https://remote-view?host=local",
        "cmux://other?host=local",
        "cmux://user@remote-view?host=local",
        "cmux://remote-view:9?host=local",
        "cmux://remote-view/x?host=local",
        "cmux://remote-view?host=local#frag",
        "cmux://remote-view?host=local&host=mock",
        "cmux://remote-view?host",
        "cmux://remote-view?host=-local",
        "cmux://remote-view?host=local&target=display:4294967296",
        "cmux://remote-view?host=local&target=display:",
        "cmux://remote-view?host=local&target=screen:1",
        "cmux://remote-view?host=local&mode=edit",
        "cmux://remote-view?host=local&port=5900",
        "cmux://remote-view?host=local&via=rd&port=5900",
        "cmux://remote-view?host=local&via=vnc&port=0",
        "cmux://remote-view?host=local&via=vnc&port=65536",
        "cmux://remote-view?host=local&via=vnc&port=005900",
        "cmux://remote-view?host=local&via=vnc&port=+59",
        "cmux://remote-view?host=local&via=ssh",
        "cmux://remote-view?host=lo cal",
    ];
    for url in invalid {
        assert_eq!(TabRecord::parse(url), None, "{url}");
    }
    assert!(tab::is_valid_host(&"a".repeat(128)));
    assert!(!tab::is_valid_host(&"a".repeat(129)));
    assert!(!tab::is_valid_host(""));
    assert!(!tab::is_valid_host("_a"));
    assert!(tab::is_valid_host("a_b.c-d"));
    assert_eq!(Target::parse("display:007"), Some(Target::Display(7)));
    assert_eq!(Target::parse("virtual"), Some(Target::Virtual));
    assert_eq!(
        call(json!({"op": "tab.parse", "url": "cmux://remote-view?host=local&target=virtual"}))["target"],
        json!({"kind": "virtual"})
    );
    assert_eq!(
        call(
            json!({"op": "tab.url", "record": {"host": "local", "target": {"kind": "display", "id": 2}}})
        ),
        json!("cmux://remote-view?host=local&target=display:2&mode=view")
    );
}

// MARK: - C ABI

#[test]
fn bad_requests_are_invalid_and_null_is_refused() {
    let view = cmux_rd_view_new();
    let mut out: *const u8 = std::ptr::null();
    let mut len = 0usize;
    for bad in [
        &b"{\"op\": \"nope\"}"[..],
        b"not json",
        b"{\"op\": \"hid.usage\"}",
        b"{\"op\": \"hid.usage\", \"keyCode\": 1, \"x\": 2}",
    ] {
        // SAFETY: live handle, readable bytes, writable out pointers.
        let code = unsafe { cmux_rd_view_call(view, bad.as_ptr(), bad.len(), &mut out, &mut len) };
        assert_eq!(code, CMUX_RD_ERR_INVALID, "{}", String::from_utf8_lossy(bad));
    }
    // SAFETY: NULL handle is refused before any read.
    let code =
        unsafe { cmux_rd_view_call(std::ptr::null_mut(), b"{}".as_ptr(), 2, &mut out, &mut len) };
    assert_eq!(code, CMUX_RD_ERR_NULL);
    // SAFETY: NULL out pointers are refused.
    let code =
        unsafe { cmux_rd_view_call(view, b"{}".as_ptr(), 2, std::ptr::null_mut(), &mut len) };
    assert_eq!(code, CMUX_RD_ERR_NULL);
    // SAFETY: from cmux_rd_view_new; NULL is ignored.
    unsafe {
        cmux_rd_view_free(view);
        cmux_rd_view_free(std::ptr::null_mut());
    }
}
