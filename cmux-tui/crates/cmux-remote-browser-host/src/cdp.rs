//! The DevTools-protocol presentation (docs/remote-browser-on-vm.md): the
//! same [`Presentation`] the CEF shim implements on macOS, played on a
//! headless Chromium over `--remote-debugging-pipe`. It is how a Linux machine
//! (a cloud VM) serves a remote tab: the CEF fork has no Linux release.
//!
//! Pure and platform-neutral: commands go out through a [`CdpSink`], and the
//! pipe's messages come back through [`CdpPresentation::on_message`], which
//! answers with [`CdpEvent`]s for the serve loop (src/cdp_serve.rs). The pipe
//! itself (NUL-delimited JSON) is [`encode_command`] and [`PipeDeframer`].

use std::collections::BTreeMap;

use cmux_remote_browser::proto::HistoryOp;
use cmux_remote_browser::rp_input::{RpCall, rp_mod};
use cmux_remote_browser::session::ScreenSize;
use serde_json::{Value, json};

use crate::page::PageChange;
use crate::tab::Presentation;

/// The largest message the pipe accepts from Chromium (a 4K JPEG frame in
/// base64 is well under it).
pub const MAX_MESSAGE_BYTES: usize = 64 * 1024 * 1024;

/// JPEG quality of the screencast. Frames are decoded and encoded again as
/// H.264, so this trades VM CPU and pipe bytes against a second generation
/// of loss.
pub const SCREENCAST_QUALITY: u32 = 85;

/// One DevTools command on the pipe: `{"id","method","params"[,"sessionId"]}`
/// followed by NUL.
pub fn encode_command(id: u64, session: Option<&str>, method: &str, params: &Value) -> Vec<u8> {
    let mut message = json!({"id": id, "method": method, "params": params});
    if let Some(session) = session {
        message["sessionId"] = Value::String(session.to_string());
    }
    let mut out = serde_json::to_vec(&message).unwrap_or_default();
    out.push(0);
    out
}

/// Splits Chromium's side of the pipe into JSON messages (each ends in NUL).
#[derive(Debug, Default)]
pub struct PipeDeframer {
    buf: Vec<u8>,
}

/// A message the deframer could not take.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PipeError {
    /// A message grew past [`MAX_MESSAGE_BYTES`] without its NUL.
    TooLarge,
    /// A complete message that is not a JSON object.
    NotJson,
}

impl PipeDeframer {
    pub fn extend(&mut self, bytes: &[u8]) {
        self.buf.extend_from_slice(bytes);
    }

    /// The next complete message, `None` until one is.
    pub fn next_message(&mut self) -> Result<Option<Value>, PipeError> {
        let Some(end) = self.buf.iter().position(|&b| b == 0) else {
            if self.buf.len() > MAX_MESSAGE_BYTES {
                return Err(PipeError::TooLarge);
            }
            return Ok(None);
        };
        let message: Vec<u8> = self.buf.drain(..=end).collect();
        match serde_json::from_slice::<Value>(&message[..end]) {
            Ok(value) if value.is_object() => Ok(Some(value)),
            _ => Err(PipeError::NotJson),
        }
    }
}

/// Where the presentation's commands go: the pipe in production, a list in
/// tests. Returns the command's id.
pub trait CdpSink {
    fn send(&mut self, session: Option<&str>, method: &str, params: Value) -> u64;
}

/// What a pipe message means for the tab (the serve loop calls the
/// [`crate::tab::HostTab`] method of each).
#[derive(Debug, Clone, PartialEq)]
pub enum CdpEvent {
    /// The tab of `request` exists as `browser` (`HostTab::tab_created`).
    TabCreated { request: i32, browser: i32 },
    /// Opening the tab of `request` failed.
    TabFailed { request: i32, error: String },
    /// One screencast frame (JPEG). Acknowledge it with
    /// [`CdpPresentation::ack_frame`] once it is encoded: Chromium sends the
    /// next one only then, which is the capture's back-pressure.
    Frame { browser: i32, jpeg: Vec<u8>, ack: i64, width: u32, height: u32 },
    /// A fact for `rb.page`.
    Page { browser: i32, change: PageChange },
    /// The page's renderer is gone (`HostTab::renderer_crashed`).
    Crashed { browser: i32 },
    /// The tab closed under the host (Chromium closed it).
    Closed { browser: i32 },
}

