//! A theme's swatch strip for the theme pickers (`Themes/ThemeSwatch.swift`): background, ANSI
//! 1...6, foreground, read from a Ghostty theme file. Includes `ThemeRGB(cssHex:)`.

use crate::tokens::color::Rgb;
use std::collections::HashMap;

/// The ANSI entries a strip shows, in order (`ThemeSwatch.paletteIndices`).
pub const PALETTE_INDICES: [i64; 6] = [1, 2, 3, 4, 5, 6];

/// Swift's `.whitespaces` set: tab and Unicode general category Zs.
fn is_swift_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// Swift's `Character.isNewline`.
fn is_swift_newline(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

fn trim(s: &str) -> &str {
    s.trim_matches(is_swift_whitespace)
}

/// Swift's `split(separator:maxSplits: 1)` with empty pieces omitted (they do not count as a split).
fn split_once_swift(s: &str, sep: char) -> Vec<&str> {
    let mut result = Vec::new();
    let mut start = 0;
    for (i, c) in s.char_indices() {
        if i < start || c != sep {
            continue;
        }
        let appended = i > start;
        if appended {
            result.push(s.get(start..i).unwrap_or_default());
        }
        start = i + c.len_utf8();
        if appended && result.len() == 1 {
            break;
        }
    }
    if start < s.len() {
        result.push(s.get(start..).unwrap_or_default());
    }
    result
}

/// A colour from `#RGB`, `#RRGGBB` or `#RRGGBBAA` (`#` optional, surrounding whitespace trimmed);
/// `None` for anything else (Swift `ThemeRGB(cssHex:)`).
pub fn css_hex(text: &str) -> Option<Rgb> {
    let t = trim(text);
    let digits = t.strip_prefix('#').unwrap_or(t);
    let count = digits.chars().count();
    if ![3, 6, 8].contains(&count) || !digits.chars().all(|c| c.is_ascii_hexdigit()) {
        return None;
    }
    let mut value = u64::from_str_radix(digits, 16).ok()?;
    if count == 3 {
        let (r, g, b) = ((value >> 8) & 0xF, (value >> 4) & 0xF, value & 0xF);
        value = ((r * 17) << 16) | ((g * 17) << 8) | (b * 17);
    }
    let alpha = if count == 8 { (value & 0xFF) as f64 / 255.0 } else { 1.0 };
    if count == 8 {
        value >>= 8;
    }
    Some(Rgb::hex(value as u32).with_alpha(alpha))
}

/// The strip in a Ghostty theme file's text; empty when it sets no colour (`ThemeSwatch.strip`).
pub fn strip(theme_file: &str) -> Vec<Rgb> {
    let mut background = None;
    let mut foreground = None;
    let mut palette: HashMap<i64, Rgb> = HashMap::new();
    for line in theme_file.split(is_swift_newline).filter(|l| !l.is_empty()) {
        let parts = split_once_swift(line, '=');
        if parts.len() != 2 {
            continue;
        }
        let value = trim(parts.get(1).copied().unwrap_or_default());
        match trim(parts.first().copied().unwrap_or_default()) {
            "background" => background = css_hex(value),
            "foreground" => foreground = css_hex(value),
            "palette" => {
                let entry = split_once_swift(value, '=');
                if entry.len() != 2 {
                    continue;
                }
                let (Ok(index), Some(color)) = (
                    trim(entry.first().copied().unwrap_or_default()).parse::<i64>(),
                    css_hex(entry.get(1).copied().unwrap_or_default()),
                ) else {
                    continue;
                };
                palette.insert(index, color);
            }
            _ => continue,
        }
    }
    background
        .into_iter()
        .chain(PALETTE_INDICES.iter().filter_map(|i| palette.get(i).copied()))
        .chain(foreground)
        .collect()
}
