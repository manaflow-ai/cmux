//! The browser automation's input rules (Swift `KeyStroke`, `DOMKeyCodes` and `MouseEventPlan` in
//! `CmuxNextBrowserAutomation`): a driver `input.key` call's Playwright key description becomes
//! the virtual key code, modifier flags and characters of one AppKit key event, and a driver
//! `input.mouse` call becomes an AppKit mouse event type, with the buttons held across calls.
//!
//! Modifier flags are `NSEvent.ModifierFlags` raw values ([`flag`]); event types are
//! `NSEvent.EventType` case names (`leftMouseDragged`).
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `browser_rules_input_key_stroke` | `{key, code, text, modifiers}` | the [`KeyStroke`], or null |
//! | `browser_rules_input_mouse_event` | `{held, type, button}` | `{eventType, held}` ([`MouseEventPlan`]) |
//! | `browser_rules_input_view_point` | `{css: {x, y}, scale, viewHeight, flipped}` | `{x, y}` |

use crate::ops::OpError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// `NSEvent.ModifierFlags` raw values.
pub mod flag {
    pub const CAPS_LOCK: u64 = 1 << 16;
    pub const SHIFT: u64 = 1 << 17;
    pub const CONTROL: u64 = 1 << 18;
    pub const OPTION: u64 = 1 << 19;
    pub const COMMAND: u64 = 1 << 20;
    pub const NUMERIC_PAD: u64 = 1 << 21;
    pub const FUNCTION: u64 = 1 << 23;
}

/// One native key event for a driver `input.key` call.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyStroke {
    pub key_code: u16,
    /// `NSEvent.ModifierFlags` raw value.
    pub modifier_flags: u64,
    /// Characters the event carries (empty for modifier keys).
    pub characters: String,
    pub characters_ignoring_modifiers: String,
    /// Set for Shift, Control, Alt, Meta and CapsLock: the event is `.flagsChanged`.
    pub is_modifier: bool,
    /// A Cocoa editing selector for Meta shortcuts (`selectAll:`).
    pub editing_command: Option<String>,
}

const LETTERS: [(&str, u16); 26] = [
    ("A", 0x00),
    ("S", 0x01),
    ("D", 0x02),
    ("F", 0x03),
    ("H", 0x04),
    ("G", 0x05),
    ("Z", 0x06),
    ("X", 0x07),
    ("C", 0x08),
    ("V", 0x09),
    ("B", 0x0B),
    ("Q", 0x0C),
    ("W", 0x0D),
    ("E", 0x0E),
    ("R", 0x0F),
    ("Y", 0x10),
    ("T", 0x11),
    ("O", 0x1F),
    ("U", 0x20),
    ("I", 0x22),
    ("P", 0x23),
    ("L", 0x25),
    ("J", 0x26),
    ("K", 0x28),
    ("N", 0x2D),
    ("M", 0x2E),
];
const DIGITS: [u16; 10] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19];
const PAD: [u16; 10] = [0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5B, 0x5C];
const FUNCTION: [u16; 12] =
    [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F];
const NAMED: [(&str, u16); 41] = [
    ("Equal", 0x18),
    ("Minus", 0x1B),
    ("BracketRight", 0x1E),
    ("BracketLeft", 0x21),
    ("Quote", 0x27),
    ("Semicolon", 0x29),
    ("Backslash", 0x2A),
    ("Comma", 0x2B),
    ("Slash", 0x2C),
    ("Period", 0x2F),
    ("Backquote", 0x32),
    ("Enter", 0x24),
    ("Tab", 0x30),
    ("Space", 0x31),
    ("Backspace", 0x33),
    ("Escape", 0x35),
    ("MetaRight", 0x36),
    ("MetaLeft", 0x37),
    ("ShiftLeft", 0x38),
    ("CapsLock", 0x39),
    ("AltLeft", 0x3A),
    ("ControlLeft", 0x3B),
    ("ShiftRight", 0x3C),
    ("AltRight", 0x3D),
    ("ControlRight", 0x3E),
    ("NumpadDecimal", 0x41),
    ("NumpadMultiply", 0x43),
    ("NumpadAdd", 0x45),
    ("NumpadDivide", 0x4B),
    ("NumpadEnter", 0x4C),
    ("NumpadSubtract", 0x4E),
    ("NumpadEqual", 0x51),
    ("Insert", 0x72),
    ("Home", 0x73),
    ("PageUp", 0x74),
    ("Delete", 0x75),
    ("End", 0x77),
    ("PageDown", 0x79),
    ("ArrowLeft", 0x7B),
    ("ArrowRight", 0x7C),
    ("ArrowDown", 0x7D),
];
const ARROW_UP: (&str, u16) = ("ArrowUp", 0x7E);

