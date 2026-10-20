//! Case and diacritic folding: the one text form the index and the query
//! match on. ASCII lowercases in place; other characters are decomposed
//! (NFKD), lose their combining marks and lowercase, so `Résumé` matches
//! `resume`.

use unicode_normalization::UnicodeNormalization;
use unicode_normalization::char::is_combining_mark;

/// The folded form of `text`.
pub fn fold(text: &str) -> String {
    let mut out = Vec::with_capacity(text.len());
    fold_into(text, &mut out);
    // `fold_into` writes only whole UTF-8 chars.
    String::from_utf8(out).unwrap_or_default()
}

/// Appends the folded bytes of `text` to `out` (cleared first).
pub(crate) fn fold_into(text: &str, out: &mut Vec<u8>) {
    out.clear();
    if text.is_ascii() {
        out.extend(text.bytes().map(|byte| byte.to_ascii_lowercase()));
        return;
    }
    let mut buffer = [0u8; 4];
    for ch in text.chars() {
        if ch.is_ascii() {
            out.push((ch as u8).to_ascii_lowercase());
            continue;
        }
        push_folded_char(ch, out, &mut buffer);
    }
}

/// Folds `text` and returns, for each folded byte (and one past the end),
/// the byte offset in `text` of the char it came from, so a match in the
/// folded text maps back to a range of the original.
pub(crate) fn fold_with_map(text: &str) -> (Vec<u8>, Vec<usize>) {
    let mut out = Vec::with_capacity(text.len());
    let mut map = Vec::with_capacity(text.len() + 1);
    let mut buffer = [0u8; 4];
    for (offset, ch) in text.char_indices() {
        let before = out.len();
        if ch.is_ascii() {
            out.push((ch as u8).to_ascii_lowercase());
        } else {
            push_folded_char(ch, &mut out, &mut buffer);
        }
        map.extend(std::iter::repeat_n(offset, out.len() - before));
    }
    map.push(text.len());
    (out, map)
}

fn push_folded_char(ch: char, out: &mut Vec<u8>, buffer: &mut [u8; 4]) {
    for decomposed in std::iter::once(ch).nfkd() {
        if is_combining_mark(decomposed) {
            continue;
        }
        for lower in decomposed.to_lowercase() {
            out.extend_from_slice(lower.encode_utf8(buffer).as_bytes());
        }
    }
}

/// Whether the folded byte at `index` of `text` starts a word: the first
/// byte, or one after a byte that is not a letter or digit (ASCII), or a
/// non-ASCII byte after an ASCII separator.
pub(crate) fn starts_word(text: &[u8], index: usize) -> bool {
    if index == 0 {
        return true;
    }
    let previous = text[index - 1];
    let current = text[index];
    if is_word_byte(previous) {
        return false;
    }
    // A UTF-8 continuation byte is inside a char, never a word start.
    current & 0xC0 != 0x80
}

/// Whether the folded byte at `end` (exclusive) ends a word.
pub(crate) fn ends_word(text: &[u8], end: usize) -> bool {
    end >= text.len() || !is_word_byte(text[end]) || !is_word_byte(text[end - 1])
}

fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte >= 0x80
}
