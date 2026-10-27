//! Text folding, character classes, prepared fields and queries.
//!
//! Every rule here matches the TypeScript ranker this crate replaced
//! (`webviews/src/palette/ranker.ts`) scalar for scalar, including the
//! JavaScript white space set and `String.prototype.trim`, so a query ranks
//! the same on every host.

use std::cell::OnceCell;
use unicode_general_category::{GeneralCategory, get_general_category};
use unicode_normalization::UnicodeNormalization;

/// The class of one scalar, for word boundaries.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum CharClass {
    Lower,
    Upper,
    Digit,
    Delimiter,
    Ideograph,
    Other,
}

/// JavaScript's `\s` (and the set `trim` removes): white space plus line terminators.
pub(crate) fn is_js_space(c: char) -> bool {
    matches!(
        c,
        '\t' | '\n' | '\u{b}' | '\u{c}' | '\r' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}'
                | '\u{2028}'
                | '\u{2029}'
                | '\u{202f}'
                | '\u{205f}'
                | '\u{3000}'
                | '\u{feff}'
    )
}

/// `String.prototype.trim`.
pub(crate) fn js_trim(text: &str) -> &str {
    text.trim_matches(is_js_space)
}

/// `String.prototype.trimEnd`.
pub(crate) fn js_trim_end(text: &str) -> &str {
    text.trim_end_matches(is_js_space)
}

/// `text.trim().split(/\s+/u).filter(Boolean)`.
pub(crate) fn js_words(text: &str) -> impl Iterator<Item = &str> {
    text.split(is_js_space).filter(|word| !word.is_empty())
}

/// White space collapsed to one space, trimmed, lowercased.
pub(crate) fn collapsed_lower(text: &str) -> String {
    js_words(text).collect::<Vec<_>>().join(" ").to_lowercase()
}

/// A scalar of general category Lu (`/\p{Lu}/u`).
pub(crate) fn is_lu(c: char) -> bool {
    get_general_category(c) == GeneralCategory::UppercaseLetter
}

fn is_ll(c: char) -> bool {
    get_general_category(c) == GeneralCategory::LowercaseLetter
}

/// One scalar folded for matching: compatibility-decomposed, lowercased, accents removed, the
/// first scalar left (the scalar itself when nothing is left).
pub(crate) fn fold_scalar(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }
    let decomposed: String = std::iter::once(c).nfkd().collect();
    decomposed
        .to_lowercase()
        .chars()
        .find(|scalar| !('\u{300}'..='\u{36f}').contains(scalar))
        .unwrap_or(c)
}

pub(crate) fn char_class(c: char) -> CharClass {
    let value = c as u32;
    match c {
        'a'..='z' => return CharClass::Lower,
        'A'..='Z' => return CharClass::Upper,
        '0'..='9' => return CharClass::Digit,
        _ => {}
    }
    if "-_./:,()[]<>…、。（）".contains(c) || is_js_space(c) {
        return CharClass::Delimiter;
    }
    if (0x3040..=0x30ff).contains(&value)
        || (0x3400..=0x9fff).contains(&value)
        || (0xac00..=0xd7af).contains(&value)
    {
        return CharClass::Ideograph;
    }
    if is_lu(c) {
        return CharClass::Upper;
    }
    if is_ll(c) {
        return CharClass::Lower;
    }
    CharClass::Other
}

fn mask_bit(folded: char) -> u64 {
    let value = folded as u32;
    match value {
        0x61..=0x7a => 1 << (value - 0x61),
        0x30..=0x39 => 1 << (26 + value - 0x30),
        0x20 => 0,
        _ => 1 << (36 + value % 28),
    }
}

pub(crate) fn mask_of(scalars: &[char]) -> u64 {
    scalars.iter().fold(0, |mask, &scalar| mask | mask_bit(scalar))
}