/// What a command's answer is for.
#[derive(Debug, Clone, PartialEq)]
enum Pending {
    Create { request: i32 },
    Attach { request: i32, target: String },
    History { browser: i32, forward: bool },
}

#[derive(Debug, Clone, PartialEq)]
struct Tab {
    target: String,
    session: String,
    capturing: bool,
    /// Mouse buttons held (CDP `buttons` bits: 1 left, 2 right, 4 middle).
    buttons: u8,
    can_go_back: bool,
    can_go_forward: bool,
    loading: bool,
}

/// [`Presentation`] over the DevTools protocol.
#[derive(Debug)]
pub struct CdpPresentation<S: CdpSink> {
    sink: S,
    screen: Option<ScreenSize>,
    tabs: BTreeMap<i32, Tab>,
    pending: BTreeMap<u64, Pending>,
    next_browser: i32,
}

/// CDP `modifiers`: Alt 1, Ctrl 2, Meta 4, Shift 8.
pub fn cdp_modifiers(rp: i32) -> i32 {
    let mut out = 0;
    for (from, to) in
        [(rp_mod::OPTION, 1), (rp_mod::CONTROL, 2), (rp_mod::COMMAND, 4), (rp_mod::SHIFT, 8)]
    {
        if rp & from != 0 {
            out |= to;
        }
    }
    out
}

/// The DOM button number (0 left, 1 middle, 2 right) as CDP names it and its
/// `buttons` bit.
fn cdp_button(button: i32) -> (&'static str, u8) {
    match button {
        1 => ("middle", 4),
        2 => ("right", 2),
        _ => ("left", 1),
    }
}

/// The button a move reports while `buttons` are held.
fn held_button(buttons: u8) -> &'static str {
    if buttons & 1 != 0 {
        "left"
    } else if buttons & 2 != 0 {
        "right"
    } else if buttons & 4 != 0 {
        "middle"
    } else {
        "none"
    }
}

/// Windows virtual key code of a DOM `code`: Chromium needs it for keys that
/// type no text (Enter, Backspace, the arrows) to act.
pub fn windows_key_code(code: &str) -> Option<i32> {
    if let Some(letter) = code.strip_prefix("Key")
        && let [c] = letter.as_bytes()
        && c.is_ascii_uppercase()
    {
        return Some(i32::from(*c));
    }
    if let Some(digit) = code.strip_prefix("Digit")
        && let [c] = digit.as_bytes()
        && c.is_ascii_digit()
    {
        return Some(i32::from(*c));
    }
    if let Some(digit) = code.strip_prefix("Numpad")
        && let [c] = digit.as_bytes()
        && c.is_ascii_digit()
    {
        return Some(0x60 + i32::from(c - b'0'));
    }
    if let Some(n) = code.strip_prefix('F').and_then(|n| n.parse::<i32>().ok())
        && (1..=24).contains(&n)
    {
        return Some(0x6F + n);
    }
    Some(match code {
        "Backspace" => 0x08,
        "Tab" => 0x09,
        "Enter" | "NumpadEnter" => 0x0D,
        "ShiftLeft" | "ShiftRight" => 0x10,
        "ControlLeft" | "ControlRight" => 0x11,
        "AltLeft" | "AltRight" => 0x12,
        "Pause" => 0x13,
        "CapsLock" => 0x14,
        "Escape" => 0x1B,
        "Space" => 0x20,
        "PageUp" => 0x21,
        "PageDown" => 0x22,
        "End" => 0x23,
        "Home" => 0x24,
        "ArrowLeft" => 0x25,
        "ArrowUp" => 0x26,
        "ArrowRight" => 0x27,
        "ArrowDown" => 0x28,
        "Insert" => 0x2D,
        "Delete" => 0x2E,
        "MetaLeft" => 0x5B,
        "MetaRight" => 0x5C,
        "ContextMenu" => 0x5D,
        "NumpadMultiply" => 0x6A,
        "NumpadAdd" => 0x6B,
        "NumpadSubtract" => 0x6D,
        "NumpadDecimal" => 0x6E,
        "NumpadDivide" => 0x6F,
        "Semicolon" => 0xBA,
        "Equal" => 0xBB,
        "Comma" => 0xBC,
        "Minus" => 0xBD,
        "Period" => 0xBE,
        "Slash" => 0xBF,
        "Backquote" => 0xC0,
        "BracketLeft" => 0xDB,
        "Backslash" => 0xDC,
        "BracketRight" => 0xDD,
        "Quote" => 0xDE,
        _ => return None,
    })
}