/// The macOS virtual key of a DOM `KeyboardEvent.code` (US layout).
pub fn virtual_key(code: &str) -> Option<u16> {
    if let Some(letter) = code.strip_prefix("Key") {
        return LETTERS.iter().find(|(name, _)| *name == letter).map(|(_, key)| *key);
    }
    if let Some(digit) = code.strip_prefix("Digit") {
        return single_digit(digit).and_then(|index| DIGITS.get(index).copied());
    }
    if let Some(digit) = code.strip_prefix("Numpad") {
        if let Some(key) = single_digit(digit).and_then(|index| PAD.get(index)) {
            return Some(*key);
        }
    }
    if let Some(number) = code.strip_prefix('F') {
        if let Ok(index) = number.parse::<usize>() {
            if (1..=12).contains(&index) && number == index.to_string() {
                return index.checked_sub(1).and_then(|at| FUNCTION.get(at)).copied();
            }
        }
    }
    if code == ARROW_UP.0 {
        return Some(ARROW_UP.1);
    }
    NAMED.iter().find(|(name, _)| *name == code).map(|(_, key)| *key)
}

fn single_digit(text: &str) -> Option<usize> {
    let mut chars = text.chars();
    match (chars.next(), chars.next()) {
        (Some(digit @ '0'..='9'), None) => Some(digit as usize - '0' as usize),
        _ => None,
    }
}

fn modifier_flag(code: &str) -> Option<u64> {
    Some(match code {
        "ShiftLeft" | "ShiftRight" => flag::SHIFT,
        "ControlLeft" | "ControlRight" => flag::CONTROL,
        "AltLeft" | "AltRight" => flag::OPTION,
        "MetaLeft" | "MetaRight" => flag::COMMAND,
        "CapsLock" => flag::CAPS_LOCK,
        _ => return None,
    })
}

fn function_char(value: u32) -> String {
    char::from_u32(value).unwrap_or('\0').to_string()
}

/// Characters AppKit puts on named keys (NSEvent function-key range).
fn named_characters(key: &str) -> Option<String> {
    let value = match key {
        "Enter" => return Some("\r".into()),
        "Tab" => return Some("\t".into()),
        "Backspace" => return Some("\u{7F}".into()),
        "Escape" => return Some("\u{1B}".into()),
        " " => return Some(" ".into()),
        "ArrowUp" => 0xF700,
        "ArrowDown" => 0xF701,
        "ArrowLeft" => 0xF702,
        "ArrowRight" => 0xF703,
        "Insert" => 0xF746,
        "Delete" => 0xF728,
        "Home" => 0xF729,
        "End" => 0xF72B,
        "PageUp" => 0xF72C,
        "PageDown" => 0xF72D,
        _ => {
            let number = key.strip_prefix('F')?;
            let index = number.parse::<u32>().ok()?;
            if !(1..=12).contains(&index) || number != index.to_string() {
                return None;
            }
            0xF703 + index
        }
    };
    Some(function_char(value))
}

const UNSHIFTED_SYMBOL: [(&str, &str); 12] = [
    ("Equal", "="),
    ("Minus", "-"),
    ("BracketRight", "]"),
    ("BracketLeft", "["),
    ("Quote", "'"),
    ("Semicolon", ";"),
    ("Backslash", "\\"),
    ("Comma", ","),
    ("Slash", "/"),
    ("Period", "."),
    ("Backquote", "`"),
    ("Space", " "),
];

const SHIFTED_SYMBOL: [(&str, &str); 21] = [
    ("!", "Digit1"),
    ("@", "Digit2"),
    ("#", "Digit3"),
    ("$", "Digit4"),
    ("%", "Digit5"),
    ("^", "Digit6"),
    ("&", "Digit7"),
    ("*", "Digit8"),
    ("(", "Digit9"),
    (")", "Digit0"),
    ("+", "Equal"),
    ("_", "Minus"),
    ("}", "BracketRight"),
    ("{", "BracketLeft"),
    ("\"", "Quote"),
    (":", "Semicolon"),
    ("|", "Backslash"),
    ("<", "Comma"),
    ("?", "Slash"),
    (">", "Period"),
    ("~", "Backquote"),
];

fn unshifted_symbol(code: &str) -> Option<&'static str> {
    UNSHIFTED_SYMBOL.iter().find(|(name, _)| *name == code).map(|(_, symbol)| *symbol)
}

fn shifted_symbol(key: &str) -> Option<&'static str> {
    SHIFTED_SYMBOL.iter().find(|(symbol, _)| *symbol == key).map(|(_, code)| *code)
}