fn boundary_bonus(previous: CharClass, current: CharClass, first: bool) -> i64 {
    use CharClass::*;
    match (previous, current) {
        (_, Delimiter) => 0,
        (_, Ideograph) => {
            if first {
                10
            } else {
                3
            }
        }
        _ if first => 10,
        (Delimiter, _) => 9,
        (Lower, Upper) => 7,
        (Ideograph, _) => 9,
        (Lower | Upper, Digit) => 4,
        (Digit, Lower | Upper) => 4,
        _ => 0,
    }
}

/// A field's text, folded once with its word-start bonuses.
pub(crate) struct FoldedText {
    pub original: Vec<char>,
    pub folded: Vec<char>,
    pub bonus: Vec<i64>,
    pub initials: Vec<char>,
    pub mask: u64,
    words: OnceCell<Vec<Vec<char>>>,
}

impl FoldedText {
    pub(crate) fn new(original: &str) -> Self {
        let original: Vec<char> = original.chars().collect();
        let mut folded = Vec::with_capacity(original.len());
        let mut bonus = Vec::with_capacity(original.len());
        let mut initials = Vec::new();
        let mut mask = 0;
        let mut previous = CharClass::Delimiter;
        for (index, &scalar) in original.iter().enumerate() {
            let folded_scalar = fold_scalar(scalar);
            let current = char_class(scalar);
            let b = boundary_bonus(previous, current, index == 0);
            folded.push(folded_scalar);
            bonus.push(b);
            mask |= mask_bit(folded_scalar);
            if b >= 7 && current != CharClass::Delimiter && current != CharClass::Ideograph {
                initials.push(folded_scalar);
            }
            previous = current;
        }
        Self { original, folded, bonus, initials, mask, words: OnceCell::new() }
    }

    /// The folded words, split at delimiters.
    pub(crate) fn words(&self) -> &[Vec<char>] {
        self.words.get_or_init(|| {
            let mut words = Vec::new();
            let mut current = Vec::new();
            for (&scalar, &folded) in self.original.iter().zip(&self.folded) {
                if char_class(scalar) == CharClass::Delimiter {
                    if !current.is_empty() {
                        words.push(std::mem::take(&mut current));
                    }
                } else {
                    current.push(folded);
                }
            }
            if !current.is_empty() {
                words.push(current);
            }
            words
        })
    }
}

/// A typed query, folded per token.
pub(crate) struct Query {
    pub raw: String,
    pub tokens: Vec<Vec<char>>,
    pub token_masks: Vec<u64>,
    pub mask: u64,
    pub joined: Vec<char>,
    pub phrase: Vec<char>,
}

impl Query {
    pub(crate) fn new(raw: &str) -> Self {
        let words: Vec<&str> = js_words(raw).collect();
        let tokens: Vec<Vec<char>> =
            words.iter().map(|word| word.chars().map(fold_scalar).collect()).collect();
        let token_masks: Vec<u64> = tokens.iter().map(|token| mask_of(token)).collect();
        let mask = token_masks.iter().fold(0, |value, token_mask| value | token_mask);
        let joined = tokens.concat();
        let phrase = words.join(" ").chars().map(fold_scalar).collect();
        Self { raw: raw.to_owned(), tokens, token_masks, mask, joined, phrase }
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.tokens.is_empty()
    }
}

pub(crate) fn has_prefix(value: &[char], prefix: &[char]) -> bool {
    value.starts_with(prefix)
}

/// Whether `title` (or a keyword) is the whole query, ignoring case, surrounding space and a
/// trailing ellipsis.
pub(crate) fn title_is_query(title: &str, raw: &str) -> bool {
    fn normalize(text: &str) -> String {
        let trimmed = js_trim(text);
        let cut = trimmed
            .strip_suffix('\u{2026}')
            .or_else(|| trimmed.strip_suffix("..."))
            .unwrap_or(trimmed);
        js_trim(cut).to_lowercase()
    }
    let query = normalize(raw);
    !query.is_empty() && normalize(title) == query
}

/// `a < b` for JavaScript strings: UTF-16 code unit order.
pub(crate) fn js_string_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    a.encode_utf16().cmp(b.encode_utf16())
}
