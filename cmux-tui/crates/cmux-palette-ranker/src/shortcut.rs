//! Shortcut queries: "cmd i", "cmd+shift+p", "⌘I", "⌥⇧K" and "ctrl-tab" find the row bound to
//! that chord.
//!
//! A query is a shortcut query only when it names at least one modifier and every other word is
//! one key. Any other query (plain words, a lone "cmd") parses to nothing and ranks as before.
//! Rows carry the keycaps the host shows (`["⇧", "⌘", "P"]`, `["⌃", "B", "C"]`, `["⌘", "1…9"]`),
//! taken from the live keybindings, so a user override is what a query finds.

use crate::text::is_js_space;

const CONTROL: u8 = 1;
const OPTION: u8 = 2;
const SHIFT: u8 = 4;
const COMMAND: u8 = 8;

/// One key of a stroke, lowercased and named (`p`, `tab`, `return`, `f5`).
#[derive(Debug, Clone, PartialEq, Eq)]
enum Key {
    Named(String),
    /// A numbered family (`⌘1…9`): any digit 1 to 9.
    Digits,
}

/// One key press with its modifiers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Stroke {
    modifiers: u8,
    key: Key,
}

fn modifier(token: &str) -> Option<u8> {
    Some(match token {
        "⌃" | "ctrl" | "control" | "ctl" => CONTROL,
        "⌥" | "opt" | "option" | "alt" => OPTION,
        "⇧" | "shift" => SHIFT,
        "⌘" | "cmd" | "command" => COMMAND,
        _ => return None,
    })
}

/// The glyphs that read as one key on their own.
fn glyph_key(c: char) -> Option<&'static str> {
    Some(match c {
        '↩' | '⏎' | '⌤' => "return",
        '⇥' => "tab",
        '⎋' => "escape",
        '⌫' => "delete",
        '⌦' => "forwarddelete",
        '↑' => "up",
        '↓' => "down",
        '←' => "left",
        '→' => "right",
        '␣' => "space",
        _ => return None,
    })
}

/// A key word a person types (lowercase): a single scalar, a glyph or a key name.
fn query_key(token: &str) -> Option<Key> {
    let mut chars = token.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        let name = glyph_key(c).map_or_else(|| c.to_string(), str::to_owned);
        return Some(Key::Named(name));
    }
    let name = match token {
        "return" | "enter" | "ret" => "return",
        "tab" => "tab",
        "esc" | "escape" => "escape",
        "delete" | "del" | "backspace" | "bksp" => "delete",
        "forwarddelete" => "forwarddelete",
        "home" | "end" | "pageup" | "pagedown" => token,
        "space" | "spacebar" => "space",
        "up" | "down" | "left" | "right" => token,
        "comma" => ",",
        "period" | "dot" => ".",
        "slash" => "/",
        "backslash" => "\\",
        "minus" | "dash" | "hyphen" => "-",
        "equal" | "equals" => "=",
        "semicolon" => ";",
        "quote" | "apostrophe" => "'",
        "backtick" | "grave" => "`",
        _ => {
            let digits = token.strip_prefix('f')?;
            let number: u8 = digits.parse().ok()?;
            if !(1..=24).contains(&number) || digits.starts_with('0') {
                return None;
            }
            return Some(Key::Named(token.to_owned()));
        }
    };
    Some(Key::Named(name.to_owned()))
}

/// One keycap the host shows as a key (`P`, `⇥`, `Space`, `1…9`, an AppKit function-key scalar).
fn keycap_key(cap: &str) -> Key {
    if cap == "1…9" {
        return Key::Digits;
    }
    let lower = cap.to_lowercase();
    let mut chars = cap.chars();
    if let (Some(c), None) = (chars.next(), chars.next()) {
        // AppKit's NSF1FunctionKey (U+F704) through NSF24FunctionKey.
        if ('\u{f704}'..='\u{f71b}').contains(&c) {
            return Key::Named(format!("f{}", u32::from(c) - 0xf704 + 1));
        }
        // AppKit's other function-key scalars that keybindings use.
        let named = match c {
            '\u{f728}' => Some("forwarddelete"),
            '\u{f729}' => Some("home"),
            '\u{f72b}' => Some("end"),
            '\u{f72c}' => Some("pageup"),
            '\u{f72d}' => Some("pagedown"),
            _ => None,
        };
        if let Some(name) = named {
            return Key::Named(name.to_owned());
        }
    }
    query_key(&lower).unwrap_or(Key::Named(lower))
}