fn is_function_key(code: &str) -> bool {
    matches!(
        code,
        "ArrowLeft"
            | "ArrowRight"
            | "ArrowDown"
            | "ArrowUp"
            | "Home"
            | "End"
            | "PageUp"
            | "PageDown"
            | "Delete"
            | "Insert"
    ) || (code.starts_with('F') && virtual_key(code).is_some() && code.len() <= 3)
}

fn is_numeric_pad(code: &str) -> bool {
    matches!(
        code,
        "NumpadDecimal"
            | "NumpadMultiply"
            | "NumpadAdd"
            | "NumpadDivide"
            | "NumpadEnter"
            | "NumpadSubtract"
            | "NumpadEqual"
            | "ArrowLeft"
            | "ArrowRight"
            | "ArrowDown"
            | "ArrowUp"
    ) || code.strip_prefix("Numpad").and_then(single_digit).is_some()
}

/// Meta shortcuts WebKit handles as editing commands.
fn editing_command(character: &str) -> Option<&'static str> {
    Some(match character {
        "a" => "selectAll:",
        "c" => "copy:",
        "x" => "cut:",
        "v" => "paste:",
        "z" => "undo:",
        _ => return None,
    })
}

fn is_single(text: &str) -> bool {
    text.chars().count() == 1
}

/// The `code` of a key given without one (`"a"`, `"Enter"`, `"#"`).
pub fn code_for_key(key: &str) -> Option<String> {
    if virtual_key(key).is_some() {
        return Some(key.to_owned());
    }
    if key == " " {
        return Some("Space".into());
    }
    if !is_single(key) {
        return None;
    }
    let scalar = key.to_lowercase().chars().next()? as u32;
    if (97..=122).contains(&scalar) {
        return Some(format!("Key{}", key.to_uppercase()));
    }
    if (48..=57).contains(&scalar) {
        return Some(format!("Digit{key}"));
    }
    if let Some((code, _)) = UNSHIFTED_SYMBOL.iter().find(|(_, symbol)| *symbol == key) {
        return Some((*code).to_owned());
    }
    shifted_symbol(key).map(str::to_owned)
}

/// Whether typing `key` on a US layout holds Shift (`"A"`, `"#"`).
pub fn needs_shift(key: &str) -> bool {
    is_single(key) && (key != key.to_lowercase() || shifted_symbol(key).is_some())
}

/// The flags of the runtime's modifier names (`Shift`, `Control`, `Alt`, `Meta`).
pub fn flags_named(names: &[String]) -> u64 {
    names.iter().fold(0, |flags, name| {
        flags
            | match name.as_str() {
                "Shift" => flag::SHIFT,
                "Control" => flag::CONTROL,
                "Alt" => flag::OPTION,
                "Meta" => flag::COMMAND,
                _ => 0,
            }
    })
}

/// The unshifted character of a printable key on a US layout.
fn base(code: &str, key: &str) -> String {
    if let Some(letter) = code.strip_prefix("Key").filter(|rest| rest.chars().count() == 1) {
        return letter.to_lowercase();
    }
    if let Some(digit) = code.strip_prefix("Digit").filter(|rest| rest.chars().count() == 1) {
        return digit.to_owned();
    }
    if let Some(symbol) = unshifted_symbol(code) {
        return symbol.to_owned();
    }
    if is_single(key) { key.to_lowercase() } else { String::new() }
}

/// Resolves a key; `None` when it has no macOS virtual key (the caller inserts `text` through
/// the text input client instead).
pub fn resolve(
    key: &str,
    code: &str,
    text: Option<&str>,
    modifiers: &[String],
) -> Option<KeyStroke> {
    let code =
        if code.is_empty() { code_for_key(key).unwrap_or_default() } else { code.to_owned() };
    let key_code = virtual_key(&code)?;
    let mut flags = flags_named(modifiers);
    if let Some(modifier) = modifier_flag(&code) {
        return Some(KeyStroke {
            key_code,
            modifier_flags: flags | modifier,
            characters: String::new(),
            characters_ignoring_modifiers: String::new(),
            is_modifier: true,
            editing_command: None,
        });
    }
    let named = named_characters(key);
    let ignoring = named.clone().unwrap_or_else(|| base(&code, key));
    // Key-up carries no text from the runtime; the event still needs the key's characters so
    // keyup reports the same key as keydown.
    let mut characters = named
        .or_else(|| text.map(str::to_owned))
        .unwrap_or_else(|| if is_single(key) { key.to_owned() } else { String::new() });
    if needs_shift(key) {
        flags |= flag::SHIFT;
    }
    let mut scalars = ignoring.chars();
    let control = match (scalars.next(), scalars.next()) {
        (Some(scalar), None) if (97..=122).contains(&(scalar as u32)) => {
            char::from_u32(scalar as u32 - 96)
        }
        _ => None,
    };
    if flags & flag::CONTROL != 0 && control.is_some() {
        characters = control.map(String::from).unwrap_or_default();
    } else if flags & flag::COMMAND != 0 {
        characters = ignoring.clone();
    }
    if is_function_key(&code) {
        flags |= flag::FUNCTION;
    }
    if is_numeric_pad(&code) {
        flags |= flag::NUMERIC_PAD;
    }
    let command =
        if flags & flag::COMMAND != 0 { editing_command(&ignoring.to_lowercase()) } else { None };
    let editing_command =
        if flags & flag::SHIFT != 0 && command == Some("undo:") { Some("redo:") } else { command };
    Some(KeyStroke {
        key_code,
        modifier_flags: flags,
        characters,
        characters_ignoring_modifiers: ignoring,
        is_modifier: false,
        editing_command: editing_command.map(str::to_owned),
    })
}

