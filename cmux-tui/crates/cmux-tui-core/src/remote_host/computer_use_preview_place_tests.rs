use super::*;

fn card(session: &str, frame: &str, done: bool) -> Value {
    json!({"event": "preview", "session": session,
           "card": {"session": session, "app": "Calculator", "done": done, "frame": frame}})
}

#[test]
fn a_new_sessions_card_sits_top_right_small_and_shown() {
    let mut places = PreviewPlaces::default();
    let line = places.relay(card("s1", "data:image/jpeg;base64,AA", false)).unwrap();
    assert_eq!(line["card"]["place"], json!({"x": 1.0, "y": 0.0, "size": "small"}));
    assert_eq!(line["card"]["hidden"], json!(false));
}

#[test]
fn a_move_is_clamped_into_the_room_and_remembered_for_the_next_card() {
    let mut places = PreviewPlaces::default();
    assert_eq!(places.update("s1", &json!({"x": -3.0, "y": 0.25})).unwrap(), None);
    assert_eq!(places.place("s1"), Place { x: 0.0, y: 0.25, ..Place::default() });
    places.update("s1", &json!({"x": 7})).unwrap();
    assert_eq!(places.place("s1").x, 1.0);
    assert_eq!(places.place("s1").y, 0.25, "a missing key keeps its value");
    let line = places.relay(card("s1", "data:image/jpeg;base64,AA", false)).unwrap();
    assert_eq!(line["card"]["place"]["y"], json!(0.25));
    // Gone, then back: the place stays.
    places.relay(json!({"event": "preview", "session": "s1", "card": null})).unwrap();
    let line = places.relay(card("s1", "data:image/jpeg;base64,BB", false)).unwrap();
    assert_eq!(line["card"]["place"]["y"], json!(0.25));
}

#[test]
fn a_move_sends_the_card_at_once_with_its_newest_frame() {
    let mut places = PreviewPlaces::default();
    places.relay(card("s1", "data:image/jpeg;base64,AA", false));
    let line = places.update("s1", &json!({"x": 0.5, "size": "full"})).unwrap().unwrap();
    assert_eq!(line["card"]["frame"], json!("data:image/jpeg;base64,AA"));
    assert_eq!(line["card"]["place"], json!({"x": 0.5, "y": 0.0, "size": "full"}));
}

#[test]
fn a_hidden_card_sends_one_line_then_no_frames_until_it_shows_or_turns_done() {
    let mut places = PreviewPlaces::default();
    places.relay(card("s1", "data:image/jpeg;base64,AA", false));
    let hidden = places.update("s1", &json!({"hidden": true})).unwrap().unwrap();
    assert_eq!(hidden["card"]["hidden"], json!(true));
    assert!(places.relay(card("s1", "data:image/jpeg;base64,BB", false)).is_none());
    assert!(places.relay(card("s1", "data:image/jpeg;base64,CC", false)).is_none());
    let done = places.relay(card("s1", "data:image/jpeg;base64,CC", true)).unwrap();
    assert_eq!(done["card"]["done"], json!(true));
    assert_eq!(done["card"]["hidden"], json!(true));
    // Shown again: the newest frame at once, then every frame.
    let shown = places.update("s1", &json!({"hidden": false})).unwrap().unwrap();
    assert_eq!(shown["card"]["frame"], json!("data:image/jpeg;base64,CC"));
    assert_eq!(shown["card"]["hidden"], json!(false));
    assert!(places.relay(card("s1", "data:image/jpeg;base64,DD", true)).is_some());
}

#[test]
fn a_card_hidden_before_its_first_frame_sends_its_first_line_hidden() {
    let mut places = PreviewPlaces::default();
    places.update("s1", &json!({"hidden": true})).unwrap();
    let first = places.relay(card("s1", "data:image/jpeg;base64,AA", false)).unwrap();
    assert_eq!(first["card"]["hidden"], json!(true));
    assert!(places.relay(card("s1", "data:image/jpeg;base64,BB", false)).is_none());
}

#[test]
fn a_gone_line_always_goes_out() {
    let mut places = PreviewPlaces::default();
    places.update("s1", &json!({"hidden": true})).unwrap();
    let gone = json!({"event": "preview", "session": "s1", "card": null});
    assert_eq!(places.relay(gone.clone()), Some(gone));
}

#[test]
fn malformed_updates_are_refused_and_change_nothing() {
    let mut places = PreviewPlaces::default();
    assert!(places.update("", &json!({"x": 0.5})).is_err());
    assert!(places.update(&"s".repeat(257), &json!({"x": 0.5})).is_err());
    assert!(places.update("s1", &json!({"x": "left"})).is_err());
    assert!(places.update("s1", &json!({"size": "huge"})).is_err());
    assert!(places.update("s1", &json!({"hidden": "yes"})).is_err());
    assert_eq!(places.place("s1"), Place::default());
}

#[test]
fn the_least_recently_touched_session_goes_past_the_limit() {
    let mut places = PreviewPlaces::default();
    for index in 0..MAX_PLACES {
        places.update(&format!("s{index}"), &json!({"y": 0.5})).unwrap();
    }
    places.update("s0", &json!({"y": 0.75})).unwrap();
    places.update("new", &json!({"y": 0.5})).unwrap();
    assert_eq!(places.entries.len(), MAX_PLACES);
    assert_eq!(places.place("s0").y, 0.75, "touched last, kept");
    assert_eq!(places.place("s1"), Place::default(), "the oldest went");
}
