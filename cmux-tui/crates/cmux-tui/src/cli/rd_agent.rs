//! `cmux rd screenshot|click|type|key`: an agent's hands on a screen this Mac shares with another
//! of the person's devices (a Mac or a Linux machine), through the Screen Sharing tab that shows
//! it. The tab is the one viewer: these commands read its latest picture (`mac_screen.frame`) and
//! send input on its session (`mac_screen.input`), exactly as the pane does for a person's mouse
//! and keyboard (Packages/macOS/CmuxNext/Sources/CmuxNextMacScreen/MacScreenAgentControl.swift).
//!
//! - Coordinates are fractions of the shared display (`--x 0.5 --y 0.25` is the middle, a
//!   quarter down), so an agent clicks where it saw something in the screenshot whatever its size.
//!   [`to_stream_pixels`] maps them to the stream's pixels; the app refuses the input when the
//!   picture changed size meanwhile, and the command maps again once.
//! - Input needs a Full Control session, which the host's person allowed. A View Only tab refuses
//!   click, type and key; nothing here asks the hub for a scope or answers an approval.
//! - Every refusal is `{error, reason, next}` ([`RdError`]), where `next` is the one command that
//!   moves the agent on (open the tab, sign in, ask for control, or run this again once the host's
//!   person allowed it), beside the CLI's usual `{code, message, details, retryable}` keys.
//!
//! On a Mac `cmux rd serve|connect` stay the cmux-rd engine's subcommands (main.rs); only the four
//! verbs here and `rd help` come to this module.

use std::path::Path;
use std::time::Duration;

use cmux_computer_use::keys::{Key, KeyCombo, Modifier};
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, parse_globals};

/// The app methods (MacScreenPages.agentMethods, every build).
pub(super) const FRAME_METHOD: &str = "mac_screen.frame";
pub(super) const INPUT_METHOD: &str = "mac_screen.input";
const STATE_METHOD: &str = super::app::MAC_SCREENS_METHOD;
/// Writing a 5K picture as PNG takes the app a moment; input is answered at once.
const FRAME_TIMEOUT: Duration = Duration::from_secs(20);
const CALL_TIMEOUT: Duration = Duration::from_secs(5);

pub(super) const HELP: &str = "\
USAGE
  cmux rd screenshot --device DEVICE [--out FILE] [--json]
  cmux rd click --device DEVICE --x FRACTION --y FRACTION [--button left|right|middle] [--double] [--json]
  cmux rd type --device DEVICE TEXT [--json]
  cmux rd key --device DEVICE COMBO [--json]

Drive the screen of another of your devices (a Mac or a Linux machine) through the Screen
Sharing tab that shows it. Open one first:
  cmux tab new-mac-screen --device DEVICE --scope view     (screenshot)
  cmux tab new-mac-screen --device DEVICE --scope full     (click, type, key: its owner allows it)

  screenshot  Saves the tab's latest picture as PNG (default: a new file in the temporary folder).
  click       Clicks at a point given as fractions of the shared display: --x 0 is the left edge,
              --x 1 the right, --y 0 the top. --double clicks twice.
  type        Types TEXT as committed text, in any layout.
  key         Presses a key combo: cmd+shift+4, ctrl+alt+delete, return, escape, f5, up.

DEVICE is the device's name or id (as `cmux app mac-screens` lists the tabs). With --json, a
result is one object on stdout and a refusal is {\"error\", \"reason\", \"next\"} on stderr,
where next is the command to run.
";

/// The agent verbs this module owns after `rd`.
const VERBS: &[&str] = &["screenshot", "click", "type", "key"];

/// Handles `cmux rd <verb>` for the agent verbs and `cmux rd help`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = parse_globals(args).ok()?;
    let (first, rest) = command.split_first()?;
    if first != "rd" || !owns(rest.first().map(String::as_str)) {
        return None;
    }
    Some(run(&global, rest))
}

