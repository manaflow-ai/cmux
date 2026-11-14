use super::viewer_silent_too_long;

#[test]
fn viewer_silence_allows_the_ninety_second_reattach_window() {
    assert!(!viewer_silent_too_long(90_000_000));
    assert!(viewer_silent_too_long(90_000_001));
}
