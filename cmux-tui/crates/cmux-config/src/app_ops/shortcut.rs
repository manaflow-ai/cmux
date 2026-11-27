//! `shortcut.*`: the app's read and write of a `shortcuts.bindings.<action>`
//! value (Swift `ShortcutBindingFormat`, the cmux.json shortcut formats the
//! old app accepts plus next's alternates). Swift keeps the enum it hands to
//! AppKit; the parse, the key names and the canonical form are here.
//!
//! Wire shapes:
//! - a stroke: `{key, command, shift, option, control}`; `key` uses
//!   NSMenuItem key-equivalent semantics (a lowercase character, or an AppKit
//!   function-key character such as U+F702 for the left arrow).
//! - a binding: `{"unbound": true}`, `{"stroke": S}`, `{"chord": [S, S]}` or
//!   `{"any": [B, ...]}` (each item a stroke or a chord, at least two).
//!
//! Ops:
//! - `shortcut.parse` `{value}` answers `{binding}` (null when `value` is not
//!   a binding); `shortcut.parse_many` `{values}` answers `{bindings}`, one
//!   each, in order.
//! - `shortcut.config_value` `{binding}` answers `{value}`: the cmux.json
//!   value `shortcut.parse` reads back.
//! - `shortcut.parse_stroke` `{text}` answers `{stroke}` (or null).
//! - `shortcut.config_string` `{stroke}` answers `{text}` (`cmd+shift+p`).
//! - `shortcut.key_equivalent` `{token}` answers `{key}` (or null);
//!   `shortcut.config_token` `{key}` answers `{token}`.

use serde_json::{Map, Value, json};
use unicode_segmentation::UnicodeSegmentation;

use super::{OpError, string};

// AppKit's function-key characters (NSEvent.h).
const UP: u32 = 0xF700;
const DOWN: u32 = 0xF701;
const LEFT: u32 = 0xF702;
const RIGHT: u32 = 0xF703;
const F1: u32 = 0xF704;
const HOME: u32 = 0xF729;
const END: u32 = 0xF72B;
const PAGE_UP: u32 = 0xF72C;
const PAGE_DOWN: u32 = 0xF72D;

/// The tokens that unbind (after trimming, any case).
const UNBOUND_TOKENS: [&str; 5] = ["", "none", "clear", "unbound", "disabled"];

/// One keystroke.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stroke {
    pub key: String,
    pub command: bool,
    pub shift: bool,
    pub option: bool,
    pub control: bool,
}

/// A parsed binding value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Binding {
    Unbound,
    Stroke(Stroke),
    Chord(Stroke, Stroke),
    Alternates(Vec<Binding>),
}

impl Binding {
    fn is_key(&self) -> bool {
        matches!(self, Binding::Stroke(_) | Binding::Chord(..))
    }
}

/// Runs a `shortcut.*` op; `None` when `op` is not one.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    Some(match op {
        "shortcut.parse" => {
            let value = request.get("value").unwrap_or(&Value::Null);
            Ok(json!({ "binding": parse(value).map(|b| binding_json(&b)) }))
        }
        "shortcut.parse_many" => match request.get("values").and_then(Value::as_array) {
            Some(values) => {
                let bindings: Vec<Value> = values
                    .iter()
                    .map(|value| parse(value).map_or(Value::Null, |b| binding_json(&b)))
                    .collect();
                Ok(json!({ "bindings": bindings }))
            }
            None => Err(OpError::Invalid("expected an array `values`".to_owned())),
        },
        "shortcut.config_value" => request
            .get("binding")
            .and_then(binding_from_json)
            .map(|b| json!({ "value": config_value(&b) }))
            .ok_or_else(|| OpError::Invalid("expected a binding `binding`".to_owned())),
        "shortcut.parse_stroke" => string(request, "text")
            .map(|text| json!({ "stroke": parse_stroke(text).map(|s| stroke_json(&s)) })),
        "shortcut.config_string" => request
            .get("stroke")
            .and_then(stroke_from_json)
            .map(|s| json!({ "text": config_string(&s) }))
            .ok_or_else(|| OpError::Invalid("expected a stroke `stroke`".to_owned())),
        "shortcut.key_equivalent" => {
            string(request, "token").map(|token| json!({ "key": key_equivalent(token) }))
        }
        "shortcut.config_token" => {
            string(request, "key").map(|key| json!({ "token": config_token(key) }))
        }
        _ => return None,
    })
}