/// Whether the word after `rd` is this module's (main.rs leaves those to the CLI on a Mac).
pub(crate) fn owns(verb: Option<&str>) -> bool {
    matches!(verb, Some(v) if VERBS.contains(&v) || matches!(v, "help" | "--help" | "-h"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Button {
    Left,
    Right,
    Middle,
}

impl Button {
    /// cmux-rd-proto's button numbers (RemoteMouseButton in the app).
    fn number(self) -> u8 {
        match self {
            Self::Left => 1,
            Self::Middle => 2,
            Self::Right => 3,
        }
    }
    fn name(self) -> &'static str {
        match self {
            Self::Left => "left",
            Self::Middle => "middle",
            Self::Right => "right",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Verb {
    Screenshot { out: Option<String> },
    Click { x: f64, y: f64, button: Button, double: bool },
    Type { text: String },
    Key { combo: String, usages: Vec<u32> },
}

impl Verb {
    fn name(&self) -> &'static str {
        match self {
            Self::Screenshot { .. } => "screenshot",
            Self::Click { .. } => "click",
            Self::Type { .. } => "type",
            Self::Key { .. } => "key",
        }
    }
    /// Input reaches the other device; a screenshot only reads.
    fn is_input(&self) -> bool {
        !matches!(self, Self::Screenshot { .. })
    }
}

#[derive(Debug, Clone, PartialEq)]
pub(super) enum Request {
    Help,
    Run { device: String, verb: Verb, json: bool },
}

/// A refusal: a stable code, why in a sentence, and the one command that moves on.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct RdError {
    pub error: &'static str,
    pub reason: String,
    pub next: String,
    /// The same command can pass by running it again (a connect in progress, an approval).
    pub retryable: bool,
}

impl RdError {
    fn new(error: &'static str, reason: impl Into<String>, next: impl Into<String>) -> Self {
        Self { error, reason: reason.into(), next: next.into(), retryable: false }
    }
    fn retryable(mut self) -> Self {
        self.retryable = true;
        self
    }

    /// `{error, reason, next}`, plus the CLI's envelope keys (`code`, `message`, `details`,
    /// `retryable`) so a caller of every other command reads it the same way.
    pub(super) fn to_json(&self) -> Value {
        json!({
            "error": self.error,
            "reason": self.reason,
            "next": self.next,
            "code": format!("rd.{}", self.error),
            "message": format!("{}; next: {}", self.reason, self.next),
            "details": {"next": self.next},
            "retryable": self.retryable,
        })
    }
}

fn usage(reason: impl Into<String>) -> RdError {
    RdError::new("usage", reason, "cmux rd help")
}

pub(super) fn parse(args: &[String]) -> Result<Request, RdError> {
    let (verb, rest) = match args.split_first() {
        None => return Ok(Request::Help),
        Some((verb, rest)) => (verb.as_str(), rest),
    };
    if matches!(verb, "help" | "--help" | "-h") {
        return Ok(Request::Help);
    }
    if !VERBS.contains(&verb) {
        return Err(usage(format!("unknown rd command {verb:?}")));
    }
    let mut device = None;
    let mut out = None;
    let (mut x, mut y) = (None, None);
    let mut button = Button::Left;
    let mut double = false;
    let mut json = false;
    let mut words = Vec::new();
    let mut iter = rest.iter();
    let mut literal = false;
    while let Some(word) = iter.next() {
        if literal || !word.starts_with("--") || word == "--" {
            if word == "--" && !literal {
                literal = true;
                continue;
            }
            words.push(word.clone());
            continue;
        }
        let (flag, inline) = match word.split_once('=') {
            Some((flag, value)) => (flag, Some(value.to_owned())),
            None => (word.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| iter.next().cloned())
                .ok_or_else(|| usage(format!("{flag} needs a value")))
        };
        match (verb, flag) {
            (_, "--json") => json = true,
            (_, "--device") => device = Some(value()?),
            ("screenshot", "--out") => out = Some(value()?),
            ("click", "--x") => x = Some(fraction("--x", &value()?)?),
            ("click", "--y") => y = Some(fraction("--y", &value()?)?),
            ("click", "--button") => {
                button = match value()?.as_str() {
                    "left" => Button::Left,
                    "right" => Button::Right,
                    "middle" => Button::Middle,
                    other => {
                        return Err(usage(format!(
                            "--button takes left, right or middle, not {other:?}"
                        )));
                    }
                }
            }
            ("click", "--double") => double = true,
            _ => return Err(usage(format!("rd {verb} takes no {flag}"))),
        }
    }
    let device = device.filter(|d| !d.trim().is_empty()).ok_or_else(|| {
        RdError::new("usage", format!("rd {verb} needs --device DEVICE"), "cmux app mac-screens")
    })?;
    let verb = match verb {
        "screenshot" => {
            no_words(verb, &words)?;
            Verb::Screenshot { out }
        }
        "click" => {
            no_words(verb, &words)?;
            let (Some(x), Some(y)) = (x, y) else {
                return Err(usage(
                    "rd click needs --x and --y, fractions of the display from 0 to 1",
                ));
            };
            Verb::Click { x, y, button, double }
        }
        "type" => {
            let text = words.join(" ");
            if text.is_empty() {
                return Err(usage("rd type needs TEXT"));
            }
            Verb::Type { text }
        }
        _ => {
            let [combo] = words.as_slice() else {
                return Err(usage("rd key takes one COMBO, like cmd+shift+4"));
            };
            let usages = key_usages(combo).map_err(usage)?;
            Verb::Key { combo: combo.clone(), usages }
        }
    };
    Ok(Request::Run { device, verb, json })
}

fn no_words(verb: &str, words: &[String]) -> Result<(), RdError> {
    match words.first() {
        None => Ok(()),
        Some(word) => Err(usage(format!("rd {verb} takes no {word:?}"))),
    }
}

/// A coordinate from 0 (left or top edge) to 1 (right or bottom edge).
fn fraction(flag: &str, text: &str) -> Result<f64, RdError> {
    match text.parse::<f64>() {
        Ok(value) if (0.0..=1.0).contains(&value) => Ok(value),
        _ => {
            Err(usage(format!("{flag} takes a fraction of the display from 0 to 1, not {text:?}")))
        }
    }
}

/// The pixel of a `width` x `height` stream at fractions `x`, `y`: 0 is the first pixel, 1 the
/// last (never one past the edge).
pub(super) fn to_stream_pixels(x: f64, y: f64, width: u32, height: u32) -> (i32, i32) {
    let axis = |fraction: f64, size: u32| -> i32 {
        let last = size.saturating_sub(1) as f64;
        (fraction.clamp(0.0, 1.0) * size as f64).floor().min(last) as i32
    };
    (axis(x, width), axis(y, height))
}

/// `"1920x1080"` (`mac_screen.state`'s `frame`) as a size; `None` before a picture.
pub(super) fn frame_size(text: &str) -> Option<(u32, u32)> {
    let (w, h) = text.split_once('x')?;
    let (w, h) = (w.parse::<u32>().ok()?, h.parse::<u32>().ok()?);
    (w > 0 && h > 0).then_some((w, h))
}

const fn hid(id: u32) -> u32 {
    0x07_0000 | id
}

/// A character's key on a US layout, and whether it takes Shift.
fn char_usage(c: char) -> Option<(u32, bool)> {
    const SHIFTED_DIGITS: &str = ")!@#$%^&*(";
    const PUNCT: &[(char, char, u32)] = &[
        ('-', '_', 0x2D),
        ('=', '+', 0x2E),
        ('[', '{', 0x2F),
        (']', '}', 0x30),
        ('\\', '|', 0x31),
        (';', ':', 0x33),
        ('\'', '"', 0x34),
        ('`', '~', 0x35),
        (',', '<', 0x36),
        ('.', '>', 0x37),
        ('/', '?', 0x38),
    ];
    let digit = |d: u32| if d == 0 { 0x27 } else { 0x1E + d - 1 };
    Some(match c {
        'a'..='z' => (0x04 + (c as u32 - 'a' as u32), false),
        'A'..='Z' => (0x04 + (c as u32 - 'A' as u32), true),
        '0'..='9' => (digit(c as u32 - '0' as u32), false),
        ' ' => (0x2C, false),
        _ => {
            if let Some(d) = SHIFTED_DIGITS.find(c) {
                (digit(d as u32), true)
            } else {
                let (plain, _, id) = *PUNCT.iter().find(|(p, s, _)| *p == c || *s == c)?;
                (id, plain != c)
            }
        }
    })
}

fn named_usage(key: &Key) -> Option<u32> {
    Some(match key {
        Key::Return => 0x28,
        Key::Escape => 0x29,
        Key::Backspace => 0x2A,
        Key::Tab => 0x2B,
        Key::Space => 0x2C,
        Key::Home => 0x4A,
        Key::PageUp => 0x4B,
        Key::Delete => 0x4C,
        Key::End => 0x4D,
        Key::PageDown => 0x4E,
        Key::Right => 0x4F,
        Key::Left => 0x50,
        Key::Down => 0x51,
        Key::Up => 0x52,
        Key::F(n @ 1..=12) => 0x3A + u32::from(*n) - 1,
        Key::F(n @ 13..=24) => 0x68 + u32::from(*n) - 13,
        Key::F(_) | Key::Char(_) => return None,
    })
}

fn modifier_usage(modifier: Modifier) -> Option<u32> {
    Some(match modifier {
        Modifier::Control => 0xE0,
        Modifier::Shift => 0xE1,
        Modifier::Alt => 0xE2,
        Modifier::Meta => 0xE3,
        Modifier::Fn => return None,
    })
}

/// A combo (cmux Computer Use's vocabulary: `cmd+shift+4`, `ctrl+alt+delete`, `return`) as HID
/// usages to press in order: modifiers first, the key last. A character that takes Shift on a US
/// layout (`A`, `?`) adds Shift.
pub(super) fn key_usages(text: &str) -> Result<Vec<u32>, String> {
    let combo = KeyCombo::parse(text)?;
    let mut modifiers = Vec::new();
    for modifier in &combo.modifiers {
        let usage = modifier_usage(*modifier)
            .ok_or_else(|| format!("{text:?}: fn has no key code another device can receive"))?;
        modifiers.push(usage);
    }
    let key = match &combo.key {
        Key::Char(c) => {
            let (usage, shift) = char_usage(*c)
                .ok_or_else(|| format!("{text:?}: no key types {c:?}; use rd type for text"))?;
            if shift && !modifiers.contains(&0xE1) {
                modifiers.push(0xE1);
            }
            usage
        }
        named => named_usage(named).ok_or_else(|| format!("{text:?}: no such key"))?,
    };
    Ok(modifiers.into_iter().chain([key]).map(hid).collect())
}

/// The events of one verb, in `mac_screen.input`'s shape, for a stream `size` big.
pub(super) fn input_events(verb: &Verb, size: (u32, u32)) -> Vec<Value> {
    match verb {
        Verb::Screenshot { .. } => Vec::new(),
        Verb::Click { x, y, button, double } => {
            let (px, py) = to_stream_pixels(*x, *y, size.0, size.1);
            let mut events = vec![json!({"t": "pointer", "x": px, "y": py})];
            for _ in 0..if *double { 2 } else { 1 } {
                for down in [true, false] {
                    events.push(json!({"t": "button", "button": button.number(), "down": down}));
                }
            }
            events
        }
        Verb::Type { text } => vec![json!({"t": "text", "text": text})],
        Verb::Key { usages, .. } => {
            let downs = usages.iter().map(|u| json!({"t": "key", "usage": u, "down": true}));
            let ups = usages.iter().rev().map(|u| json!({"t": "key", "usage": u, "down": false}));
            downs.chain(ups).collect()
        }
    }
}

fn shell_quote(text: &str) -> String {
    super::cloud_start_chat::shell_quote(text)
}

/// This command again, as the agent would type it (the `next` of a refusal that passes by waiting).
pub(super) fn command_line(device: &str, verb: &Verb, json: bool) -> String {
    let mut words = vec![
        "cmux".to_owned(),
        "rd".into(),
        verb.name().into(),
        "--device".into(),
        shell_quote(device),
    ];
    if json {
        words.push("--json".into());
    }
    match verb {
        Verb::Screenshot { out } => {
            if let Some(out) = out {
                words.extend(["--out".into(), shell_quote(out)]);
            }
        }
        Verb::Click { x, y, button, double } => {
            words.extend(["--x".into(), x.to_string(), "--y".into(), y.to_string()]);
            if *button != Button::Left {
                words.extend(["--button".into(), button.name().into()]);
            }
            if *double {
                words.push("--double".into());
            }
        }
        Verb::Type { text } => {
            if text.starts_with('-') {
                words.push("--".into());
            }
            words.push(shell_quote(text));
        }
        Verb::Key { combo, .. } => words.push(shell_quote(combo)),
    }
    words.join(" ")
}

/// The command that opens a Screen Sharing tab on `device` with the scope `verb` needs.
pub(super) fn open_command(device: &str, verb: &Verb) -> String {
    let scope = if verb.is_input() { "full" } else { "view" };
    format!("cmux tab new-mac-screen --device {} --scope {scope}", shell_quote(device))
}

/// One Mac Screen tab of `mac_screen.state`.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct TabRow {
    pub tab: String,
    pub device_id: Option<String>,
    pub device: String,
    pub connected: bool,
    pub has_frame: bool,
    pub frame: Option<(u32, u32)>,
}

pub(super) fn tab_rows(state: &Value) -> Vec<TabRow> {
    let rows = state.get("tabs").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    rows.iter()
        .filter_map(|row| {
            Some(TabRow {
                tab: row.get("tab")?.as_str()?.to_owned(),
                device_id: row.get("device_id").and_then(Value::as_str).map(str::to_owned),
                device: row.get("device").and_then(Value::as_str).unwrap_or_default().to_owned(),
                connected: row.get("connected").and_then(Value::as_bool).unwrap_or(false),
                has_frame: row.get("has_frame").and_then(Value::as_bool).unwrap_or(false),
                frame: row.get("frame").and_then(Value::as_str).and_then(frame_size),
            })
        })
        .collect()
}

/// The tab showing `device`: its exact id, its name (any case), a unique id prefix of four or
/// more characters, or the tab's own id. Of several tabs on one device, a streaming one first.
pub(super) fn pick_tab<'a>(
    rows: &'a [TabRow],
    device: &str,
    verb: &Verb,
) -> Result<&'a TabRow, RdError> {
    let wanted = device.trim();
    let by = |test: &dyn Fn(&TabRow) -> bool| rows.iter().filter(|r| test(r)).collect::<Vec<_>>();
    let mut matches = by(&|r| r.device_id.as_deref() == Some(wanted) || r.tab == wanted);
    if matches.is_empty() {
        matches = by(&|r| r.device.eq_ignore_ascii_case(wanted));
    }
    if matches.is_empty() && wanted.len() >= 4 {
        matches = by(&|r| r.device_id.as_deref().is_some_and(|id| id.starts_with(wanted)));
    }
    let devices: std::collections::BTreeSet<_> =
        matches.iter().map(|r| r.device_id.clone().unwrap_or_else(|| r.tab.clone())).collect();
    if devices.len() > 1 {
        let names: Vec<_> = matches
            .iter()
            .map(|r| format!("{} ({})", r.device, r.device_id.as_deref().unwrap_or("?")))
            .collect();
        return Err(RdError::new(
            "ambiguous_device",
            format!("{wanted:?} names more than one device: {}", names.join(", ")),
            "cmux app mac-screens",
        ));
    }
    matches.sort_by_key(|r| (!(r.connected && r.has_frame), r.tab.clone()));
    matches.into_iter().next().ok_or_else(|| {
        RdError::new(
            "no_screen_tab",
            format!("no Screen Sharing tab shows {wanted:?}"),
            open_command(wanted, verb),
        )
    })
}