/// Pixels one wheel line scrolls when the viewer's deltas are lines (a mouse
/// wheel, not a trackpad).
const LINE_PIXELS: f64 = 40.0;

/// The DevTools commands of one input call on a tab holding `buttons`.
/// Updates `buttons`. Empty when the call has no DevTools form (popup
/// surfaces and pinch: headless Chromium has neither).
pub fn input_commands(call: &RpCall, buttons: &mut u8) -> Vec<(&'static str, Value)> {
    match call {
        RpCall::SendKey { down, code, key, text, unmodified_text, modifiers, commands } => {
            let kind = match (*down, text.is_empty()) {
                (false, _) => "keyUp",
                (true, true) => "rawKeyDown",
                (true, false) => "keyDown",
            };
            let mut params = json!({
                "type": kind,
                "modifiers": cdp_modifiers(*modifiers),
                "code": code,
                "key": key,
                "autoRepeat": modifiers & rp_mod::REPEAT != 0,
            });
            if let Some(vk) = windows_key_code(code) {
                params["windowsVirtualKeyCode"] = json!(vk);
                params["nativeVirtualKeyCode"] = json!(vk);
            }
            if *down && !text.is_empty() {
                params["text"] = json!(text);
                params["unmodifiedText"] = json!(unmodified_text);
            }
            if !commands.is_empty() {
                params["commands"] = commands.iter().map(|(name, _)| json!(name)).collect();
            }
            vec![("Input.dispatchKeyEvent", params)]
        }
        RpCall::PageMouse { kind, x, y, button, click_count, modifiers } => {
            let (name, bit) = cdp_button(*button);
            let (kind, button_name) = match kind {
                1 => {
                    *buttons |= bit;
                    ("mousePressed", name)
                }
                2 => {
                    *buttons &= !bit;
                    ("mouseReleased", name)
                }
                _ => ("mouseMoved", held_button(*buttons)),
            };
            vec![(
                "Input.dispatchMouseEvent",
                json!({
                    "type": kind, "x": x, "y": y, "button": button_name, "buttons": *buttons,
                    "clickCount": click_count, "modifiers": cdp_modifiers(*modifiers),
                }),
            )]
        }
        RpCall::SendWheel { x, y, dx, dy, precise, modifiers, .. } => {
            // The viewer sends AppKit deltas (positive scrolls up); DevTools'
            // positive deltaY scrolls down.
            let scale = if *precise { 1.0 } else { LINE_PIXELS };
            vec![(
                "Input.dispatchMouseEvent",
                json!({
                    "type": "mouseWheel", "x": x, "y": y, "deltaX": -dx * scale,
                    "deltaY": -dy * scale, "modifiers": cdp_modifiers(*modifiers),
                    "button": "none", "buttons": *buttons,
                }),
            )]
        }
        RpCall::ImeSetComposition { text, selection_start, selection_end, replacement, .. } => {
            let mut params = json!({
                "text": text, "selectionStart": selection_start, "selectionEnd": selection_end,
            });
            if let Some([start, end]) = replacement {
                params["replacementStart"] = json!(start);
                params["replacementEnd"] = json!(end);
            }
            vec![("Input.imeSetComposition", params)]
        }
        RpCall::ImeCommit { text, .. } => vec![("Input.insertText", json!({"text": text}))],
        RpCall::ImeCancel => vec![(
            "Input.imeSetComposition",
            json!({"text": "", "selectionStart": 0, "selectionEnd": 0}),
        )],
        // The composition's text is already in the field; finishing keeps it.
        RpCall::ImeFinish { .. } => Vec::new(),
        RpCall::SendPinch { .. } | RpCall::SurfaceMouse { .. } => Vec::new(),
    }
}

/// `Emulation.setDeviceMetricsOverride` of a screen.
fn metrics(screen: ScreenSize) -> Value {
    json!({
        "width": screen.css_width, "height": screen.css_height,
        "deviceScaleFactor": screen.scale, "mobile": false,
        "screenWidth": screen.css_width, "screenHeight": screen.css_height,
    })
}

/// `Page.startScreencast` of a screen (device pixels).
fn screencast(screen: ScreenSize) -> Value {
    let px = |css: u32| (f64::from(css) * screen.scale).round();
    json!({
        "format": "jpeg", "quality": SCREENCAST_QUALITY,
        "maxWidth": px(screen.css_width), "maxHeight": px(screen.css_height), "everyNthFrame": 1,
    })
}

