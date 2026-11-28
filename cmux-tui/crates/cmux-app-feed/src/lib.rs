//! The cmux NEXT app's Feed and Bookmarks rules, in Rust so the macOS app keeps only the
//! platform work (the why-swift RFD: Rust owns state, lists and rules; Swift is the shell).
//! Pure: no I/O. Served to the app over the app FFI's JSON channel (`cmux-layout-reducer-ffi`,
//! ops `app_feed_*`).
//!
//! - [`github_actions`]: what a Feed GitHub item's action does (`FeedGitHubActions`).
//! - [`dialog_answer`]: an agent question's selections as an answer (`AgentDialogDesk`).
//! - [`approve_proof`]: the phone approve proof's key list, install token and checks before the
//!   signature (`FeedApproveProofCheck`; the P-256 verify stays in CryptoKit).
//! - [`update_card`]: the installed update's Feed card (`UpdateFeedPosting`).
//! - [`bookmark_import`]: which browser profiles a bookmark import lists, offers and reads
//!   (`BookmarkBrowserImport`).

pub mod approve_proof;
pub mod bookmark_import;
pub mod dialog_answer;
pub mod github_actions;
pub mod update_card;

/// Swift's `CharacterSet.whitespaces`: spaces and tabs, not line breaks.
pub(crate) fn is_swift_whitespace(c: char) -> bool {
    c == '\t'
        || (c.is_whitespace()
            && !matches!(c, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'))
}

/// `trimmingCharacters(in: .whitespaces)`.
pub(crate) fn trim_whitespace(text: &str) -> &str {
    text.trim_matches(is_swift_whitespace)
}

/// Swift's `split(separator:maxSplits:)` with empty pieces omitted (they do not count toward
/// `max_splits`).
pub(crate) fn swift_split(text: &str, separator: char, max_splits: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    for (index, c) in text.char_indices() {
        if c != separator {
            continue;
        }
        let appended = index > start;
        if appended {
            out.push(&text[start..index]);
        }
        start = index + c.len_utf8();
        if appended && out.len() == max_splits {
            break;
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn split_omits_empty_pieces_like_swift() {
        assert_eq!(swift_split("a=b=c", '=', 1), vec!["a", "b=c"]);
        assert_eq!(swift_split("=b", '=', 1), vec!["b"]);
        assert_eq!(swift_split("a=", '=', 1), vec!["a"]);
        assert_eq!(swift_split("==x=y", '=', 1), vec!["x", "y"]);
        assert_eq!(swift_split("a..b", '.', usize::MAX), vec!["a", "b"]);
        assert!(swift_split("", '=', 1).is_empty());
    }

    #[test]
    fn trims_spaces_and_tabs_only() {
        assert_eq!(trim_whitespace(" \tx \u{00A0}"), "x");
        assert_eq!(trim_whitespace("\nx\n"), "\nx\n");
    }
}
