use super::{HELD_MAX, hold, take_held};

/// A held notice rides the next prompt once, and a chat holds at most `HELD_MAX`, newest kept.
#[test]
fn a_held_notice_rides_the_next_prompt_once() {
    let id = "s-budget-held-test";
    assert_eq!(take_held(id), None);
    for n in 0..HELD_MAX + 2 {
        hold(id, format!("notice {n}"));
    }
    let text = take_held(id).expect("held");
    assert!(!text.contains("notice 0") && !text.contains("notice 1"), "{text}");
    assert!(text.starts_with("notice 2") && text.ends_with(&format!("notice {}", HELD_MAX + 1)));
    assert_eq!(take_held(id), None, "taken once");
}
