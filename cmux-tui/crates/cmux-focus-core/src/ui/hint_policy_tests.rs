use super::*;

#[test]
fn a_pane_navigation_key_keeps_the_hold_showing() {
    let mut policy = ShortcutHintPolicy::default();
    let held = CONTROL | OPTION;
    let delay = INTENTIONAL_HOLD_DELAY_NS;
    assert!(policy.update(held, true, delay));
    policy.key_down(true);
    assert!(
        policy.update(held, true, delay),
        "a pane-navigation key hid the hints while the modifier was still held"
    );
    policy.key_down(false);
    assert!(!policy.update(held, true, delay), "any other key hides them until release");
    assert!(!policy.update(0, true, delay));
    assert!(policy.update(held, true, delay), "a release clears the suppression");
}

#[test]
fn shift_alone_and_a_short_hold_do_not_show() {
    let mut policy = ShortcutHintPolicy::default();
    assert_eq!(ShortcutHintPolicy::armed(SHIFT), None);
    assert_eq!(ShortcutHintPolicy::armed(SHIFT | COMMAND | (1 << 23)), Some(SHIFT | COMMAND));
    assert!(!policy.update(SHIFT, true, INTENTIONAL_HOLD_DELAY_NS));
    assert!(!policy.update(COMMAND, true, INTENTIONAL_HOLD_DELAY_NS - 1));
    assert!(!policy.update(COMMAND, false, INTENTIONAL_HOLD_DELAY_NS));
}
