//! When a capture is due: debounced, never while hidden or mid-transition, once at quit.

use cmux_launch_image::schedule::{Event, Schedule};

fn shown(debounce: u64) -> Schedule {
    let mut s = Schedule::new(debounce);
    s.note(Event::Shown, 0);
    s
}

#[test]
fn a_burst_of_changes_is_one_capture_after_the_debounce() {
    let mut s = shown(100);
    assert_eq!(s.note(Event::Changed, 1_000), Some(1_100));
    assert_eq!(s.note(Event::Changed, 1_050), Some(1_150));
    assert!(!s.take_due(1_149));
    assert!(s.take_due(1_150));
    assert!(!s.take_due(5_000), "the change was taken");
    assert_eq!(s.due_at(), None);
}

#[test]
fn nothing_is_due_while_hidden() {
    let mut s = Schedule::new(100);
    // A new window is hidden until shown.
    assert_eq!(s.note(Event::Changed, 10), None);
    assert!(!s.take_due(10_000));
    assert!(!s.take_quit());
    // Shown at 500: due a debounce after it became capturable, not after the change.
    assert_eq!(s.note(Event::Shown, 500), Some(600));
    s.note(Event::Hidden, 550);
    assert!(!s.take_due(700));
    assert_eq!(s.note(Event::Shown, 800), Some(900));
    assert!(s.take_due(900));
}

#[test]
fn nothing_is_due_mid_transition_and_transitions_nest() {
    let mut s = shown(100);
    s.note(Event::Changed, 1_000);
    s.note(Event::TransitionBegan, 1_010);
    s.note(Event::TransitionBegan, 1_020);
    s.note(Event::Changed, 1_030);
    assert!(!s.take_due(2_000));
    assert_eq!(s.note(Event::TransitionEnded, 2_000), None);
    assert!(!s.take_quit(), "no capture while a transition runs, quit included");
    // The last one ends at 3000: a debounce after that.
    assert_eq!(s.note(Event::TransitionEnded, 3_000), Some(3_100));
    assert!(!s.take_due(3_099));
    assert!(s.take_due(3_100));
    // An unmatched end does not wrap.
    s.note(Event::TransitionEnded, 4_000);
    assert_eq!(s.note(Event::Changed, 4_000), Some(4_100));
}

#[test]
fn a_failed_capture_is_due_again() {
    let mut s = shown(100);
    s.note(Event::Changed, 0);
    assert!(s.take_due(100));
    assert_eq!(s.note(Event::CaptureFailed, 150), Some(250));
    assert!(s.take_due(250));
}

#[test]
fn quit_captures_a_changed_or_never_captured_window_once() {
    let mut s = shown(100);
    assert!(s.take_quit(), "no capture in this run yet");
    assert!(!s.take_quit());
    s.note(Event::Changed, 10);
    assert!(s.take_quit(), "changed since its last capture");
    let mut settled = shown(100);
    settled.note(Event::Changed, 0);
    assert!(settled.take_due(100));
    assert!(!settled.take_quit(), "its last capture is current");
}

#[test]
fn unknown_raw_events_are_refused() {
    assert_eq!(Event::from_raw(0), None);
    assert_eq!(Event::from_raw(8), None);
    assert_eq!(Event::from_raw(7), Some(Event::CaptureDone));
    assert_eq!(Event::from_raw(1), Some(Event::Changed));
}

#[test]
fn a_capture_is_current_only_while_nothing_moved() {
    let mut s = shown(100);
    s.note(Event::Changed, 0);
    assert!(s.take_due(100));
    let started = s.epoch();
    assert!(s.is_current(started));
    // A failed capture elsewhere does not make it stale.
    s.note(Event::CaptureFailed, 110);
    assert!(s.is_current(started));
    // A resize, theme or tab change while it encodes does.
    s.note(Event::Changed, 120);
    assert!(!s.is_current(started));
    let next = s.epoch();
    s.note(Event::TransitionBegan, 130);
    assert!(!s.is_current(next));
    let mut hidden = shown(100);
    let e = hidden.epoch();
    hidden.note(Event::Hidden, 5);
    assert!(!hidden.is_current(e));
}

#[test]
fn a_capture_made_stale_by_a_hide_or_transition_is_due_again() {
    let mut s = shown(100);
    s.note(Event::Changed, 0);
    assert!(s.take_due(100));
    let started = s.epoch();
    // Occluded and shown again while it encodes: the capture is stale and dropped...
    s.note(Event::Hidden, 110);
    s.note(Event::Shown, 120);
    assert!(!s.is_current(started));
    // ...and its change is due again, a debounce after the window settled.
    assert_eq!(s.due_at(), Some(220));
    assert!(s.take_due(220));
    let again = s.epoch();
    s.note(Event::TransitionBegan, 230);
    s.note(Event::TransitionEnded, 240);
    assert!(!s.is_current(again));
    assert_eq!(s.due_at(), Some(340));
}

#[test]
fn repeated_visibility_events_and_finished_captures_change_nothing() {
    let mut s = shown(100);
    s.note(Event::Changed, 0);
    assert!(s.take_due(100));
    let started = s.epoch();
    s.note(Event::Shown, 105);
    s.note(Event::TransitionEnded, 106);
    assert!(s.is_current(started), "a repeated show or an unmatched end is no change");
    s.note(Event::CaptureDone, 110);
    // After it is done, a hide and show does not ask for another capture.
    s.note(Event::Hidden, 120);
    s.note(Event::Shown, 130);
    assert_eq!(s.due_at(), None);
    assert!(!s.take_quit());
}