/// The words of a query: modifier glyphs stand alone; white space separates; `+` and `-` separate
/// after a word and are a word of their own after a separator (`cmd+-`, `⌘-`, `Cmd + P`).
fn tokens(query: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut current = String::new();
    for c in query.chars() {
        if is_js_space(c) {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
        } else if matches!(c, '⌃' | '⌥' | '⇧' | '⌘') {
            if !current.is_empty() {
                tokens.push(std::mem::take(&mut current));
            }
            tokens.push(c.to_string());
        } else if (c == '+' || c == '-') && !current.is_empty() {
            tokens.push(std::mem::take(&mut current));
        } else if c == '+' || c == '-' {
            // After a separator, `+` and `-` are a key word of their own.
            tokens.push(c.to_string());
        } else {
            current.extend(c.to_lowercase());
        }
    }
    if !current.is_empty() {
        tokens.push(current);
    }
    tokens
}

/// A US shifted symbol as shift plus its base key (`?` is ⇧/), so "cmd ?" names ⇧⌘/ and a
/// binding stored as `}` names ⇧].
fn stroke(mut modifiers: u8, key: Key) -> Stroke {
    const SHIFTED: &[(char, char)] = &[
        ('~', '`'),
        ('!', '1'),
        ('@', '2'),
        ('#', '3'),
        ('$', '4'),
        ('%', '5'),
        ('^', '6'),
        ('&', '7'),
        ('*', '8'),
        ('(', '9'),
        (')', '0'),
        ('_', '-'),
        ('+', '='),
        ('{', '['),
        ('}', ']'),
        ('|', '\\'),
        (':', ';'),
        ('"', '\''),
        ('<', ','),
        ('>', '.'),
        ('?', '/'),
    ];
    if let Key::Named(name) = &key {
        let mut chars = name.chars();
        if let (Some(c), None) = (chars.next(), chars.next())
            && let Some(&(_, base)) = SHIFTED.iter().find(|(shifted, _)| *shifted == c)
        {
            modifiers |= SHIFT;
            return Stroke { modifiers, key: Key::Named(base.to_string()) };
        }
    }
    Stroke { modifiers, key }
}

/// The strokes a query names, or nothing when it is not a shortcut query.
pub(crate) fn parse_query(query: &str) -> Option<Vec<Stroke>> {
    let mut strokes = Vec::new();
    let mut modifiers = 0;
    let mut named_modifier = false;
    let tokens = tokens(query);
    for (at, token) in tokens.iter().enumerate() {
        if let Some(bit) = modifier(token) {
            modifiers |= bit;
            named_modifier = true;
            continue;
        }
        // "Cmd + P": a lone + or - between a modifier and the next word separates them.
        if (token == "+" || token == "-")
            && modifiers != 0
            && at + 1 < tokens.len()
            && at
                .checked_sub(1)
                .and_then(|before| tokens.get(before))
                .is_some_and(|last| modifier(last).is_some())
        {
            continue;
        }
        strokes.push(stroke(modifiers, query_key(token)?));
        modifiers = 0;
    }
    (named_modifier && modifiers == 0 && !strokes.is_empty()).then_some(strokes)
}

/// The strokes of a row's keycaps, or nothing when it has none.
pub(crate) fn parse_keycaps(keycaps: &[String]) -> Option<Vec<Stroke>> {
    let mut strokes = Vec::new();
    let mut modifiers = 0;
    for cap in keycaps {
        if let Some(bit) = modifier(cap.as_str()) {
            modifiers |= bit;
            continue;
        }
        strokes.push(stroke(modifiers, keycap_key(cap)));
        modifiers = 0;
    }
    (modifiers == 0 && !strokes.is_empty()).then_some(strokes)
}

/// The query names exactly the row's shortcut (any digit 1 to 9 for a numbered family).
pub(crate) fn matches(query: &[Stroke], row: &[Stroke]) -> bool {
    query.len() == row.len()
        && query.iter().zip(row).all(|(query, row)| {
            query.modifiers == row.modifiers
                && match (&query.key, &row.key) {
                    (Key::Named(typed), Key::Digits) => {
                        matches!(typed.as_bytes(), [b'1'..=b'9'])
                    }
                    (typed, shown) => typed == shown,
                }
        })
}