/// Parses one binding value; `None` when it is not a valid binding.
pub fn parse(value: &Value) -> Option<Binding> {
    match value {
        Value::Null => Some(Binding::Unbound),
        Value::String(text) => {
            if UNBOUND_TOKENS.contains(&trim_spaces(text).to_lowercase().as_str()) {
                return Some(Binding::Unbound);
            }
            parse_stroke(text).map(Binding::Stroke)
        }
        Value::Array(items) => {
            let strokes: Vec<Stroke> =
                items.iter().filter_map(|item| item.as_str().and_then(parse_stroke)).collect();
            if strokes.len() != items.len() {
                return None;
            }
            let mut strokes = strokes.into_iter();
            match (strokes.next(), strokes.next(), strokes.next()) {
                (None, _, _) => Some(Binding::Unbound),
                (Some(first), None, _) => Some(Binding::Stroke(first)),
                (Some(first), Some(second), None) => Some(Binding::Chord(first, second)),
                _ => None,
            }
        }
        Value::Object(members) if members.contains_key("any") => parse_alternates(members),
        Value::Object(members) => {
            let first = members.get("first").and_then(parse_stroke_object)?;
            if first.key.is_empty() {
                return Some(Binding::Unbound);
            }
            match members.get("second") {
                Some(second) if !second.is_null() => {
                    Some(Binding::Chord(first, parse_stroke_object(second)?))
                }
                _ => Some(Binding::Stroke(first)),
            }
        }
        _ => None,
    }
}

/// `{"any": [...]}`: every item a key or a chord (not an unbind token); a
/// repeated item counts once. No items unbinds; one is that binding.
fn parse_alternates(members: &Map<String, Value>) -> Option<Binding> {
    if members.len() != 1 {
        return None;
    }
    let items = members.get("any")?.as_array()?;
    let mut bindings: Vec<Binding> = Vec::new();
    for item in items {
        let binding = parse(item).filter(Binding::is_key)?;
        if !bindings.contains(&binding) {
            bindings.push(binding);
        }
    }
    match bindings.len() {
        0 => Some(Binding::Unbound),
        1 => bindings.pop(),
        _ => Some(Binding::Alternates(bindings)),
    }
}

/// The cmux.json value for `binding`, in the forms [`parse`] reads.
pub fn config_value(binding: &Binding) -> Value {
    match binding {
        Binding::Unbound => Value::Null,
        Binding::Stroke(stroke) => Value::String(config_string(stroke)),
        Binding::Chord(first, second) => json!([config_string(first), config_string(second)]),
        Binding::Alternates(bindings) => {
            json!({ "any": bindings.iter().map(config_value).collect::<Vec<_>>() })
        }
    }
}

/// Parses `cmd+shift+p` (or `⌘⇧`-style modifier tokens) joined by `+`.
pub fn parse_stroke(text: &str) -> Option<Stroke> {
    let mut parts: Vec<&str> = text.split('+').collect();
    let mut key_token = *parts.last()?;
    // `cmd++` means the plus key.
    if key_token.is_empty() && parts.len() >= 2 && parts[parts.len() - 2].is_empty() {
        parts.pop();
        key_token = "+";
    }
    let mut stroke =
        Stroke { key: String::new(), command: false, shift: false, option: false, control: false };
    for modifier in &parts[..parts.len() - 1] {
        match trim_spaces(modifier).to_lowercase().as_str() {
            "cmd" | "command" | "⌘" => stroke.command = true,
            "shift" | "⇧" => stroke.shift = true,
            "opt" | "option" | "alt" | "⌥" => stroke.option = true,
            "ctrl" | "control" | "ctl" | "⌃" => stroke.control = true,
            "" => {}
            _ => return None,
        }
    }
    stroke.key = key_equivalent(key_token)?;
    Some(stroke)
}

/// The recorder's object form: `{key, command, shift, option, control}`.
fn parse_stroke_object(value: &Value) -> Option<Stroke> {
    let members = value.as_object()?;
    let raw_key = members.get("key")?.as_str()?;
    let key = if raw_key.is_empty() {
        String::new()
    } else {
        key_equivalent(raw_key).unwrap_or_else(|| raw_key.to_lowercase())
    };
    let flag = |name: &str| members.get(name).and_then(Value::as_bool).unwrap_or(false);
    Some(Stroke {
        key,
        command: flag("command"),
        shift: flag("shift"),
        option: flag("option"),
        control: flag("control"),
    })
}

/// Maps a config key token to a key-equivalent character.
pub fn key_equivalent(raw_token: &str) -> Option<String> {
    let trimmed = trim_spaces(raw_token);
    if trimmed.is_empty() {
        return (raw_token == " ").then(|| " ".to_owned());
    }
    let lowered = trimmed.to_lowercase();
    let named = match lowered.as_str() {
        "left" | "arrowleft" | "leftarrow" | "←" => function_key(LEFT),
        "right" | "arrowright" | "rightarrow" | "→" => function_key(RIGHT),
        "up" | "arrowup" | "uparrow" | "↑" => function_key(UP),
        "down" | "arrowdown" | "downarrow" | "↓" => function_key(DOWN),
        "tab" | "⇥" => "\t".to_owned(),
        "return" | "enter" | "↩" => "\r".to_owned(),
        "escape" | "esc" | "⎋" => "\u{1B}".to_owned(),
        "delete" | "backspace" | "⌫" => "\u{8}".to_owned(),
        "space" | "spacebar" | "<space>" => " ".to_owned(),
        "comma" => ",".to_owned(),
        "period" | "dot" => ".".to_owned(),
        "slash" => "/".to_owned(),
        "backslash" => "\\".to_owned(),
        "semicolon" => ";".to_owned(),
        "quote" | "apostrophe" => "'".to_owned(),
        "backtick" | "grave" => "`".to_owned(),
        "minus" | "hyphen" => "-".to_owned(),
        "plus" | "equals" => "=".to_owned(),
        "leftbracket" | "openbracket" => "[".to_owned(),
        "rightbracket" | "closebracket" => "]".to_owned(),
        "home" => function_key(HOME),
        "end" => function_key(END),
        "pageup" => function_key(PAGE_UP),
        "pagedown" => function_key(PAGE_DOWN),
        _ => {
            if let Some(number) = lowered.strip_prefix('f').and_then(swift_int)
                && (1..=20).contains(&number)
            {
                return Some(function_key(F1 + number - 1));
            }
            // One character as a person sees it (Swift's `count`: grapheme clusters).
            if lowered.graphemes(true).count() != 1 {
                return None;
            }
            return Some(lowered);
        }
    };
    Some(named)
}

