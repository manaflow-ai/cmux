//! Ghostty's code point widths and grapheme clustering (DEC mode 2027, on by
//! default), so the model splits and sizes glyphs as the Mac's and the
//! phone's Ghostty do. Widths and grapheme-width properties come from the
//! UCD Ghostty's pinned uucode carries (`tools/gen_unicode.py`); cluster
//! boundaries are UAX #29 extended grapheme clusters.

use unicode_segmentation::GraphemeCursor;

#[path = "unicode_tables.rs"]
mod tables;

fn in_ranges(cp: u32, ranges: &[(u32, u32)]) -> bool {
    ranges
        .binary_search_by(|&(a, b)| {
            if b < cp {
                std::cmp::Ordering::Less
            } else if a > cp {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        })
        .is_ok()
}

/// A code point's cells when printed on its own: 0, 1 or 2 (Ghostty's
/// `unicode.table.get(c).width`; every code point up to U+00FF is 1).
pub fn width(ch: char) -> usize {
    let cp = u32::from(ch);
    if cp <= 0xFF {
        return 1;
    }
    let found = tables::WIDTH.binary_search_by(|&(a, b, _)| {
        if b < cp {
            std::cmp::Ordering::Less
        } else if a > cp {
            std::cmp::Ordering::Greater
        } else {
            std::cmp::Ordering::Equal
        }
    });
    // `binary_search_by` only answers an index in the table, so `get` always finds it.
    found.ok().and_then(|i| tables::WIDTH.get(i)).map_or(1, |&(_, _, w)| usize::from(w))
}

/// How appending `ch` to a cluster ending in `prev` changes its width
/// (Ghostty's `graphemeWidthEffect`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WidthEffect {
    /// Not stored at all (a variation selector on a base it does not vary).
    Ignore,
    NoChange,
    Wide,
    Narrow,
}

pub fn width_effect(prev: char, ch: char) -> WidthEffect {
    if ch == '\u{FE0F}' || ch == '\u{FE0E}' {
        if !in_ranges(u32::from(prev), tables::EMOJI_VS_BASE) {
            return WidthEffect::Ignore;
        }
        return if ch == '\u{FE0F}' { WidthEffect::Wide } else { WidthEffect::Narrow };
    }
    if width(ch) == 0 || in_ranges(u32::from(ch), tables::ZERO_IN_GRAPHEME) {
        WidthEffect::NoChange
    } else {
        WidthEffect::Wide
    }
}

/// Emoji modifiers are the only ranges in `ZERO_IN_GRAPHEME` besides the
/// prepends.
fn is_prepend(cp: u32) -> bool {
    !(0x1F3FB..=0x1F3FF).contains(&cp) && in_ranges(cp, tables::ZERO_IN_GRAPHEME)
}

/// Letters and symbols that start a cluster after anything but a prepend
/// (grapheme break property Other, not extended pictographic, not an Indic
/// conjunct consonant): no segmentation needed for the common case.
fn starts_cluster(cp: u32) -> bool {
    matches!(cp,
        0x100..=0x2FF
        | 0x370..=0x482
        | 0x2500..=0x259F
        | 0x2800..=0x28FF
        | 0x3041..=0x3096
        | 0x30A0..=0x30FF
        | 0x3400..=0x4DBF
        | 0x4E00..=0x9FFF
        | 0xE000..=0xF8FF
        | 0xFF01..=0xFF60)
}

/// Whether `ch` starts a new cluster after the cluster `text` (Ghostty's
/// `graphemeBreak` run over the cell's code points, then `ch`).
pub fn is_break(text: &str, ch: char) -> bool {
    let mut chars = text.chars();
    if let (Some(only), None) = (chars.next(), chars.next())
        && starts_cluster(u32::from(ch))
    {
        return !is_prepend(u32::from(only));
    }
    let mut joined = String::with_capacity(text.len() + ch.len_utf8());
    joined.push_str(text);
    joined.push(ch);
    let mut cursor = GraphemeCursor::new(text.len(), joined.len(), true);
    cursor.is_boundary(&joined, 0).unwrap_or(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn widths_are_ghosttys() {
        assert_eq!(width('a'), 1);
        assert_eq!(width('\u{301}'), 0);
        assert_eq!(width('\u{200D}'), 0);
        assert_eq!(width('\u{FE0F}'), 0);
        assert_eq!(width('漢'), 2);
        assert_eq!(width('🇯'), 2);
        assert_eq!(width('👍'), 2);
        assert_eq!(width('🏽'), 2);
        assert_eq!(width('\u{2E3B}'), 2);
        assert_eq!(width('\u{20E3}'), 0);
        assert_eq!(width('\u{1160}'), 0);
        assert_eq!(width('\u{93F}'), 1);
    }

    #[test]
    fn clusters_join_and_break() {
        assert!(!is_break("e", '\u{301}'));
        assert!(!is_break("👨", '\u{200D}'));
        assert!(!is_break("👨\u{200D}", '👩'));
        assert!(is_break("👨", '👩'));
        assert!(!is_break("🇯", '🇵'));
        assert!(is_break("🇯🇵", '🇺'));
        assert!(is_break("a", '漢'));
        assert!(!is_break("👍", '🏽'));
        assert!(!is_break("स\u{94D}", 'त'));
        assert_eq!(width_effect('❤', '\u{FE0F}'), WidthEffect::Wide);
        assert_eq!(width_effect('a', '\u{FE0F}'), WidthEffect::Ignore);
        assert_eq!(width_effect('☺', '\u{FE0E}'), WidthEffect::Narrow);
        assert_eq!(width_effect('e', '\u{301}'), WidthEffect::NoChange);
        assert_eq!(width_effect('क', '\u{93F}'), WidthEffect::Wide);
        assert_eq!(width_effect('a', '🏽'), WidthEffect::NoChange);
    }
}
