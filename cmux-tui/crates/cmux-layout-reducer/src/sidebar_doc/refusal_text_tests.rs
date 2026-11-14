//! The refusal text table: each code has its own plain-words text, and no
//! code falls back to a generic "did not make this move".

use std::collections::HashSet;

use super::model::*;

#[test]
fn every_refusal_round_trips_and_has_its_own_text() {
    let mut texts = HashSet::new();
    for refusal in Refusal::ALL {
        assert_eq!(Refusal::from_code(refusal.as_str()), Some(refusal));
        let text = refusal.text();
        assert!(texts.insert(text), "{refusal} shares its text: {text}");
        assert_eq!(change_failure_text(refusal.as_str()), text);
        assert!(!text.to_lowercase().contains("did not make this move"), "{refusal}: {text}");
    }
    for failure in CHANGE_FAILURES {
        assert!(Refusal::from_code(failure).is_none());
        assert!(texts.insert(change_failure_text(failure)), "{failure} shares its text");
    }
}

#[test]
fn an_unknown_code_is_a_failure_not_a_refusal() {
    assert_eq!(Refusal::from_code("nope"), None);
    assert_eq!(change_failure_text("nope"), change_failure_text("failed"));
    assert_eq!(change_failure_text(""), change_failure_text("failed"));
}

#[test]
fn the_limits_the_text_names_are_the_reducers() {
    assert!(Refusal::InvalidTitle.text().contains(&format!("1 to {MAX_TITLE_CHARS}")));
    assert!(Refusal::Nesting.text().contains(&MAX_GROUP_DEPTH.to_string()));
    assert!(Refusal::TooMany.text().contains(&MAX_SECTIONS.to_string()));
    assert!(Refusal::TooMany.text().contains("20,000") && MAX_ITEMS == 20_000);
}
