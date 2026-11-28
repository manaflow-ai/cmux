use super::*;

fn seen() -> ViewFacts {
    ViewFacts {
        in_window: true,
        in_window_with_content: true,
        intersects_content: true,
        ..ViewFacts::default()
    }
}

#[test]
fn a_move_from_a_seen_view_to_an_unseen_one_is_refused() {
    let hidden = ViewFacts { hidden: true, ..seen() };
    let facts = ResponderMove {
        target: Some(hidden),
        current: Some(seen()),
        current_in_target_window: true,
        ..ResponderMove::default()
    };
    assert!(unseen_refuses(&facts));
    assert!(!unseen_refuses(&ResponderMove { in_input_event: true, ..facts }), "a click moves it");
    assert!(!unseen_refuses(&ResponderMove { focus_model_applies: true, ..facts }));
    assert!(!unseen_refuses(&ResponderMove { target: Some(seen()), ..facts }));
    let offscreen = ViewFacts { intersects_content: false, ..seen() };
    assert!(!unseen_refuses(&ResponderMove { current: Some(offscreen), ..facts }));
    assert!(shows(&ViewFacts { bounds_empty: true, ..offscreen }), "an empty view is not unseen");
}

#[test]
fn a_system_move_off_the_typing_target_is_refused() {
    let facts = ResponderMove {
        system_origin: true,
        before_is_typing_target: true,
        typed_within_grace: true,
        ..ResponderMove::default()
    };
    assert!(takes_from_typing(&facts));
    assert!(!takes_from_typing(&ResponderMove { typed_within_grace: false, ..facts }));
    assert!(!takes_from_typing(&ResponderMove { system_origin: false, ..facts }));
    assert!(!takes_from_typing(&ResponderMove { responder_is_before: true, ..facts }));
}

#[test]
fn a_key_for_another_window_is_dropped() {
    let facts = KeyWindows {
        event_window: true,
        key_window: true,
        source: Some("w1".into()),
        target: Some("w2".into()),
        ..KeyWindows::default()
    };
    assert!(drops_key(&facts));
    assert!(!drops_key(&KeyWindows { target: Some("w1".into()), ..facts.clone() }));
    assert!(!drops_key(&KeyWindows { same_window: true, ..facts.clone() }));
    let foreign = KeyWindows { target: None, ..facts };
    assert!(!drops_key(&foreign), "a foreign key window with no held run takes the key");
    assert!(drops_key(&KeyWindows { held_run_key_window_is_key: Some(true), ..foreign }));
}