/// A mouse button of a driver `input.mouse` call.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Button {
    Left,
    Right,
    Middle,
}

/// The AppKit event types for a driver `input.mouse` call, with the buttons held across calls: a
/// move while a button is down is a drag, as WebKit expects for selections and HTML5 drag starts.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct MouseEventPlan {
    held: Vec<Button>,
}

impl MouseEventPlan {
    /// A plan holding `held`.
    pub fn new(held: impl IntoIterator<Item = Button>) -> Self {
        let mut plan = Self::default();
        for button in held {
            plan.hold(button);
        }
        plan
    }

    /// The held buttons, in left, right, middle order.
    pub fn held(&self) -> Vec<Button> {
        [Button::Left, Button::Right, Button::Middle]
            .into_iter()
            .filter(|button| self.held.contains(button))
            .collect()
    }

    fn hold(&mut self, button: Button) {
        if !self.held.contains(&button) {
            self.held.push(button);
        }
    }

    /// The event type for one call; `None` for a wheel (a scroll event) or an unknown type.
    /// Updates the held buttons.
    pub fn event_type(&mut self, kind: &str, button: Button) -> Option<&'static str> {
        match kind {
            "move" => Some(if self.held.contains(&Button::Left) {
                "leftMouseDragged"
            } else if self.held.contains(&Button::Right) {
                "rightMouseDragged"
            } else if self.held.contains(&Button::Middle) {
                "otherMouseDragged"
            } else {
                "mouseMoved"
            }),
            "down" => {
                self.hold(button);
                Some(match button {
                    Button::Left => "leftMouseDown",
                    Button::Right => "rightMouseDown",
                    Button::Middle => "otherMouseDown",
                })
            }
            "up" => {
                self.held.retain(|held| *held != button);
                Some(match button {
                    Button::Left => "leftMouseUp",
                    Button::Right => "rightMouseUp",
                    Button::Middle => "otherMouseUp",
                })
            }
            _ => None,
        }
    }
}

/// A point.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// CSS pixels from the viewport's top-left to the web view's own coordinates, given the page
/// scale (`pageZoom * magnification`).
pub fn view_point(css: Point, scale: f64, view_height: f64, flipped: bool) -> Point {
    let factor = if scale > 0.0 { scale } else { 1.0 };
    let x = css.x * factor;
    let y = css.y * factor;
    Point { x, y: if flipped { y } else { view_height - y } }
}

#[derive(Deserialize)]
struct KeyRequest {
    key: String,
    #[serde(default)]
    code: String,
    #[serde(default)]
    text: Option<String>,
    #[serde(default)]
    modifiers: Vec<String>,
}

#[derive(Deserialize)]
struct MouseRequest {
    #[serde(default)]
    held: Vec<Button>,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default = "left")]
    button: Button,
}

fn left() -> Button {
    Button::Left
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ViewPointRequest {
    css: Point,
    #[serde(default)]
    scale: f64,
    #[serde(default)]
    view_height: f64,
    #[serde(default)]
    flipped: bool,
}

fn parse<T: serde::de::DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

/// Answers the `browser_rules_input_*` ops; `None` for any other op.
pub fn call(op: &str, request: Value) -> Option<Result<Value, OpError>> {
    let answer = match op {
        "browser_rules_input_key_stroke" => parse::<KeyRequest>(request).map(|request| {
            json!(resolve(&request.key, &request.code, request.text.as_deref(), &request.modifiers))
        }),
        "browser_rules_input_mouse_event" => parse::<MouseRequest>(request).map(|request| {
            let mut plan = MouseEventPlan::new(request.held);
            let event_type = plan.event_type(&request.kind, request.button);
            json!({"eventType": event_type, "held": plan.held()})
        }),
        "browser_rules_input_view_point" => parse::<ViewPointRequest>(request).map(|request| {
            json!(view_point(request.css, request.scale, request.view_height, request.flipped))
        }),
        _ => return None,
    };
    Some(answer)
}
