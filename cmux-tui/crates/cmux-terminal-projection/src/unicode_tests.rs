use super::*;

#[test]
fn widths_are_ghosttys() {
    assert_eq!(width('a'), 1);
    assert_eq!(width('\u{301}'), 0);
    assert_eq!(width('\u{200D}'), 0);
    assert_eq!(width('\u{FE0F}'), 0);
    assert_eq!(width('漢'), 2);
    assert_eq!(width('🇯'), 2);
    assert_eq!(width('👍'), 2);
    assert_eq!(width('🏽'), 2);
    assert_eq!(width('\u{2E3B}'), 2);
    assert_eq!(width('\u{20E3}'), 0);
    assert_eq!(width('\u{1160}'), 0);
    assert_eq!(width('\u{93F}'), 1);
}

#[test]
fn clusters_join_and_break() {
    assert!(!is_break("e", '\u{301}'));
    assert!(!is_break("👨", '\u{200D}'));
    assert!(!is_break("👨\u{200D}", '👩'));
    assert!(is_break("👨", '👩'));
    assert!(!is_break("🇯", '🇵'));
    assert!(is_break("🇯🇵", '🇺'));
    assert!(is_break("a", '漢'));
    assert!(!is_break("👍", '🏽'));
    assert!(!is_break("स\u{94D}", 'त'));
    assert_eq!(width_effect('❤', '\u{FE0F}'), WidthEffect::Wide);
    assert_eq!(width_effect('a', '\u{FE0F}'), WidthEffect::Ignore);
    assert_eq!(width_effect('☺', '\u{FE0E}'), WidthEffect::Narrow);
    assert_eq!(width_effect('e', '\u{301}'), WidthEffect::NoChange);
    assert_eq!(width_effect('क', '\u{93F}'), WidthEffect::Wide);
    assert_eq!(width_effect('a', '🏽'), WidthEffect::NoChange);
}