impl<S: CdpSink> CdpPresentation<S> {
    pub fn new(sink: S) -> Self {
        Self {
            sink,
            screen: None,
            tabs: BTreeMap::new(),
            pending: BTreeMap::new(),
            next_browser: 1,
        }
    }

    pub fn sink(&self) -> &S {
        &self.sink
    }

    pub fn sink_mut(&mut self) -> &mut S {
        &mut self.sink
    }

    fn browser_of_session(&self, session: &str) -> Option<i32> {
        self.tabs.iter().find(|(_, tab)| tab.session == session).map(|(&b, _)| b)
    }

    fn browser_of_target(&self, target: &str) -> Option<i32> {
        self.tabs.iter().find(|(_, tab)| tab.target == target).map(|(&b, _)| b)
    }

    fn on_tab(&mut self, browser: i32, method: &str, params: Value) -> bool {
        let Some(session) = self.tabs.get(&browser).map(|t| t.session.clone()) else {
            return false;
        };
        self.sink.send(Some(&session), method, params);
        true
    }

    /// Lets Chromium send the next screencast frame of `browser`.
    pub fn ack_frame(&mut self, browser: i32, ack: i64) {
        self.on_tab(browser, "Page.screencastFrameAck", json!({"sessionId": ack}));
    }

    /// The facts and requests one pipe message carries.
    pub fn on_message(&mut self, message: &Value) -> Vec<CdpEvent> {
        if let Some(id) = message.get("id").and_then(Value::as_u64) {
            return self.on_response(id, message);
        }
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            return Vec::new();
        };
        let params = message.get("params").cloned().unwrap_or(Value::Null);
        let browser = message
            .get("sessionId")
            .and_then(Value::as_str)
            .and_then(|session| self.browser_of_session(session));
        self.on_event(browser, method, &params)
    }

    fn on_response(&mut self, id: u64, message: &Value) -> Vec<CdpEvent> {
        let Some(pending) = self.pending.remove(&id) else { return Vec::new() };
        let error = message
            .get("error")
            .map(|e| e.get("message").and_then(Value::as_str).unwrap_or("error").to_string());
        let result = message.get("result").cloned().unwrap_or(Value::Null);
        match pending {
            Pending::Create { request } => {
                let target = result.get("targetId").and_then(Value::as_str);
                match (error, target) {
                    (None, Some(target)) => {
                        let id = self.sink.send(
                            None,
                            "Target.attachToTarget",
                            json!({"targetId": target, "flatten": true}),
                        );
                        self.pending
                            .insert(id, Pending::Attach { request, target: target.to_string() });
                        Vec::new()
                    }
                    (error, _) => vec![CdpEvent::TabFailed {
                        request,
                        error: error.unwrap_or_else(|| "no targetId".into()),
                    }],
                }
            }
            Pending::Attach { request, target } => {
                let session = result.get("sessionId").and_then(Value::as_str);
                let (None, Some(session)) = (error.clone(), session) else {
                    return vec![CdpEvent::TabFailed {
                        request,
                        error: error.unwrap_or_else(|| "no sessionId".into()),
                    }];
                };
                let browser = self.next_browser;
                self.next_browser += 1;
                self.tabs.insert(
                    browser,
                    Tab {
                        target,
                        session: session.to_string(),
                        capturing: false,
                        buttons: 0,
                        can_go_back: false,
                        can_go_forward: false,
                        loading: true,
                    },
                );
                self.on_tab(browser, "Page.enable", json!({}));
                self.on_tab(browser, "Inspector.enable", json!({}));
                if let Some(screen) = self.screen {
                    self.on_tab(browser, "Emulation.setDeviceMetricsOverride", metrics(screen));
                }
                vec![CdpEvent::TabCreated { request, browser }]
            }
            Pending::History { browser, forward } => {
                if error.is_some() {
                    return Vec::new();
                }
                let current = result.get("currentIndex").and_then(Value::as_i64).unwrap_or(0);
                let entries = result.get("entries").and_then(Value::as_array);
                let target = current + if forward { 1 } else { -1 };
                let Some(entry) = entries
                    .and_then(|e| usize::try_from(target).ok().and_then(|i| e.get(i)))
                    .and_then(|e| e.get("id"))
                    .cloned()
                else {
                    return Vec::new();
                };
                self.on_tab(browser, "Page.navigateToHistoryEntry", json!({"entryId": entry}));
                Vec::new()
            }
        }
    }

    fn on_event(&mut self, browser: Option<i32>, method: &str, params: &Value) -> Vec<CdpEvent> {
        match (method, browser) {
            ("Page.screencastFrame", Some(browser)) => {
                use base64::Engine as _;
                let Some(ack) = params.get("sessionId").and_then(Value::as_i64) else {
                    return Vec::new();
                };
                let data = params.get("data").and_then(Value::as_str).unwrap_or_default();
                let Ok(jpeg) = base64::engine::general_purpose::STANDARD.decode(data) else {
                    self.ack_frame(browser, ack);
                    return Vec::new();
                };
                let meta = params.get("metadata");
                let dim = |key: &str| {
                    meta.and_then(|m| m.get(key)).and_then(Value::as_f64).unwrap_or(0.0)
                };
                let scale = self.screen.map_or(1.0, |s| s.scale);
                let px = |v: f64| (v * scale).round().max(0.0) as u32;
                vec![CdpEvent::Frame {
                    browser,
                    jpeg,
                    ack,
                    width: px(dim("deviceWidth")),
                    height: px(dim("deviceHeight")),
                }]
            }
            ("Page.frameNavigated", Some(browser)) => {
                let frame = params.get("frame");
                if frame.and_then(|f| f.get("parentId")).is_some() {
                    return Vec::new();
                }
                let url = frame.and_then(|f| f.get("url")).and_then(Value::as_str);
                url.map(|url| CdpEvent::Page {
                    browser,
                    change: PageChange::Url(url.to_string()),
                })
                .into_iter()
                .collect()
            }
            ("Page.navigatedWithinDocument", Some(browser)) => params
                .get("url")
                .and_then(Value::as_str)
                .map(|url| CdpEvent::Page { browser, change: PageChange::Url(url.to_string()) })
                .into_iter()
                .collect(),
            ("Page.frameStartedLoading" | "Page.frameStoppedLoading", Some(browser)) => {
                let loading = method == "Page.frameStartedLoading";
                let Some(tab) = self.tabs.get_mut(&browser) else { return Vec::new() };
                if tab.loading == loading {
                    return Vec::new();
                }
                tab.loading = loading;
                let change = PageChange::Loading {
                    loading,
                    can_go_back: tab.can_go_back,
                    can_go_forward: tab.can_go_forward,
                };
                if !loading {
                    // Back and forward come from the history once loaded.
                    let session = tab.session.clone();
                    self.sink.send(Some(&session), "Runtime.evaluate", json!({
                        "expression": "history.length", "returnByValue": true,
                    }));
                }
                vec![CdpEvent::Page { browser, change }]
            }
            ("Target.targetInfoChanged", _) => {
                let info = params.get("targetInfo");
                let target = info.and_then(|i| i.get("targetId")).and_then(Value::as_str);
                let Some(browser) = target.and_then(|t| self.browser_of_target(t)) else {
                    return Vec::new();
                };
                info.and_then(|i| i.get("title"))
                    .and_then(Value::as_str)
                    .filter(|title| !title.is_empty())
                    .map(|title| CdpEvent::Page {
                        browser,
                        change: PageChange::Title(title.to_string()),
                    })
                    .into_iter()
                    .collect()
            }
            ("Inspector.targetCrashed", Some(browser)) => vec![CdpEvent::Crashed { browser }],
            ("Target.detachedFromTarget", _) => {
                let session = params.get("sessionId").and_then(Value::as_str);
                let Some(browser) = session.and_then(|s| self.browser_of_session(s)) else {
                    return Vec::new();
                };
                self.tabs.remove(&browser);
                vec![CdpEvent::Closed { browser }]
            }
            _ => Vec::new(),
        }
    }
}

