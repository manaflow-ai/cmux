//! What a person sees of agent text: secrets scrubbed (`FeedSecretScrubber`), bidi and zero-width
//! controls shown (`AcpmuxPermissionPrompt.visible`), and cuts that count grapheme clusters as
//! Swift's `String.count` and `prefix` do.

use regex::{NoExpand, Regex};
use std::sync::LazyLock;
use unicode_segmentation::UnicodeSegmentation;

/// What a scrubbed secret becomes.
pub const MARKER: &str = "[redacted]";

/// How many characters of unbounded program output [`scrub_prefix`] reads.
pub const WINDOW: usize = 16 * 1024;

const WHOLE: &[&str] = &[
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|$)",
    r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}",
    r"\b(sk|pk|rk)-[A-Za-z0-9_-]{16,}",
    r"\b(ghp|gho|ghs|ghu|ghr)_[A-Za-z0-9]{20,}",
    r"\bgithub_pat_[A-Za-z0-9_]{20,}",
    r"\bglpat-[A-Za-z0-9_-]{16,}",
    r"\bxox[abposr]-[A-Za-z0-9-]{10,}",
    r"\b(AKIA|ASIA)[0-9A-Z]{16}\b",
    r"\bAIza[0-9A-Za-z_-]{30,}",
    r"\bnpm_[A-Za-z0-9]{30,}",
    r"(?i)\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@",
];

const BEARER: &str = r#"(?i)(\b(?:bearer|basic)\s+)([^\s"',;]{4,})"#;
const VALUED: &str = r#"(?i)(\b[a-z0-9_.-]*(?:api[_-]?key|token|secret|passw(?:or)?d|pwd|credential|auth(?:orization)?)[a-z0-9_.-]*["']?\s*[:=]\s*["']?)([^\s"',;]{4,})"#;

struct Patterns {
    whole: Vec<Regex>,
    kept_prefix: Vec<Regex>,
}

static PATTERNS: LazyLock<Patterns> = LazyLock::new(|| Patterns {
    whole: WHOLE.iter().filter_map(|pattern| Regex::new(pattern).ok()).collect(),
    kept_prefix: [BEARER, VALUED].iter().filter_map(|pattern| Regex::new(pattern).ok()).collect(),
});

/// `text` with every secret the patterns know replaced by [`MARKER`]: whole tokens (keys, JWTs,
/// URL credentials) go entirely; a bearer or a `name=value` keeps its name.
pub fn scrub(text: &str) -> String {
    if text.is_empty() {
        return String::new();
    }
    let mut out = text.to_owned();
    for pattern in &PATTERNS.whole {
        out = pattern.replace_all(&out, NoExpand(MARKER)).into_owned();
    }
    for pattern in &PATTERNS.kept_prefix {
        out = pattern.replace_all(&out, format!("${{1}}{MARKER}").as_str()).into_owned();
    }
    out
}

/// [`scrub`] of the first [`WINDOW`] characters.
pub fn scrub_prefix(text: &str) -> String {
    scrub(&prefix(text, WINDOW))
}

/// `text` with each invisible bidi or zero-width control written as `<U+XXXX>`.
pub fn visible(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for scalar in text.chars() {
        let value = scalar as u32;
        let hidden = matches!(value,
            0x061C | 0x180E | 0x200B..=0x200F | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x2069 | 0xFEFF);
        if hidden {
            out.push_str(&format!("<U+{value:04X}>"));
        } else {
            out.push(scalar);
        }
    }
    out
}

/// Swift's `String.count`: grapheme clusters.
pub fn count(text: &str) -> usize {
    text.graphemes(true).count()
}

/// Swift's `String(text.prefix(limit))`: the first `limit` grapheme clusters.
pub fn prefix(text: &str, limit: usize) -> String {
    text.graphemes(true).take(limit).collect()
}

/// `text` cut to `limit` characters, the last one an ellipsis when it was longer.
pub fn cut(text: &str, limit: usize) -> String {
    if count(text) > limit {
        let mut out = prefix(text, limit.saturating_sub(1));
        out.push('…');
        out
    } else {
        text.to_owned()
    }
}

/// Foundation's `CharacterSet.whitespaces`: space separators and tab, never a line break.
pub fn is_inline_space(scalar: char) -> bool {
    scalar == '\t'
        || (scalar.is_whitespace()
            && !matches!(
                scalar,
                '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}'
            ))
}

/// `text.trimmingCharacters(in: .whitespaces)`.
pub fn trim_inline(text: &str) -> &str {
    text.trim_matches(is_inline_space)
}

/// `a.caseInsensitiveCompare(b) == .orderedSame`.
pub fn same_ignoring_case(a: &str, b: &str) -> bool {
    a == b || a.to_lowercase() == b.to_lowercase()
}

/// `word` as a shell reads it: as is when every scalar is plain, else single-quoted.
pub fn shell_quoted(word: &str) -> String {
    let plain = !word.is_empty()
        && word
            .chars()
            .all(|scalar| scalar.is_ascii_alphanumeric() || "-_./=:,+@%".contains(scalar));
    if plain { word.to_owned() } else { single_quoted(word) }
}

/// `word` always single-quoted (`'` written `'\''`).
pub fn single_quoted(word: &str) -> String {
    format!("'{}'", word.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrub_replaces_whole_tokens_and_keeps_names() {
        assert_eq!(scrub("key ghp_abcdefghijklmnopqrstuvwxyz0123"), "key [redacted]");
        assert_eq!(scrub("curl -H Bearer abcdef123"), "curl -H Bearer [redacted]");
        assert_eq!(scrub("curl -H 'x' --token=hunter22 ok"), "curl -H 'x' --token=[redacted] ok");
        assert_eq!(scrub("git clone https://me:pw@host/x"), "git clone [redacted]host/x");
        assert_eq!(scrub("AKIAABCDEFGHIJKLMNOP"), "[redacted]");
        assert_eq!(
            scrub("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY----- tail"),
            "[redacted] tail"
        );
        assert_eq!(scrub("swift test --filter Login"), "swift test --filter Login");
        assert_eq!(scrub(""), "");
    }

    #[test]
    fn visible_writes_hidden_controls() {
        assert_eq!(visible("a\u{202E}b\u{FEFF}"), "a<U+202E>b<U+FEFF>");
        assert_eq!(visible("plain é"), "plain é");
    }

    #[test]
    fn cut_counts_graphemes() {
        assert_eq!(cut("abcdef", 4), "abc…");
        assert_eq!(cut("abcd", 4), "abcd");
        assert_eq!(cut("👨‍👩‍👧e\u{301}xy", 3), "👨‍👩‍👧e\u{301}…");
        assert_eq!(count("e\u{301}"), 1);
    }

    #[test]
    fn shell_quoting() {
        assert_eq!(shell_quoted("swift"), "swift");
        assert_eq!(shell_quoted("a b"), "'a b'");
        assert_eq!(shell_quoted(""), "''");
        assert_eq!(shell_quoted("it's"), r"'it'\''s'");
        assert_eq!(trim_inline(" \tx \n"), "x \n");
    }
}
