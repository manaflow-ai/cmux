//! Search folding: case, diacritic and width insensitive, for every script,
//! modeled on Swift `String.folding(options: [.caseInsensitive,
//! .diacriticInsensitive, .widthInsensitive], locale: nil)`.
//!
//! Per character, in this order:
//!
//! 1. NFKD (ICU4X `icu_normalizer`, compiled Unicode data): canonical and
//!    compatibility decomposition. This folds width (`Ａ` to `A`, `ｶ` to
//!    `カ`, U+3000 to a space) and splits precomposed letters into a base and
//!    marks (`é` to `e` + U+0301, `が` to `か` + U+3099).
//! 2. Drop every combining mark, meaning every character with a nonzero
//!    canonical combining class: Latin, Greek and Cyrillic accents, Kana
//!    voicing marks, Hebrew points, Arabic harakat, Indic nukta and virama.
//! 3. Locale-free case folding: Unicode lowercase mapping, plus the full
//!    case folds that differ from it: `ß` to `ss` (and `ẞ`, which lowercases
//!    to `ß`), final `ς` to `σ`, and the Cyrillic small letter variants
//!    U+1C80..U+1C88. `İ` lowercases to `i` + U+0307 and the dot is dropped,
//!    so it folds to `i`; the dotless `ı` stays (no Turkish rules).
//!
//! Differences from Swift, by design: NFKD also folds other compatibility
//! characters (`ﬁ` to `fi`, `²` to `2`, `①` to `1`); Swift's width option
//! covers only wide and narrow forms. Nonspacing marks with combining class
//! zero (for example Thai vowel signs) are kept.

use icu_normalizer::DecomposingNormalizerBorrowed;
use icu_normalizer::properties::CanonicalCombiningClassMapBorrowed;

const NFKD: DecomposingNormalizerBorrowed<'static> = DecomposingNormalizerBorrowed::new_nfkd();
const COMBINING_CLASS: CanonicalCombiningClassMapBorrowed<'static> =
    CanonicalCombiningClassMapBorrowed::new();

/// The folded form of `text`, for substring matching.
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in NFKD.normalize_iter(text.chars()) {
        if is_combining_mark(ch) {
            continue;
        }
        for lower in ch.to_lowercase() {
            if !is_combining_mark(lower) {
                push_case_folded(&mut out, lower);
            }
        }
    }
    out
}

/// The folded whitespace-separated tokens of a search text. Empty text has
/// no tokens and matches everything.
pub fn tokens(text: &str) -> Vec<String> {
    text.split(char::is_whitespace).filter(|token| !token.is_empty()).map(fold).collect()
}

fn is_combining_mark(ch: char) -> bool {
    COMBINING_CLASS.get_u8(ch) != 0
}

/// Appends the full case fold of an already lowercased character where it
/// differs from the lowercase mapping (CaseFolding.txt status C and F).
fn push_case_folded(out: &mut String, lower: char) {
    let folded = match lower {
        'ß' => {
            out.push_str("ss");
            return;
        }
        'ς' => 'σ',
        '\u{1C80}' => 'в',
        '\u{1C81}' => 'д',
        '\u{1C82}' => 'о',
        '\u{1C83}' => 'с',
        '\u{1C84}' | '\u{1C85}' => 'т',
        '\u{1C86}' => 'ъ',
        '\u{1C87}' => 'ѣ',
        '\u{1C88}' => '\u{A64B}',
        other => other,
    };
    out.push(folded);
}

#[cfg(test)]
#[path = "fold_tests.rs"]
mod tests;
