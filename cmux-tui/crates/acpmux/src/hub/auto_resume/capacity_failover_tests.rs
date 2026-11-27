use super::*;

#[test]
fn the_switch_comes_at_the_configured_attempt_and_after() {
    assert!(!fails_over_at(1, 3));
    assert!(!fails_over_at(2, 3));
    assert!(fails_over_at(3, 3));
    assert!(fails_over_at(7, 3));
    assert!(fails_over_at(1, 1));
    // 0 never switches.
    assert!(!fails_over_at(1, 0));
    assert!(!fails_over_at(50, 0));
}

#[test]
fn the_notices_name_both_models() {
    assert_eq!(
        failover_text("claude-opus-5-5", "claude-sonnet-5-5"),
        "acpmux: Anthropic overloaded: continuing on claude-sonnet-5-5 (was claude-opus-5-5); back when it recovers"
    );
    let back = restored_text("claude-opus-5-5", "claude-sonnet-5-5");
    assert!(back.contains("continuing on claude-opus-5-5"), "{back}");
    assert!(back.contains("claude-sonnet-5-5"), "{back}");
}