impl<S: CdpSink> Presentation for CdpPresentation<S> {
    fn set_screen(&mut self, screen: ScreenSize) -> bool {
        if !(screen.scale.is_finite() && screen.scale > 0.0)
            || screen.css_width == 0
            || screen.css_height == 0
        {
            return false;
        }
        self.screen = Some(screen);
        let browsers: Vec<(i32, bool)> = self.tabs.iter().map(|(&b, t)| (b, t.capturing)).collect();
        for (browser, capturing) in browsers {
            self.on_tab(browser, "Emulation.setDeviceMetricsOverride", metrics(screen));
            if capturing {
                // The screencast's size is fixed at its start.
                self.on_tab(browser, "Page.stopScreencast", json!({}));
                self.on_tab(browser, "Page.startScreencast", screencast(screen));
            }
        }
        true
    }

    fn open_tab(&mut self, request: i32, url: &str, screen: ScreenSize) -> bool {
        self.screen.get_or_insert(screen);
        let id = self.sink.send(
            None,
            "Target.createTarget",
            json!({"url": url, "width": screen.css_width, "height": screen.css_height}),
        );
        self.pending.insert(id, Pending::Create { request });
        true
    }

    fn close_tab(&mut self, browser: i32) {
        if let Some(tab) = self.tabs.remove(&browser) {
            self.sink.send(None, "Target.closeTarget", json!({"targetId": tab.target}));
        }
    }