/// The app's refusal (`mac_screen.<state>`, MacScreenAgentControl.swift) as the agent's next step.
pub(super) fn explain_refusal(code: &str, device: &str, verb: &Verb, json: bool) -> RdError {
    let again = command_line(device, verb, json);
    let open = open_command(device, verb);
    let state = code.strip_prefix("mac_screen.").unwrap_or(code);
    let quoted = shell_quote(device);
    match state {
        "no_tab" => RdError::new(
            "no_screen_tab",
            format!("the Screen Sharing tab for {device:?} closed"),
            open,
        ),
        "connect_card" => RdError::new(
            "not_connected",
            format!("the tab for {device:?} waits at its Connect card: nothing streams"),
            open,
        ),
        "requesting" | "connecting" | "no_frame" => {
            RdError::new("connecting", format!("the tab for {device:?} is still connecting"), again)
                .retryable()
        }
        "waiting_for_approval" => RdError::new(
            "waiting_for_approval",
            format!("{device:?} has not allowed this Mac yet: its owner decides on that device"),
            again,
        )
        .retryable(),
        "declined" => RdError::new("declined", format!("{device:?}'s owner declined"), open),
        "view_only" => RdError::new(
            "view_only",
            format!(
                "the tab views {device:?} without control: rd {} needs Full Control, which its owner allows",
                verb.name()
            ),
            format!("cmux tab new-mac-screen --device {quoted} --scope full"),
        ),
        "not_signed_in" => {
            RdError::new("signed_out", "this Mac is not signed in to cmux", "cmux login")
        }
        "scope_exceeds" => RdError::new(
            "control_not_allowed",
            format!("{device:?} lets this Mac view only, not control"),
            format!("cmux rd screenshot --device {quoted}"),
        ),
        "permission_none" => RdError::new(
            "not_allowed",
            format!("{device:?} does not let this Mac view it"),
            "cmux device list",
        ),
        "host_offline" => {
            RdError::new("device_offline", format!("{device:?} is offline"), "cmux device list")
        }
        "not_shared" => RdError::new(
            "not_shared",
            format!("{device:?} does not share its screen; turn sharing on there"),
            "cmux device list",
        ),
        "not_found" => RdError::new(
            "unknown_device",
            format!("{device:?} is no longer one of your devices"),
            "cmux device list",
        ),
        "frame_changed" => RdError::new(
            "frame_changed",
            format!("{device:?}'s display changed size; take a new screenshot"),
            format!("cmux rd screenshot --device {quoted}"),
        )
        .retryable(),
        "revoked" | "ended" | "stream_failed" | "failed" | "unsupported" | "refused" => {
            RdError::new(
                "session_ended",
                format!("the session with {device:?} ended ({state})"),
                open,
            )
        }
        other => {
            RdError::new("refused", format!("the app refused: {other}"), "cmux app mac-screens")
        }
    }
}

