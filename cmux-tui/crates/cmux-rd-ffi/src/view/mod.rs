//! The remote desktop viewer's rules and state, moved out of the Swift
//! `CmuxNextRemoteView` module: keyboard routing and held keys, the pane's
//! state reducer, and the tab record and policy. Every op is pure: the
//! caller passes the state in and takes the next state back
//! (`cmux_rd_view_call`, `view_ffi.rs`).

pub mod keyboard;
pub mod pane;
pub mod tab;

use serde::Deserialize;
use serde_json::{Value, json};

use keyboard::{
    InputEvent, KeyboardMode, KeyboardState, ReleaseChord, ScrollAccumulator, SystemShortcuts,
    TapConditions, TapKey,
};
use pane::{LatencyHold, PaneEvent, PaneState};
use tab::{TabRecord, TabSource, Target};

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
    PaneReduce { state: PaneState, event: PaneEvent, now: i64 },
    #[serde(rename = "pane.view")]
    PaneView { state: PaneState },
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
}

fn view_mode() -> pane::ControlMode {
    pane::ControlMode::View
}

fn events(state: &KeyboardState, events: Vec<InputEvent>) -> Value {
    json!({"state": state, "events": events})
}

/// Runs one request; Err when the request is not one.
pub fn call(request: &[u8]) -> Result<Value, serde_json::Error> {
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
    }
}