    fn capture(&mut self, browser: i32, on: bool) -> bool {
        let Some(screen) = self.screen else { return false };
        let Some(tab) = self.tabs.get_mut(&browser) else { return false };
        if tab.capturing == on {
            return true;
        }
        tab.capturing = on;
        if on {
            self.on_tab(browser, "Page.startScreencast", screencast(screen))
        } else {
            self.on_tab(browser, "Page.stopScreencast", json!({}))
        }
    }

    fn input(&mut self, browser: i32, call: &RpCall) -> bool {
        let Some(tab) = self.tabs.get_mut(&browser) else { return false };
        let commands = input_commands(call, &mut tab.buttons);
        if commands.is_empty() {
            return matches!(call, RpCall::ImeFinish { .. });
        }
        for (method, params) in commands {
            self.on_tab(browser, method, params);
        }
        true
    }

    // Headless Chromium shows no native menus: there is never one to answer.
    fn context_menu_result(&mut self, _fork_token: i64, _command: Option<i64>) -> bool {
        false
    }

    fn popup_menu_result(&mut self, _fork_token: i64, _indices: Option<&[u32]>) -> bool {
        false
    }

    fn dialog_result(&mut self, fork_token: i64, accept: bool, text: Option<&str>) -> bool {
        let Ok(browser) = i32::try_from(fork_token) else { return false };
        let mut params = json!({"accept": accept});
        if let Some(text) = text {
            params["promptText"] = json!(text);
        }
        self.on_tab(browser, "Page.handleJavaScriptDialog", params)
    }

    fn set_active(&mut self, browser: i32, active: bool) -> bool {
        self.on_tab(browser, "Emulation.setFocusEmulationEnabled", json!({"enabled": active}))
    }

    fn surface_capture(&mut self, _surface: u32) -> bool {
        false
    }

    fn surface_close(&mut self, _surface: u32) {}

    fn surface_refresh(&mut self, _surface: u32) -> bool {
        false
    }

    fn load_url(&mut self, browser: i32, url: &str) -> bool {
        self.on_tab(browser, "Page.navigate", json!({"url": url}))
    }

    fn history(&mut self, browser: i32, op: HistoryOp) -> bool {
        let Some(session) = self.tabs.get(&browser).map(|t| t.session.clone()) else {
            return false;
        };
        match op {
            HistoryOp::Back | HistoryOp::Forward => {
                let id = self.sink.send(Some(&session), "Page.getNavigationHistory", json!({}));
                self.pending
                    .insert(id, Pending::History { browser, forward: op == HistoryOp::Forward });
            }
            HistoryOp::Reload => {
                self.sink.send(Some(&session), "Page.reload", json!({}));
            }
            HistoryOp::ReloadNoCache => {
                self.sink.send(Some(&session), "Page.reload", json!({"ignoreCache": true}));
            }
            HistoryOp::Stop => {
                self.sink.send(Some(&session), "Page.stopLoading", json!({}));
            }
        }
        true
    }

    fn find(
        &mut self,
        browser: i32,
        query: &str,
        forward: bool,
        match_case: bool,
        _next: bool,
    ) -> bool {
        // window.find(string, caseSensitive, backwards, wrapAround): no match
        // count, so no rb.find.result yet (docs/remote-browser-on-vm.md, slice 3).
        let expression = format!(
            "window.find({}, {match_case}, {}, true)",
            serde_json::to_string(query).unwrap_or_else(|_| "\"\"".into()),
            !forward
        );
        self.on_tab(browser, "Runtime.evaluate", json!({"expression": expression}))
    }

    fn stop_finding(&mut self, browser: i32, keep_selection: bool) -> bool {
        if keep_selection {
            return self.tabs.contains_key(&browser);
        }
        self.on_tab(
            browser,
            "Runtime.evaluate",
            json!({"expression": "window.getSelection().removeAllRanges()"}),
        )
    }
}
