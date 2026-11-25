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
    let filler =
        "ordinary context that fills the compact report body with useful but nonessential prose. "
            .repeat(10);
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
