//! Pure formatting for the short lane report that is shown in a parent's inbox.
//!
//! The hub owns delivery and provenance; this module deliberately only reads the lane's last
//! reply. Keeping parsing here makes the report's headline and bounded excerpt independently
//! testable and prevents the delivery path from growing another transcript policy.

use regex::Regex;
use std::sync::LazyLock;

const EXCERPT_CHARS: usize = 600;
const HEADLINE_CHARS: usize = 120;

static REVIEW: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(
        r"(?im)Review\s*\([^\)\r\n]{1,120}\)\s*:\s*(SHIP|BLOCK|FIX|HOLD)\s+at\s+([0-9a-f]{40})\b",
    )
    .ok()
});
static FINDING_START: LazyLock<Option<Regex>> = LazyLock::new(|| {
    Regex::new(r"(?i)^\s*(?:[-*+]\s+|\d+[.)]\s+|#{1,6}\s+)?(?:\*\*|\[)?P([123])\b").ok()
});
static NO_FINDINGS: LazyLock<Option<Regex>> =
    LazyLock::new(|| Regex::new(r"(?i)^\s*(?:none|no findings?)\s*[.!]?\s*$").ok());

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) struct FindingCounts {
    pub(super) p1: usize,
    pub(super) p2: usize,
    pub(super) p3: usize,
}