/// The config string for a stroke (`cmd+shift+p`), as the Settings writer
/// stores it.
pub fn config_string(stroke: &Stroke) -> String {
    let mut parts: Vec<String> = Vec::new();
    for (on, name) in [
        (stroke.command, "cmd"),
        (stroke.shift, "shift"),
        (stroke.option, "opt"),
        (stroke.control, "ctrl"),
    ] {
        if on {
            parts.push(name.to_owned());
        }
    }
    parts.push(config_token(&stroke.key));
    parts.join("+")
}

/// The config token for a key-equivalent character.
pub fn config_token(key: &str) -> String {
    let named = match key {
        "\t" => Some("tab"),
        "\r" => Some("return"),
        "\u{1B}" => Some("escape"),
        "\u{8}" | "\u{7F}" => Some("delete"),
        " " => Some("space"),
        "+" => Some("plus"),
        _ => None,
    };
    if let Some(name) = named {
        return name.to_owned();
    }
    let mut chars = key.chars();
    if let (Some(scalar), None) = (chars.next(), chars.next()) {
        let code = u32::from(scalar);
        let name = match code {
            LEFT => Some("left"),
            RIGHT => Some("right"),
            UP => Some("up"),
            DOWN => Some("down"),
            HOME => Some("home"),
            END => Some("end"),
            PAGE_UP => Some("pageup"),
            PAGE_DOWN => Some("pagedown"),
            _ => None,
        };
        if let Some(name) = name {
            return name.to_owned();
        }
        if (F1..=F1 + 19).contains(&code) {
            return format!("f{}", code - F1 + 1);
        }
    }
    key.to_owned()
}

/// A stroke as its wire object.
pub fn stroke_json(stroke: &Stroke) -> Value {
    json!({
        "key": stroke.key,
        "command": stroke.command,
        "shift": stroke.shift,
        "option": stroke.option,
        "control": stroke.control,
    })
}

/// A binding as its wire object.
pub fn binding_json(binding: &Binding) -> Value {
    match binding {
        Binding::Unbound => json!({ "unbound": true }),
        Binding::Stroke(stroke) => json!({ "stroke": stroke_json(stroke) }),
        Binding::Chord(first, second) => {
            json!({ "chord": [stroke_json(first), stroke_json(second)] })
        }
        Binding::Alternates(bindings) => {
            json!({ "any": bindings.iter().map(binding_json).collect::<Vec<_>>() })
        }
    }
}

fn stroke_from_json(value: &Value) -> Option<Stroke> {
    let flag = |name: &str| value.get(name).and_then(Value::as_bool).unwrap_or(false);
    Some(Stroke {
        key: value.get("key")?.as_str()?.to_owned(),
        command: flag("command"),
        shift: flag("shift"),
        option: flag("option"),
        control: flag("control"),
    })
}

fn binding_from_json(value: &Value) -> Option<Binding> {
    let members = value.as_object()?;
    if members.get("unbound").and_then(Value::as_bool) == Some(true) {
        return Some(Binding::Unbound);
    }
    if let Some(stroke) = members.get("stroke") {
        return stroke_from_json(stroke).map(Binding::Stroke);
    }
    if let Some(chord) = members.get("chord").and_then(Value::as_array) {
        let [first, second] = chord.as_slice() else { return None };
        return Some(Binding::Chord(stroke_from_json(first)?, stroke_from_json(second)?));
    }
    let any = members.get("any")?.as_array()?;
    any.iter().map(binding_from_json).collect::<Option<Vec<_>>>().map(Binding::Alternates)
}

/// The character for an AppKit function-key code.
fn function_key(code: u32) -> String {
    // Function-key codes are valid private-use scalars; NUL stands in otherwise.
    char::from_u32(code).unwrap_or('\0').to_string()
}

/// Swift's `trimmingCharacters(in: .whitespaces)`: tab and the Unicode space
/// separators, not line breaks.
fn trim_spaces(text: &str) -> &str {
    text.trim_matches(|c: char| c == '\t' || (c.is_whitespace() && !is_line_break(c)))
}

fn is_line_break(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

/// Swift's `Int(String)`: an optional sign and ASCII digits only.
fn swift_int(text: &str) -> Option<u32> {
    let digits = text.strip_prefix('+').unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

#[cfg(test)]
#[path = "shortcut_tests.rs"]
mod tests;
