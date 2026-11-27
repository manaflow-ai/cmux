use std::sync::{Arc, Mutex};

use super::*;
use crate::desktop::Rect;

fn p(x: f64, y: f64) -> Point {
    Point { x, y }
}

fn mv(session: &str, x: f64, y: f64) -> CursorEvent {
    CursorEvent::Move { session: session.into(), label: "agent".into(), at: p(x, y) }
}

fn hide(session: &str) -> CursorEvent {
    CursorEvent::Hide { session: session.into() }
}

#[derive(Default)]
struct Seen(Mutex<Vec<CursorEvent>>);

impl CursorSink for Seen {
    fn show(&self, event: CursorEvent) {
        self.0.lock().unwrap().push(event);
    }
}

#[test]
fn the_cursor_glides_to_each_action_and_hides_when_the_last_session_ends() {
    let mut track = Track::default();
    assert_eq!(track.apply(&mv("a", 10.0, 20.0)), Draw::Glide(p(10.0, 20.0)));
    let click = CursorEvent::Click {
        session: "b".into(),
        label: "other".into(),
        at: p(5.0, 6.0),
        button: "left".into(),
        count: 1,
    };
    assert_eq!(track.apply(&click), Draw::Glide(p(5.0, 6.0)));
    // Typing with no point keeps the cursor where it is.
    let typing = CursorEvent::Typing {
        session: "a".into(),
        label: "agent".into(),
        at: None,
        text: "hi".into(),
    };
    assert_eq!(track.apply(&typing), Draw::Nothing);
    // One of two sessions ends: the cursor stays for the other.
    assert_eq!(track.apply(&hide("a")), Draw::Nothing);
    assert_eq!(track.apply(&hide("b")), Draw::Hide);
    // A second hide draws nothing.
    assert_eq!(track.apply(&hide("b")), Draw::Nothing);
}

#[test]
fn a_refusal_that_ends_the_session_hides_its_cursor() {
    let mut track = Track::default();
    track.apply(&mv("a", 1.0, 1.0));
    let stopped = CursorEvent::Refused {
        session: "a".into(),
        label: "agent".into(),
        at: None,
        reason: "Stopped".into(),
        ends: true,
    };
    assert_eq!(track.apply(&stopped), Draw::Hide);
}

#[test]
fn a_look_without_a_point_aims_at_the_window_it_reads() {
    let look = CursorEvent::Look {
        session: "a".into(),
        label: "agent".into(),
        at: None,
        rect: Some(Rect { x: 100.0, y: 200.0, width: 40.0, height: 20.0 }),
    };
    assert_eq!(target(&look), Some(p(120.0, 210.0)));
    let drag = CursorEvent::Drag {
        session: "a".into(),
        label: "agent".into(),
        from: p(0.0, 0.0),
        to: p(9.0, 9.0),
    };
    assert_eq!(target(&drag), Some(p(9.0, 9.0)));
}

#[test]
fn the_glide_starts_at_the_old_point_and_ends_at_the_new_one() {
    let (a, b) = (p(0.0, 0.0), p(100.0, 50.0));
    assert_eq!(glide(a, b, 0.0), a);
    assert_eq!(glide(a, b, 1.0), b);
    assert_eq!(glide(a, b, 7.0), b);
    let mid = glide(a, b, 0.5);
    // Ease-out: past halfway at half time.
    assert!(mid.x > 50.0 && mid.x < 100.0, "{mid:?}");
}

#[test]
fn show_cursor_off_draws_nothing_and_hides_what_is_up() {
    let seen = Arc::new(Seen::default());
    let gate = ShowCursor::new(seen.clone(), true);
    gate.show(mv("a", 1.0, 1.0));
    gate.set(false);
    gate.show(mv("a", 2.0, 2.0));
    gate.show(mv("b", 3.0, 3.0));
    assert_eq!(*seen.0.lock().unwrap(), vec![mv("a", 1.0, 1.0), hide("a")]);
    // Back on, the next action draws again.
    gate.set(true);
    gate.show(mv("b", 4.0, 4.0));
    gate.show(hide("b"));
    assert_eq!(seen.0.lock().unwrap()[2..], [mv("b", 4.0, 4.0), hide("b")]);
}

#[test]
fn show_cursor_off_from_the_start_draws_nothing() {
    let seen = Arc::new(Seen::default());
    let gate = ShowCursor::new(seen.clone(), false);
    gate.show(mv("a", 1.0, 1.0));
    gate.set(false);
    assert!(seen.0.lock().unwrap().is_empty());
}
