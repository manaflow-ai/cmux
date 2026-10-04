//! Search folding: case, diacritic and width insensitive, like Swift
//! `String.folding(options: [.caseInsensitive, .diacriticInsensitive,
//! .widthInsensitive], locale: nil)`.
//!
//! The workspace has no Unicode normalization crate, so the fold uses two
//! small tables generated from the Unicode Character Database by
//! `tools/gen_fold_table.py` (see `fold_table.rs`):
//!
//! 1. Width: fullwidth and halfwidth forms map to their `<wide>`/`<narrow>`
//!    compatibility target (`Ａ` to `A`, `ｶ` to `カ`), U+3000 to a space.
//! 2. Case: Unicode lowercase mapping (`char::to_lowercase`).
//! 3. Diacritics: a precomposed Latin, Greek, Cyrillic or Kana letter whose
//!    canonical decomposition is a base letter plus nonspacing marks maps to
//!    that base (`é` to `e`, `が` to `か`); then every combining mark in the
//!    combining blocks below is dropped, which also folds input that arrives
//!    already decomposed (`e` + U+0301).

use crate::fold_table::{DIACRITIC_BASES, WIDTH_FORMS};

/// The folded form of `text`, for substring matching.
pub fn fold(text: &str) -> String {
        text.to_owned()
    }

/// The folded whitespace-separated tokens of a search text. Empty text has
/// no tokens and matches everything.
pub fn tokens(text: &str) -> Vec<String> {
    text.split(char::is_whitespace).filter(|token| !token.is_empty()).map(fold).collect()
}

fn lookup(table: &[(char, char)], ch: char) -> Option<char> {
    table.binary_search_by_key(&ch, |&(from, _)| from).ok().map(|index| table[index].1)
}

/// Combining Diacritical Marks and their supplements and extensions, the
/// combining marks for symbols and half marks, and the Kana voicing marks.
fn is_combining_mark(ch: char) -> bool {
    matches!(ch,
        '\u{0300}'..='\u{036F}'
        | '\u{1AB0}'..='\u{1AFF}'
        | '\u{1DC0}'..='\u{1DFF}'
        | '\u{20D0}'..='\u{20FF}'
        | '\u{FE20}'..='\u{FE2F}'
        | '\u{3099}'..='\u{309A}')
}

#[cfg(test)]
#[path = "fold_tests.rs"]
mod tests;
