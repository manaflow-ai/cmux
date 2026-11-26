//! `!` on the new tab screen (the Mac app's `NewTabTypeAhead.delta`): what to
//! type so a prompt showing what was sent shows what is typed now. Pure.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

/// DEL (the shell's backspace) for each character of `sent` after the common
/// prefix, then the rest of `typed`. Characters are grapheme clusters, and
/// two are equal when canonically equivalent, as Swift's `Character`s are.
pub fn delta(sent: &str, typed: &str) -> String {
    let sent: Vec<&str> = sent.graphemes(true).collect();
    let typed: Vec<&str> = typed.graphemes(true).collect();
    let common = sent.iter().zip(&typed).take_while(|(a, b)| same(a, b)).count();
    let mut out = "\u{7f}".repeat(sent.len() - common);
    out.extend(typed[common..].iter().copied());
    out
}

fn same(a: &str, b: &str) -> bool {
    a == b || a.nfd().eq(b.nfd())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_edit_erases_back_to_the_common_prefix_then_types_the_rest() {
        assert_eq!(delta("", "ls"), "ls");
        assert_eq!(delta("ls", "ls -la"), " -la");
        assert_eq!(delta("ls -la", "ls"), "\u{7f}\u{7f}\u{7f}\u{7f}");
        assert_eq!(delta("git stat", "git sw"), "\u{7f}\u{7f}\u{7f}w");
        assert_eq!(delta("same", "same"), "");
    }

    #[test]
    fn a_character_is_a_grapheme_cluster() {
        assert_eq!(delta("e\u{301}", "e"), "\u{7f}e", "one character erased, not one scalar");
        assert_eq!(delta("👍🏽x", "👍🏽y"), "\u{7f}y");
        assert_eq!(
            delta("caf\u{e9}s", "cafe\u{301}"),
            "\u{7f}",
            "é and e + U+0301 are one character"
        );
    }
}
