//! Foundation character classes the Swift validators use, ported so the
//! Rust checks agree with them.

/// Foundation `CharacterSet.whitespaces`: tab and Unicode space separators (Zs).
pub(crate) fn is_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

/// `text.trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_whitespaces(text: &str) -> &str {
    text.trim_matches(is_whitespace)
}

/// Foundation `CharacterSet.controlCharacters`: categories Cc and Cf.
pub(crate) fn is_control(c: char) -> bool {
    if c.is_control() {
        return true;
    }
    matches!(
        c as u32,
        0xAD | 0x600..=0x605
            | 0x61C
            | 0x6DD
            | 0x70F
            | 0x890..=0x891
            | 0x8E2
            | 0x180E
            | 0x200B..=0x200F
            | 0x202A..=0x202E
            | 0x2060..=0x2064
            | 0x2066..=0x206F
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0x110BD
            | 0x110CD
            | 0x13430..=0x1343F
            | 0x1BCA0..=0x1BCA3
            | 0x1D173..=0x1D17A
            | 0xE0001
            | 0xE0020..=0xE007F
    )
}

/// Swift `Character.isHexDigit`: ASCII and fullwidth hex digits.
pub(crate) fn is_hex_digit(c: char) -> bool {
    c.is_ascii_hexdigit()
        || matches!(c, '\u{FF10}'..='\u{FF19}' | '\u{FF21}'..='\u{FF26}' | '\u{FF41}'..='\u{FF46}')
}

/// No character that could start another Ghostty config line.
fn is_config_safe(text: &str) -> bool {
    text.chars().all(|c| !is_control(c) && !matches!(c, '#' | '=' | '"'))
}

/// A parsed Ghostty theme spec (Swift `ThemeSpec`): one theme name or a
/// light/dark pair.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThemeSpec {
    pub light: String,
    pub dark: String,
}

/// Longest accepted theme spec.
pub const THEME_SPEC_MAX_LENGTH: usize = 200;
/// Longest accepted font family name.
pub const FONT_FAMILY_MAX_LENGTH: usize = 120;

impl ThemeSpec {
    /// `None` for empty text, text over the limit, a part with an unknown
    /// prefix, or characters that could start another config line.
    pub fn parse(raw: &str) -> Option<ThemeSpec> {
        let trimmed = trim_whitespaces(raw);
        if trimmed.is_empty()
            || crate::value::char_count(trimmed) > THEME_SPEC_MAX_LENGTH
            || !is_config_safe(trimmed)
        {
            return None;
        }
        let (mut light, mut dark, mut plain) = (None, None, None);
        for part in trimmed.split(',') {
            let text = trim_whitespaces(part);
            if text.is_empty() {
                return None;
            }
            if let Some(name) = prefixed(text, "light:") {
                light = Some(name);
            } else if let Some(name) = prefixed(text, "dark:") {
                dark = Some(name);
            } else if plain.is_none() && !text.contains(':') {
                plain = Some(text.to_string());
            } else {
                return None;
            }
        }
        let resolved_light = light.clone().or_else(|| dark.clone()).or_else(|| plain.clone())?;
        let resolved_dark = dark.or(light).or(plain)?;
        Some(ThemeSpec { light: resolved_light, dark: resolved_dark })
    }
}

fn prefixed(text: &str, prefix: &str) -> Option<String> {
    let head = text.get(..prefix.len())?;
    if !head.eq_ignore_ascii_case(prefix) {
        return None;
    }
    let name = trim_whitespaces(&text[prefix.len()..]);
    (!name.is_empty()).then(|| name.to_string())
}

/// Swift `TerminalFontSetting.isValidFamily`.
pub fn is_valid_font_family(text: &str) -> bool {
    let family = trim_whitespaces(text);
    !family.is_empty()
        && crate::value::char_count(family) <= FONT_FAMILY_MAX_LENGTH
        && is_config_safe(family)
}

/// Swift `QuietHours.minutes`: `"HH:MM"` to minutes after midnight.
pub fn quiet_hours_minutes(text: &str) -> Option<i64> {
    let parts: Vec<&str> = text.split(':').filter(|part| !part.is_empty()).collect();
    let [hour, minute] = parts.as_slice() else {
        return None;
    };
    let hour: i64 = swift_int(hour)?;
    let minute: i64 = swift_int(minute)?;
    ((0..=23).contains(&hour) && (0..=59).contains(&minute)).then_some(hour * 60 + minute)
}

/// Swift `Int(String)`: optional sign, ASCII digits only.
fn swift_int(text: &str) -> Option<i64> {
    let digits = text.strip_prefix(['+', '-']).unwrap_or(text);
    if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    text.parse().ok()
}