impl FindingCounts {
    fn total(self) -> usize {
        self.p1 + self.p2 + self.p3
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ReviewVerdict {
    kind: String,
    sha: String,
    counts: FindingCounts,
    end: usize,
}

pub(super) fn headline(reply: &str) -> String {
    let Some(verdict) = verdict(reply) else {
        let one_line = reply.split_whitespace().collect::<Vec<_>>().join(" ");
        return first_sentence(&one_line, HEADLINE_CHARS);
    };
    let sha = verdict.sha.get(..12).unwrap_or(&verdict.sha);
    let counts = verdict.counts;
    if counts.total() == 0 {
        return format!("{} at {sha} · no findings", verdict.kind);
    }
    let mut parts = Vec::new();
    if counts.p1 > 0 {
        parts.push(format!("{} P1", counts.p1));
    }
    if counts.p2 > 0 {
        parts.push(format!("{} P2", counts.p2));
    }
    if counts.p3 > 0 {
        parts.push(format!("{} P3", counts.p3));
    }
    format!("{} at {sha} · {}", verdict.kind, parts.join(", "))
}

pub(super) fn excerpt(reply: &str) -> String {
    let Some(verdict) = verdict(reply) else {
        return bounded_lines(reply);
    };
    bounded_lines(reply.get(verdict.end..).unwrap_or_default())
}

fn verdict(reply: &str) -> Option<ReviewVerdict> {
    let marker = REVIEW.as_ref()?.captures(reply)?;
    let whole = marker.get(0)?;
    let kind = marker.get(1)?.as_str().to_ascii_uppercase();
    let sha = marker.get(2)?.as_str().to_ascii_lowercase();
    let tail = reply.get(whole.end()..).unwrap_or_default();
    let counts = count_findings(tail);
    Some(ReviewVerdict { kind, sha, counts, end: whole.end() })
}

fn count_findings(text: &str) -> FindingCounts {
    let mut counts = FindingCounts { p1: 0, p2: 0, p3: 0 };
    for line in text.lines() {
        let Some(level) = finding_start(line) else { continue };
        match level {
            '1' => counts.p1 += 1,
            '2' => counts.p2 += 1,
            '3' => counts.p3 += 1,
            _ => {}
        }
    }
    counts
}

fn finding_start(line: &str) -> Option<char> {
    if NO_FINDINGS.as_ref()?.is_match(line) {
        return None;
    }
    FINDING_START
        .as_ref()?
        .captures(line)
        .and_then(|capture| capture.get(1)?.as_str().chars().next())
}

fn bounded_lines(text: &str) -> String {
    let mut out = Vec::new();
    let mut used = 0usize;
    for line in text.lines().map(str::trim).filter(|line| !line.is_empty()) {
        let required = matches!(finding_start(line), Some('1' | '2'));
        let candidate =
            if required { first_sentence(line, EXCERPT_CHARS) } else { line.to_owned() };
        let cost = candidate.chars().count() + usize::from(!out.is_empty());
        if required || used + cost <= EXCERPT_CHARS {
            out.push(candidate);
            used += cost;
        }
    }
    out.join("\n")
}

fn first_sentence(text: &str, max: usize) -> String {
    let text = text.trim();
    if text.is_empty() {
        return String::new();
    }
    let end = text
        .char_indices()
        .find_map(|(index, ch)| {
            if !matches!(ch, '.' | '!' | '?') {
                return None;
            }
            let rest = text.get(index + ch.len_utf8()..).unwrap_or_default();
            let rest = rest.trim_start_matches('*').trim_start_matches('_');
            (rest.is_empty() || rest.starts_with(char::is_whitespace))
                .then_some(index + ch.len_utf8())
        })
        .unwrap_or(text.len());
    shorten_words(text.get(..end).unwrap_or(text), max)
}

fn shorten_words(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.trim().to_owned();
    }
    let end = text.char_indices().nth(max).map_or(text.len(), |(index, _)| index);
    let prefix = text.get(..end).unwrap_or(text);
    let boundary =
        prefix.char_indices().rfind(|(_, ch)| ch.is_whitespace()).map(|(index, _)| index);
    match boundary {
        Some(index) if index > 0 => prefix.get(..index).unwrap_or(prefix).trim_end().to_owned(),
        _ => text.chars().take(max).collect(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verdict_may_follow_prose_and_counts_findings() {
        assert!(REVIEW.is_some());
        assert!(FINDING_START.is_some());
        assert!(NO_FINDINGS.is_some());
        let reply = "I checked the branch. Review (Astra): BLOCK at 0123456789abcdef0123456789abcdef01234567\n- **P1:** one.\nP2 — two.\nP2 — three.\nP3: note.";
        assert_eq!(headline(reply), "BLOCK at 0123456789ab · 1 P1, 2 P2, 1 P3");
    }

    #[test]
    fn ship_none_has_compact_headline() {
        let reply = "Review (Sol): SHIP at ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD\nNone";
        assert_eq!(headline(reply), "SHIP at abcdefabcdef · no findings");
    }

    #[test]
    fn short_review_sha_is_not_a_verdict() {
        let reply = "Review (Sol): SHIP at abc123\nNone";
        assert_eq!(headline(reply), "Review (Sol): SHIP at abc123 None");
    }

    #[test]
    fn fallback_is_first_sentence_at_a_word_boundary() {
        let reply = "A useful report sentence that is deliberately long enough to pass the one hundred and twenty character display budget before it ends. More details.";
        let result = headline(reply);
        assert!(result.len() <= HEADLINE_CHARS);
        assert!(!result.ends_with(' '));
        assert!(result.starts_with("A useful report sentence"));
    }

    #[test]
    fn excerpt_keeps_required_findings_after_budget() {
        let filler = "ordinary context that fills the compact report body with useful but nonessential prose. ".repeat(10);
        let reply = format!(
            "Review (Sol): BLOCK at 0123456789abcdef0123456789abcdef01234567\n{filler}\nP1: the important finding survives. Follow-up details are omitted.\nP2: another finding survives."
        );
        let result = excerpt(&reply);
        assert!(result.contains("P1: the important finding survives."));
        assert!(result.contains("P2: another finding survives."));
    }

    #[test]
    fn counts_finding_starts_once_and_none_is_empty() {
        let reply = "Review (Sol): BLOCK at 0123456789abcdef0123456789abcdef01234567\nP1: one mentions P2 but is one finding\n- [P2] bracket finding\nNone\nP3: three.";
        assert_eq!(headline(reply), "BLOCK at 0123456789ab · 1 P1, 1 P2, 1 P3");
    }

    #[test]
    fn long_single_word_has_a_bounded_fallback() {
        let result = headline(&"x".repeat(200));
        assert_eq!(result.chars().count(), HEADLINE_CHARS);
    }

    #[test]
    fn no_review_excerpt_is_line_bounded() {
        let result = excerpt("first line\nsecond line\nthird line");
        assert_eq!(result, "first line\nsecond line\nthird line");
    }
}