/// An app connection failure or a refusal that is not a Mac Screen state.
fn app_error(error: &Value) -> RdError {
    let code = error.get("code").and_then(Value::as_str).unwrap_or("refused");
    let message = error.get("message").and_then(Value::as_str).unwrap_or(code);
    if code == "method_not_found" {
        return RdError::new(
            "app_outdated",
            "the running cmux app does not serve mac_screen.frame and mac_screen.input",
            "cmux settings check-for-updates",
        );
    }
    if code.starts_with("socket.") || code.starts_with("transport") || code.starts_with("app.") {
        return RdError::new(
            "app_unreachable",
            format!("the cmux app does not answer: {message}"),
            "open -a cmux",
        )
        .retryable();
    }
    RdError::new("refused", message.to_owned(), "cmux app mac-screens")
}

fn print_error(error: &RdError, output: OutputMode) -> i32 {
    let code = if error.error == "usage" { 2 } else { 1 };
    super::wire::print_local_error(&error.to_json(), output, code)
}

fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    let request = match parse(args) {
        Ok(request) => request,
        Err(error) => {
            let output =
                if args.iter().any(|a| a == "--json") { OutputMode::Json } else { global.output };
            return print_error(&error, output);
        }
    };
    let Request::Run { device, verb, json } = request else {
        print!("{HELP}");
        return 0;
    };
    let output = if json { OutputMode::Json } else { global.output };
    match drive(global, &device, &verb, json) {
        Ok(value) => super::wire::print_local_success(&value, output),
        Err(error) => print_error(&error, output),
    }
}

