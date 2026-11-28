//! Character classes and the string comparisons the Swift parser made through Foundation and
//! `Character`: Unicode scalars are `char`s, a Swift `Character` is a grapheme cluster, and
//! Swift `String` equality is canonical equivalence.

use unicode_general_category::{GeneralCategory as G, get_general_category};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// The scalar at `i`, None past either end.
pub(crate) fn at(s: &[char], i: usize) -> Option<char> {
    s.get(i).copied()
}

/// A link destination's edge (removed) or embedded (refused) character: control, format,
/// separator or whitespace.
pub(crate) fn is_edge(c: char) -> bool {
    matches!(
        get_general_category(c),
        G::Control | G::Format | G::SpaceSeparator | G::LineSeparator | G::ParagraphSeparator
    ) || c.is_whitespace()
}

/// An RFC 3986 scheme before the first ":": an ASCII letter, then letters, digits, "+", "-", ".".
pub(crate) fn has_scheme(s: &str) -> bool {
    let Some((head, _)) = s.split_once(':') else { return false };
    let mut it = head.chars();
    let Some(first) = it.next() else { return false };
    first.is_ascii_alphabetic()
        && it.all(|c| c.is_ascii_alphanumeric() || c == '+' || c == '-' || c == '.')
}

/// Foundation's `CharacterSet.whitespaces`: space separators and tab.
pub(crate) fn is_space(c: char) -> bool {
    c == '\t' || get_general_category(c) == G::SpaceSeparator
}

/// Foundation's `CharacterSet.whitespacesAndNewlines`.
pub(crate) fn is_space_or_newline(c: char) -> bool {
    matches!(c, '\t'..='\r' | '\u{85}')
        || matches!(
            get_general_category(c),
            G::SpaceSeparator | G::LineSeparator | G::ParagraphSeparator
        )
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_spaces(s: &str) -> &str {
    s.trim_matches(is_space)
}

pub(crate) fn is_ascii_punct(c: char) -> bool {
    matches!(c as u32, 33..=47 | 58..=64 | 91..=96 | 123..=126)
}

pub(crate) fn is_ws(c: char) -> bool {
    c.is_whitespace()
}

/// A letter or an ASCII digit; None (outside the text) is neither.
pub(crate) fn is_alnum(c: Option<char>) -> bool {
    c.is_some_and(|c| c.is_alphabetic() || c.is_ascii_digit())
}

pub(crate) fn is_punct(c: char) -> bool {
    is_ascii_punct(c)
        || matches!(
            get_general_category(c),
            G::ConnectorPunctuation
                | G::DashPunctuation
                | G::OpenPunctuation
                | G::ClosePunctuation
                | G::InitialPunctuation
                | G::FinalPunctuation
                | G::OtherPunctuation
                | G::MathSymbol
                | G::CurrencySymbol
                | G::ModifierSymbol
                | G::OtherSymbol
        )
}

/// Swift's `Character.isLetter` (its first scalar is alphabetic).
pub(crate) fn grapheme_is_letter(g: &str) -> bool {
    g.chars().next().is_some_and(char::is_alphabetic)
}

/// Swift's `Character.isNumber` (its first scalar has a numeric type).
pub(crate) fn grapheme_is_number(g: &str) -> bool {
    g.chars().next().is_some_and(|c| {
        matches!(get_general_category(c), G::DecimalNumber | G::LetterNumber | G::OtherNumber)
    })
}

pub(crate) fn graphemes(s: &str) -> Vec<&str> {
    s.graphemes(true).collect()
}

/// `String.contains(Character)` for a one-scalar character.
pub(crate) fn contains_grapheme(s: &str, g: &str) -> bool {
    s.contains(g) && s.graphemes(true).any(|x| x == g)
}

/// Swift `String ==`: canonical equivalence.
pub(crate) fn canon_eq(a: &str, b: &str) -> bool {
    a == b || (!(a.is_ascii() && b.is_ascii()) && a.nfd().eq(b.nfd()))
}

pub(crate) fn canon_eq_opt(a: Option<&str>, b: Option<&str>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => canon_eq(a, b),
        _ => false,
    }
}

/// Characters ICU's `$` also matches before when they end the input.
pub(crate) fn is_line_terminator(c: char) -> bool {
    matches!(c, '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

pub(crate) fn collect(s: &[char]) -> String {
    s.iter().collect()
}

pub(crate) fn utf16_len(s: &str) -> usize {
    s.chars().map(char::len_utf16).sum()
}
