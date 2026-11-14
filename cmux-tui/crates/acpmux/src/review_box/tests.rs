use super::*;

#[test]
fn a_review_box_harness_or_a_review_tag_marks_one() {
    assert!(is("codex-review-box", std::iter::empty()));
    assert!(is("claude-review-box", std::iter::empty()));
    assert!(is("codex", ["review.verdict"].into_iter()));
    assert!(!is("codex", std::iter::empty()));
    assert!(!is("codex", ["lane", "reviewer"].into_iter()), "a tag named review without the dot");
    assert!(!is("review-box-codex", std::iter::empty()));
}
