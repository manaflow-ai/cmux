//! The remote desktop viewer's rules and state, moved out of the Swift
//! `CmuxNextRemoteView` module: keyboard routing and held keys, the pane's
//! state reducer, the tab record and policy, the session and tab-list
//! bookkeeping, and the stream transport's rules (control codec,
//! handshake, session bookkeeping, frame splitting, cursor feed and popup
//! surface streams). Every op is pure: the caller passes the state in and
//! takes the next state back (`cmux_rd_view_call`, `view_ffi.rs`).

pub mod control;
pub mod cursor;
pub mod handshake;
pub mod keyboard;
pub mod pane;
pub mod session;
mod session_ops;
pub mod tab;
pub mod tabs;
pub mod transport;

use cmux_rd_proto::{base64_decode, control::Control};
use serde::Deserialize;
use serde_json::{Value, json};

use keyboard::{
    InputEvent, KeyboardMode, KeyboardState, ReleaseChord, ScrollAccumulator, SystemShortcuts,
    TapConditions, TapKey,
};
use pane::{LatencyHold, PaneEvent, PaneState};
use tab::{TabRecord, TabSource, Target};
use transport::{StreamSplitter, SurfaceChange, SurfaceStreams, Transport};

fn default_true() -> bool {
    true
}

/// One request: `{"op": "...", ...fields}`.
#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all_fields = "camelCase", deny_unknown_fields)]
pub enum Request {
    #[serde(rename = "keyboard.route")]
    KeyboardRoute {
        key_code: u16,
        #[serde(default)]
        modifiers: u64,
        #[serde(default)]
        mode: KeyboardMode,
        #[serde(default)]
        send_system_shortcuts: bool,
        #[serde(default = "default_true")]
        input_source_is_ascii_capable: bool,
        #[serde(default)]
        release_chord: ReleaseChord,
        #[serde(default)]
        is_local_shortcut: bool,
    },
    #[serde(rename = "keyboard.isSystemShortcut")]
    IsSystemShortcut {
        key_code: u16,
        #[serde(default)]
        modifiers: u64,
    },
    #[serde(rename = "keyboard.typesText")]
    TypesText {
        key_code: u16,
        #[serde(default)]
        modifiers: u64,
    },
    #[serde(rename = "keyboard.sendsAsText")]
    SendsAsText {
        #[serde(default)]
        characters: Option<String>,
        #[serde(default)]
        layout_characters: Option<String>,
        #[serde(default)]
        modifiers: u64,
    },
    #[serde(rename = "keyboard.releaseChordMatches")]
    ReleaseChordMatches {
        #[serde(default)]
        release_chord: ReleaseChord,
        key_code: u16,
        #[serde(default)]
        modifiers: u64,
    },
    /// The whole key code to HID usage id table (index = key code).
    #[serde(rename = "hid.table")]
    HidTable,
    #[serde(rename = "hid.usage")]
    HidUsage { key_code: u16 },
    #[serde(rename = "hid.keyCode")]
    HidKeyCode { usage: u32 },
    #[serde(rename = "keys.keyDown")]
    KeyDown {
        #[serde(default)]
        state: KeyboardState,
        key_code: u16,
        #[serde(default)]
        is_repeat: bool,
    },
    #[serde(rename = "keys.keyUp")]
    KeyUp {
        #[serde(default)]
        state: KeyboardState,
        key_code: u16,
    },
    #[serde(rename = "keys.flagsChanged")]
    FlagsChanged {
        #[serde(default)]
        state: KeyboardState,
        key_code: u16,
        #[serde(default)]
        modifiers: u64,
    },
    #[serde(rename = "keys.buttonDown")]
    ButtonDown {
        #[serde(default)]
        state: KeyboardState,
        button: u8,
    },
    #[serde(rename = "keys.buttonUp")]
    ButtonUp {
        #[serde(default)]
        state: KeyboardState,
        button: u8,
    },
    #[serde(rename = "keys.releaseAll")]
    ReleaseAll {
        #[serde(default)]
        state: KeyboardState,
    },
    #[serde(rename = "mouse.button")]
    MouseButton { number: i64 },
    #[serde(rename = "shortcuts.installs")]
    ShortcutsInstalls { conditions: TapConditions },
    #[serde(rename = "shortcuts.takes")]
    ShortcutsTakes {
        #[serde(default)]
        shortcuts: SystemShortcuts,
        key_code: u16,
        #[serde(default)]
        modifiers: u64,
    },
    #[serde(rename = "shortcuts.route")]
    ShortcutsRoute {
        #[serde(default)]
        shortcuts: SystemShortcuts,
        #[serde(default)]
        keyboard: KeyboardState,
        key: TapKey,
    },
    #[serde(rename = "scroll.add")]
    ScrollAdd {
        #[serde(default)]
        state: ScrollAccumulator,
        dx: f64,
        dy: f64,
        #[serde(default)]
        precise: bool,
        #[serde(default)]
        phase: u64,
        #[serde(default)]
        momentum_phase: u64,
    },
    #[serde(rename = "text.events")]
    TextEvents { text: String },
    #[serde(rename = "pane.reduce")]
    PaneReduce { state: Box<PaneState>, event: PaneEvent, now: i64 },
    #[serde(rename = "pane.view")]
    PaneView { state: Box<PaneState> },
    #[serde(rename = "latency.sample")]
    LatencySample {
        #[serde(default)]
        state: LatencyHold,
        over: bool,
        now: i64,
    },
    #[serde(rename = "tab.parse")]
    TabParse { url: String },
    #[serde(rename = "tab.make")]
    TabMake {
        host: String,
        #[serde(default)]
        target: Target,
        #[serde(default = "view_mode")]
        mode: pane::ControlMode,
        #[serde(default)]
        vnc_port: Option<u16>,
        #[serde(default)]
        cloud_desktop: bool,
        #[serde(default)]
        cloud_rd: bool,
    },
    #[serde(rename = "tab.url")]
    TabUrl { record: TabRecord },
    #[serde(rename = "tab.isValidHost")]
    TabIsValidHost { host: String },
    #[serde(rename = "tab.decide")]
    TabDecide {
        #[serde(default)]
        record: Option<TabRecord>,
        source: TabSource,
        pane_available: bool,
        #[serde(default)]
        cloud_rd_available: bool,
    },
    #[serde(rename = "tab.isPrivateNetwork")]
    TabIsPrivateNetwork { host: String },
    #[serde(rename = "tab.isLoopback")]
    TabIsLoopback { host: String },
    /// One received control message (the frame payload as text).
    #[serde(rename = "control.parse")]
    ControlParse { json: String },
    #[serde(rename = "control.encode")]
    ControlEncode { control: Control },
    #[serde(rename = "hello.cloudDesktop")]
    HelloCloudDesktop {
        #[serde(default)]
        install: Option<String>,
    },
    #[serde(rename = "hello.remoteBrowser")]
    HelloRemoteBrowser {
        user: String,
        install: String,
        #[serde(default)]
        token: Option<String>,
    },
    #[serde(rename = "hello.encode")]
    HelloEncode { hello: control::Hello },
    #[serde(rename = "hello.redacted")]
    HelloRedacted { hello: control::Hello },
    #[serde(rename = "handshake.new")]
    HandshakeNew { service: String },
    #[serde(rename = "handshake.receive")]
    HandshakeReceive { state: handshake::Handshake, message: Value },
    #[serde(rename = "handshake.hostEnd")]
    HandshakeHostEnd { reason: String },
    #[serde(rename = "transport.new")]
    TransportNew {
        hello: control::Hello,
        start_key: String,
        #[serde(default)]
        control: bool,
        #[serde(default)]
        clipboard: bool,
    },
    #[serde(rename = "transport.connect")]
    TransportConnect { state: Transport },
    #[serde(rename = "transport.ready")]
    TransportReady { state: Transport },
    #[serde(rename = "transport.progress")]
    TransportProgress { state: Transport, text: String },
    #[serde(rename = "transport.closed")]
    TransportClosed { state: Transport, reason: String },
    #[serde(rename = "transport.rejected")]
    TransportRejected { state: Transport, error: String },
    #[serde(rename = "transport.stop")]
    TransportStop { state: Transport },
    #[serde(rename = "transport.control")]
    TransportControl { state: Transport, json: String },
    #[serde(rename = "transport.service")]
    TransportService { state: Transport, body: Value },
    #[serde(rename = "transport.finish")]
    TransportFinish { state: Transport },
    #[serde(rename = "transport.status")]
    TransportStatus {
        state: Transport,
        #[serde(default)]
        upstream: Option<pane::UpstreamStatus>,
    },
    #[serde(rename = "transport.gates")]
    TransportGates { state: Transport },
    /// Received bytes, base64.
    #[serde(rename = "splitter.split")]
    SplitterSplit {
        #[serde(default)]
        state: StreamSplitter,
        data: String,
    },
    #[serde(rename = "cursor.image")]
    CursorImage { shape: u32, width: u32, height: u32, hot_x: u32, hot_y: u32, rgba: String },
    #[serde(rename = "cursorFeed.shape")]
    CursorFeedShape {
        #[serde(default)]
        state: cursor::CursorFeed,
        id: u32,
    },
    /// One datagram, base64.
    #[serde(rename = "cursorFeed.datagram")]
    CursorFeedDatagram {
        #[serde(default)]
        state: cursor::CursorFeed,
        data: String,
    },
    #[serde(rename = "surfaces.parse")]
    SurfacesParse { body: Value },
    #[serde(rename = "surfaces.apply")]
    SurfacesApply {
        #[serde(default)]
        state: SurfaceStreams,
        change: SurfaceChange,
    },
    #[serde(rename = "surfaces.start")]
    SurfacesStart {
        #[serde(default)]
        state: SurfaceStreams,
        stream: u16,
        surface: u32,
    },
    #[serde(rename = "surfaces.end")]
    SurfacesEnd {
        #[serde(default)]
        state: SurfaceStreams,
        stream: u16,
    },
    #[serde(rename = "surfaces.endAll")]
    SurfacesEndAll {
        #[serde(default)]
        state: SurfaceStreams,
    },
}

