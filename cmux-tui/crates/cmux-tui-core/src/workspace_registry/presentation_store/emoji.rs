//! One emoji grapheme for presentation icons (`validate_presentation_icon`).

/// Longest accepted emoji icon, in bytes.
const MAX_EMOJI_ICON_BYTES: usize = 32;

fn is_emoji_base(ch: char) -> bool {
    matches!(u32::from(ch),
        0x00A9 | 0x00AE | 0x203C | 0x2049 | 0x2122 | 0x2139
        | 0x2194..=0x21FF | 0x231A..=0x23FF | 0x24C2 | 0x25AA..=0x25FE
        | 0x2600..=0x27BF | 0x2934 | 0x2935 | 0x2B05..=0x2BFF | 0x3030 | 0x303D
        | 0x3297 | 0x3299 | 0x1F000..=0x1FAFF)
}

fn is_regional_indicator(ch: char) -> bool {
    matches!(u32::from(ch), 0x1F1E6..=0x1F1FF)
}

/// One emoji grapheme without a Unicode segmentation table: an emoji base
/// optionally followed by variation selectors, skin tone modifiers, a keycap
/// mark, tag characters, or ZWJ-joined further bases; a flag (two regional
/// indicators); or a keycap sequence (`#`, `*`, or a digit, U+FE0F, U+20E3).
pub(super) fn is_single_emoji(value: &str) -> bool {
    if value.is_empty() || value.len() > MAX_EMOJI_ICON_BYTES {
        return false;
    }
    let chars = value.chars().collect::<Vec<_>>();
    if chars.iter().any(|ch| ch.is_control() || ch.is_whitespace()) {
        return false;
    }
    if chars.len() == 2 && chars.iter().all(|ch| is_regional_indicator(*ch)) {
        return true;
    }
    if chars.len() >= 2
        && (chars[0].is_ascii_digit() || matches!(chars[0], '#' | '*'))
        && chars[1..].iter().all(|ch| matches!(u32::from(*ch), 0xFE0F | 0x20E3))
        && chars.last() == Some(&'\u{20E3}')
    {
        return true;
    }
    if !is_emoji_base(chars[0]) || is_regional_indicator(chars[0]) {
        return false;
    }
    let mut expect_base = false;
    for ch in &chars[1..] {
        let code = u32::from(*ch);
        if expect_base {
            if !is_emoji_base(*ch) || is_regional_indicator(*ch) {
                return false;
            }
            expect_base = false;
            continue;
        }
        match code {
            0x200D => expect_base = true,
            0xFE0E | 0xFE0F | 0x20E3 | 0x1F3FB..=0x1F3FF | 0xE0020..=0xE007F => {}
            _ => return false,
        }
    }
    !expect_base
}
