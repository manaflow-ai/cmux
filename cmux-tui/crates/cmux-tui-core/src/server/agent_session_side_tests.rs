use super::*;

#[test]
fn the_fork_is_live_or_through_one_positive_turn() {
    assert_eq!(boundary("s", true, None), Some(json!({"sessionId": "s", "live": true})));
    assert_eq!(boundary("s", false, Some(4)), Some(json!({"sessionId": "s", "throughSeq": 4})));
    assert_eq!(boundary("s", false, Some(0)), None);
    assert_eq!(boundary("s", false, None), None);
    assert_eq!(boundary("s", true, Some(4)), None);
}

#[test]
fn a_first_prompt_needs_text_and_an_id() {
    assert!(matches!(first_prompt(None, None), Ok(None)));
    assert!(matches!(
        first_prompt(Some("look".into()), Some("p-1".into())),
        Ok(Some((text, id))) if text == "look" && id == "p-1"
    ));
    for (text, id) in [
        (Some("look"), None),
        (None, Some("p-1")),
        (Some("  "), Some("p-1")),
        (Some("look"), Some("")),
        (Some("look"), Some("p 1")),
    ] {
        assert!(
            matches!(
                first_prompt(text.map(Into::into), id.map(Into::into)),
                Err(Refusal::BadRequest)
            ),
            "{text:?} {id:?}"
        );
    }
    let long = "x".repeat(MAX_PROMPT_BYTES + 1);
    assert!(matches!(first_prompt(Some(long), Some("p".into())), Err(Refusal::BadRequest)));
}