fn view_mode() -> pane::ControlMode {
    pane::ControlMode::View
}

fn events(state: &KeyboardState, events: Vec<InputEvent>) -> Value {
    json!({"state": state, "events": events})
}

/// Runs one request; Err when the request is not one.
pub fn call(request: &[u8]) -> Result<Value, serde_json::Error> {
    if let Some(answer) = session_ops::call(request) {
        return answer;
    }
    let request: Request = serde_json::from_slice(request)?;
    Ok(run(request))
}

pub fn run(request: Request) -> Value {
    use Request as R;
    match request {
        R::KeyboardRoute {
            key_code,
            modifiers,
            mode,
            send_system_shortcuts,
            input_source_is_ascii_capable,
            release_chord,
            is_local_shortcut,
        } => json!(keyboard::route(
            key_code,
            modifiers,
            mode,
            send_system_shortcuts,
            input_source_is_ascii_capable,
            release_chord,
            is_local_shortcut
        )),
        R::IsSystemShortcut { key_code, modifiers } => {
            json!(keyboard::is_system_shortcut(key_code, modifiers))
        }
        R::TypesText { key_code, modifiers } => json!(keyboard::types_text(key_code, modifiers)),
        R::SendsAsText { characters, layout_characters, modifiers } => {
            json!(keyboard::sends_as_text(
                characters.as_deref(),
                layout_characters.as_deref(),
                modifiers
            ))
        }
        R::ReleaseChordMatches { release_chord, key_code, modifiers } => {
            json!(release_chord.matches(key_code, modifiers & keyboard::flags::DEVICE_INDEPENDENT))
        }
        R::HidTable => json!(keyboard::hid_table().to_vec()),
        R::HidUsage { key_code } => json!(keyboard::usage(key_code)),
        R::HidKeyCode { usage } => json!(keyboard::key_code(usage)),
        R::KeyDown { mut state, key_code, is_repeat } => {
            let out = state.key_down(key_code, is_repeat);
            events(&state, out)
        }
        R::KeyUp { mut state, key_code } => {
            let out = state.key_up(key_code);
            events(&state, out)
        }
        R::FlagsChanged { mut state, key_code, modifiers } => {
            let out = state.flags_changed(key_code, modifiers);
            events(&state, out)
        }
        R::ButtonDown { mut state, button } => {
            let out = state.button_down(button);
            events(&state, out)
        }
        R::ButtonUp { mut state, button } => {
            let out = state.button_up(button);
            events(&state, out)
        }
        R::ReleaseAll { mut state } => {
            let out = state.release_all();
            events(&state, out)
        }
        R::MouseButton { number } => json!(keyboard::button_from_appkit(number)),
        R::ShortcutsInstalls { conditions } => json!(conditions.installs()),
        R::ShortcutsTakes { shortcuts, key_code, modifiers } => {
            json!(shortcuts.takes(key_code, modifiers))
        }
        R::ShortcutsRoute { mut shortcuts, mut keyboard, key } => {
            let out = shortcuts.route(key, &mut keyboard);
            json!({"shortcuts": shortcuts, "keyboard": keyboard, "events": out})
        }
        R::ScrollAdd { mut state, dx, dy, precise, phase, momentum_phase } => {
            let event = state.add(dx, dy, precise, phase, momentum_phase);
            json!({"state": state, "event": event})
        }
        R::TextEvents { text } => json!(keyboard::text_events(&text)),
        R::PaneReduce { state, event, now } => {
            let next = pane::reduce(&state, &event, now);
            json!({"state": next, "view": next.view()})
        }
        R::PaneView { state } => json!(state.view()),
        R::LatencySample { mut state, over, now } => {
            state.sample(over, now);
            json!({"state": state, "due": state.due()})
        }
        R::TabParse { url } => json!(TabRecord::parse(&url)),
        R::TabMake { host, target, mode, vnc_port, cloud_desktop, cloud_rd } => {
            json!(TabRecord::new(&host, target, mode, vnc_port, cloud_desktop, cloud_rd))
        }
        R::TabUrl { record } => json!(record.url()),
        R::TabIsValidHost { host } => json!(tab::is_valid_host(&host)),
        R::TabDecide { record, source, pane_available, cloud_rd_available } => {
            // A record that came in as data is checked as `init?` would.
            let record = record.and_then(TabRecord::validated);
            json!(tab::decide(record.as_ref(), source, pane_available, cloud_rd_available))
        }
        R::TabIsPrivateNetwork { host } => json!(tab::is_private_network(&host)),
        R::TabIsLoopback { host } => json!(tab::is_loopback(&host)),
        R::ControlParse { json } => match control::parse(json.as_bytes()) {
            Ok(incoming) => json!({"ok": true, "incoming": incoming}),
            Err(error) => json!({"ok": false, "error": error.to_string()}),
        },
        R::ControlEncode { control } => control::encode(&control),
        R::HelloCloudDesktop { install } => {
            json!(control::Hello::cloud_desktop(install.as_deref()))
        }
        R::HelloRemoteBrowser { user, install, token } => {
            json!(control::Hello::remote_browser(&user, &install, token.as_deref()))
        }
        R::HelloEncode { hello } => control::encode(&hello.control()),
        R::HelloRedacted { hello } => json!(hello.redacted_description()),
        R::HandshakeNew { service } => json!(handshake::Handshake::new(&service)),
        R::HandshakeReceive { mut state, message } => {
            let parsed = control::parse_value(message);
            if let Ok(incoming) = &parsed {
                state.receive(incoming);
            }
            json!({"state": state, "parsed": parsed.is_ok(), "session": state.session_state()})
        }
        R::HandshakeHostEnd { reason } => json!(handshake::host_end(&reason)),
        R::TransportNew { hello, start_key, control, clipboard } => {
            json!(Transport::new(hello, &start_key, control, clipboard))
        }
        R::TransportConnect { mut state } => {
            let start = state.connect();
            json!({"state": state, "start": start})
        }
        R::TransportReady { mut state } => {
            let send = state.ready();
            json!({"state": state, "send": send})
        }
        R::TransportProgress { mut state, text } => {
            state.progress(&text);
            json!({"state": state})
        }
        R::TransportClosed { mut state, reason } => {
            state.closed(&reason);
            json!({"state": state})
        }
        R::TransportRejected { mut state, error } => {
            state.closed(&Transport::rejected_reason(&error));
            json!({"state": state})
        }
        R::TransportStop { mut state } => {
            let send = state.stop();
            json!({"state": state, "revokeUpstream": send.is_some(), "send": send})
        }
        R::TransportControl { mut state, json } => {
            let actions = state.receive_control(json.as_bytes());
            json!({"state": state, "actions": actions})
        }
        R::TransportService { state, body } => json!({"send": state.service_message(body)}),
        R::TransportFinish { mut state } => {
            state.finish();
            json!({"state": state})
        }
        R::TransportStatus { state, upstream } => json!(state.status(upstream)),
        R::TransportGates { state } => json!({
            "acceptsData": state.accepts_data(),
            "streaming": state.handshake.is_streaming(),
            "ended": state.handshake.is_ended(),
            "serviceInput": state.allows_service_input(),
            "upstreamRequest": state.allows_upstream_request(),
        }),
        R::SplitterSplit { mut state, data } => match base64_decode(&data) {
            Some(bytes) => {
                let segments = state.split(&bytes);
                json!({"state": state, "segments": segments})
            }
            None => json!({"state": state, "error": "data is not base64"}),
        },
        R::CursorImage { shape, width, height, hot_x, hot_y, rgba } => {
            json!(cursor::image(shape, width, height, hot_x, hot_y, &rgba))
        }
        R::CursorFeedShape { mut state, id } => {
            let out = state.receive_shape(id);
            json!({"state": state, "result": out})
        }
        R::CursorFeedDatagram { mut state, data } => {
            let result = match base64_decode(&data) {
                Some(bytes) => state.receive_datagram(&bytes),
                None => cursor::DatagramResult::NotCursor,
            };
            json!({"state": state, "result": result})
        }
        R::SurfacesParse { body } => json!(SurfaceChange::parse(&body)),
        R::SurfacesApply { mut state, change } => {
            let plan = state.apply(change);
            json!({"state": state, "plan": plan})
        }
        R::SurfacesStart { mut state, stream, surface } => {
            state.start(stream, surface);
            json!({"state": state})
        }
        R::SurfacesEnd { mut state, stream } => {
            state.end(stream);
            json!({"state": state})
        }
        R::SurfacesEndAll { mut state } => {
            let ended = state.end_all();
            json!({"state": state, "ended": ended})
        }
    }
}
