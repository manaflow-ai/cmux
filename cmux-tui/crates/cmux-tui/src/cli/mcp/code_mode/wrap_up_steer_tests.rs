use super::*;

/// A chat with acpmux's `wrap_up` is told to end a turn with it in `cmux_exec`'s own
/// description, since code mode shows no other tool; one without it is not.
#[test]
fn the_exec_description_names_wrap_up_only_where_it_is() {
    let with = descriptors(&[json!({"name": WRAP_UP})]);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.acpmux_wrap_up({recap, ask, actions})"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})]);
    assert!(!without[0]["description"].as_str().unwrap().contains("wrap_up"));
}

/// A chat with the cmux-sessions server folded in is told to suggest side work as a new chat
/// (`sessions_offer_session`) in `cmux_exec`'s description; one without it is not.
#[test]
fn the_exec_description_names_the_session_offer_only_where_it_is() {
    let with = descriptors(&[json!({"name": OFFER}), json!({"name": "sessions_suggest_tasks"})]);
    let text = with[0]["description"].as_str().unwrap();
    assert!(text.contains("cmux.sessions_offer_session({title, prompt, worktree?})"), "{text}");
    let without = descriptors(&[json!({"name": "pane_split"})]);
    assert!(!without[0]["description"].as_str().unwrap().contains("offer_session"));
}
