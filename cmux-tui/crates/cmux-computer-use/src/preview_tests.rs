use std::sync::{Arc, Mutex};

use serde_json::Value;

use super::*;

#[derive(Default)]
struct Streams(Mutex<Vec<(Vec<String>, u64)>>);

impl PreviewSource for Streams {
    fn stream(&self, windows: &[String], _long_side: u32, _fps: u32, generation: u64) {
        self.0.lock().unwrap().push((windows.to_vec(), generation));
    }
}

fn hub() -> (PreviewHub, Arc<Streams>, Arc<Mutex<Vec<Value>>>) {
    let streams = Arc::new(Streams::default());
    let hub = PreviewHub::new(streams.clone(), true);
    let lines = Arc::new(Mutex::new(Vec::new()));
    let sink = lines.clone();
    hub.watch(Arc::new(move |line: &Value| {
        sink.lock().unwrap().push(line.clone());
        true
    }));
    (hub, streams, lines)
}

const RECT: Rect = Rect { x: 100.0, y: 100.0, width: 400.0, height: 200.0 };

fn last(lines: &Mutex<Vec<Value>>) -> Value {
    lines.lock().unwrap().last().cloned().unwrap_or(Value::Null)
}

#[test]
fn an_active_session_streams_its_window_and_sends_its_frames() {
    let (hub, streams, lines) = hub();
    hub.activate("s1", "Claude Code");
    hub.note_window("s1", "Claude Code", "42", RECT, "Calculator");
    assert_eq!(streams.0.lock().unwrap().last().unwrap().0, vec!["42".to_string()]);
    hub.frame("42", &[0xff, 0xd8, 0xff]);
    let line = last(&lines);
    assert_eq!(line["session"], "s1");
    assert_eq!(line["card"]["done"], false);
    assert_eq!(line["card"]["app"], "Calculator");
    assert!(line["card"]["frame"].as_str().unwrap().starts_with("data:image/jpeg;base64,"));
}

#[test]
fn the_card_turns_done_when_the_session_is_no_longer_active_and_ignores_later_frames() {
    let (hub, _, lines) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    hub.frame("42", b"one");
    hub.deactivate("s1");
    let done = last(&lines);
    assert_eq!(done["card"]["done"], true);
    let count = lines.lock().unwrap().len();
    // The person's own changes after the turn are never shown.
    hub.frame("42", b"two");
    assert_eq!(lines.lock().unwrap().len(), count);
    assert_eq!(hub.card("s1").unwrap()["frame"], done["card"]["frame"]);
}

#[test]
fn a_closed_window_clears_its_card() {
    let (hub, streams, lines) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    hub.frame("42", b"one");
    hub.window_closed("42");
    assert_eq!(last(&lines)["card"], Value::Null);
    assert!(hub.card("s1").is_none());
    assert_eq!(streams.0.lock().unwrap().last().unwrap().0, Vec::<String>::new());
}

#[test]
fn turning_the_preview_off_removes_every_card_and_stream() {
    let (hub, streams, lines) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    hub.frame("42", b"one");
    hub.set_enabled(false);
    assert_eq!(last(&lines)["card"], Value::Null);
    assert_eq!(streams.0.lock().unwrap().last().unwrap().0, Vec::<String>::new());
    // Off: nothing is noted or streamed.
    hub.note_window("s1", "Codex", "43", RECT, "Notes");
    assert!(hub.streaming().is_empty());
}

#[test]
fn nothing_streams_without_a_watcher() {
    let hub = PreviewHub::new(Arc::new(Streams::default()), true);
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    assert!(hub.streaming().is_empty());
    let id = hub.watch(Arc::new(|_: &Value| true));
    assert_eq!(hub.streaming(), vec!["42".to_string()]);
    hub.unwatch(id);
    assert!(hub.streaming().is_empty());
}

#[test]
fn the_pointer_is_a_fraction_of_the_window_and_counts_clicks() {
    let (hub, _, lines) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    hub.frame("42", b"one");
    hub.cursor(&CursorEvent::Click {
        session: "s1".into(),
        label: "Codex".into(),
        at: Point { x: 300.0, y: 150.0 },
        button: "left".into(),
        count: 1,
    });
    let pointer = last(&lines)["card"]["pointer"].clone();
    assert_eq!(pointer["x"], 0.5);
    assert_eq!(pointer["y"], 0.25);
    assert_eq!(pointer["click"], 1);
    assert_eq!(pointer["windowWidth"], 400.0);
}

#[test]
fn a_late_watcher_gets_the_cards_shown_now() {
    let (hub, _, _) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    hub.frame("42", b"one");
    let got = Arc::new(Mutex::new(Vec::new()));
    let sink = got.clone();
    hub.watch(Arc::new(move |line: &Value| {
        sink.lock().unwrap().push(line.clone());
        true
    }));
    assert_eq!(got.lock().unwrap().len(), 1);
    assert_eq!(got.lock().unwrap()[0]["session"], "s1");
}

#[test]
fn old_done_cards_go_first_beyond_the_limit() {
    let (hub, _, lines) = hub();
    for i in 0..=MAX_CARDS {
        let session = format!("s{i}");
        let window = format!("{}", 100 + i);
        hub.activate(&session, "Codex");
        hub.note_window(&session, "Codex", &window, RECT, "Notes");
        hub.frame(&window, b"x");
        hub.deactivate(&session);
    }
    assert!(hub.card("s0").is_none());
    assert!(hub.card(&format!("s{MAX_CARDS}")).is_some());
    assert!(lines.lock().unwrap().iter().any(|l| l["session"] == "s0" && l["card"].is_null()));
}

#[test]
fn the_same_frame_again_sends_nothing() {
    let (hub, _, lines) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    hub.frame("42", b"one");
    let count = lines.lock().unwrap().len();
    hub.frame("42", b"one");
    hub.frame("42", b"one");
    assert_eq!(lines.lock().unwrap().len(), count);
    hub.frame("42", b"two");
    assert_eq!(lines.lock().unwrap().len(), count + 1);
}

#[test]
fn a_same_window_handoff_rejects_frames_from_the_previous_stream() {
    let (hub, streams, lines) = hub();
    hub.activate("s1", "Codex");
    hub.note_window("s1", "Codex", "42", RECT, "Notes");
    let first_generation = streams.0.lock().unwrap().last().unwrap().1;
    hub.frame_for_generation("42", first_generation, b"session one");

    hub.activate("s2", "Codex");
    hub.note_window("s2", "Codex", "42", RECT, "Notes");
    let second_generation = streams.0.lock().unwrap().last().unwrap().1;
    assert_ne!(first_generation, second_generation);
    let count = lines.lock().unwrap().len();

    // The old ScreenCaptureKit callback can arrive after the new session has
    // claimed the same window. It must not paint either card.
    hub.frame_for_generation("42", first_generation, b"stale session one");
    assert_eq!(lines.lock().unwrap().len(), count);
    assert_eq!(hub.card("s2"), None);
    hub.window_closed_for_generation("42", first_generation);
    assert!(hub.card("s1").is_some(), "a stale close must not clear the new stream");

    hub.frame_for_generation("42", second_generation, b"session two");
    assert_eq!(hub.card("s2").unwrap()["frame"], hub.card("s1").unwrap()["frame"]);
}