/// One call to the app: its answer, or the refusal as the agent's next step.
fn call(
    stream: &mut std::os::unix::net::UnixStream,
    method: &str,
    params: Value,
    timeout: Duration,
    device: &str,
    verb: &Verb,
    json: bool,
) -> Result<Value, RdError> {
    match super::app::request(stream, method, params, timeout) {
        Err(message) => Err(app_error(&json!({"code": "transport", "message": message}))),
        Ok(Err(error)) => {
            let code = error.get("code").and_then(Value::as_str).unwrap_or_default();
            if code.starts_with("mac_screen.") {
                Err(explain_refusal(code, device, verb, json))
            } else {
                Err(app_error(&error))
            }
        }
        Ok(Ok(value)) => Ok(value),
    }
}

fn drive(global: &GlobalArgs, device: &str, verb: &Verb, json: bool) -> Result<Value, RdError> {
    let mut stream = super::app::connect_command(global).map_err(|error| app_error(&error))?;
    let read_tab = |stream: &mut std::os::unix::net::UnixStream| -> Result<TabRow, RdError> {
        let state = call(stream, STATE_METHOD, json!({}), CALL_TIMEOUT, device, verb, json)?;
        let rows = tab_rows(&state);
        pick_tab(&rows, device, verb).cloned()
    };
    let row = read_tab(&mut stream)?;
    let answer_base = |row: &TabRow| {
        let mut base = Map::new();
        base.insert("device".into(), json!(row.device));
        base.insert("device_id".into(), json!(row.device_id));
        base.insert("tab".into(), json!(row.tab));
        base
    };
    if let Verb::Screenshot { out } = verb {
        let path = screenshot_path(out.as_deref(), &row.device)?;
        if let Some(parent) = Path::new(&path).parent() {
            std::fs::create_dir_all(parent).map_err(|e| {
                RdError::new(
                    "bad_out",
                    format!("cannot make {}: {e}", parent.display()),
                    "cmux rd screenshot --device DEVICE --out /tmp/screen.png",
                )
            })?;
        }
        let answer = call(
            &mut stream,
            FRAME_METHOD,
            json!({"tab": row.tab, "path": path}),
            FRAME_TIMEOUT,
            device,
            verb,
            json,
        )?;
        let mut value = answer_base(&row);
        value.insert("path".into(), json!(path));
        value.insert("width".into(), answer.get("width").cloned().unwrap_or(Value::Null));
        value.insert("height".into(), answer.get("height").cloned().unwrap_or(Value::Null));
        return Ok(Value::Object(value));
    }
    // Input: map against the picture's size; the app refuses a changed size, and one fresh read retries.
    let mut row = row;
    for attempt in 0..2 {
        let Some(size) = row.frame.filter(|_| row.has_frame) else {
            // No picture yet: the app says why (connect card, approval, connecting).
            call(
                &mut stream,
                INPUT_METHOD,
                json!({"tab": row.tab, "events": []}),
                CALL_TIMEOUT,
                device,
                verb,
                json,
            )?;
            return Err(explain_refusal("no_frame", device, verb, json));
        };
        let events = input_events(verb, size);
        let params =
            json!({"tab": row.tab, "frame": format!("{}x{}", size.0, size.1), "events": events});
        match call(&mut stream, INPUT_METHOD, params, CALL_TIMEOUT, device, verb, json) {
            Ok(answer) => {
                let mut value = answer_base(&row);
                value.insert(
                    "sent".into(),
                    answer.get("sent").cloned().unwrap_or(json!(events.len())),
                );
                value.insert("frame".into(), json!({"width": size.0, "height": size.1}));
                if let Verb::Click { x, y, .. } = verb {
                    let (px, py) = to_stream_pixels(*x, *y, size.0, size.1);
                    value.insert("pixel".into(), json!({"x": px, "y": py}));
                }
                return Ok(Value::Object(value));
            }
            Err(error) if error.error == "frame_changed" && attempt == 0 => {
                row = read_tab(&mut stream)?;
            }
            Err(error) => return Err(error),
        }
    }
    Err(explain_refusal("frame_changed", device, verb, json))
}

/// Where the PNG goes: `--out` made absolute, else a new file in the temporary folder.
pub(super) fn screenshot_path(out: Option<&str>, device: &str) -> Result<String, RdError> {
    if let Some(out) = out {
        if out == "-" || out.starts_with('~') || out.is_empty() {
            return Err(usage("--out takes a file path (absolute or relative to here)"));
        }
        return Ok(super::app::caller_absolute(out).unwrap_or_else(|| out.to_owned()));
    }
    let slug: String = device
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .chars()
        .take(40)
        .collect();
    let millis = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let name = format!("cmux-rd-{}-{millis}.png", if slug.is_empty() { "screen" } else { &slug });
    Ok(std::env::temp_dir().join(name).to_string_lossy().into_owned())
}

#[cfg(test)]
mod tests;
