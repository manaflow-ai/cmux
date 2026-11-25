//! When a capture is due: leading edge, throttled, one in flight, nothing unwatched.

use cmux_pane_pictures::schedule::{Event, Outcome, PAGE_GAP_MS, PictureSchedule, TERMINAL_GAP_MS};

const GAP: u64 = 200;

fn watched() -> PictureSchedule {
    let mut s = PictureSchedule::new(GAP);
    s.note(Event::Watched, 0);
    s
}

#[test]
fn default_gaps() {
    assert_eq!(TERMINAL_GAP_MS, 200);
    assert_eq!(PAGE_GAP_MS, 500);
}

#[test]
fn first_damage_is_due_at_once() {
    let mut s = watched();
    // A watched tab with no picture yet is due at once, damaged or not.
    assert_eq!(s.due_at(), Some(0));
    let due = s.note(Event::Damaged, 1000).expect("due");
    assert!(due <= 1000);
    assert_eq!(s.take_due(1000), Some(1));
}

#[test]
fn a_burst_is_one_trailing_capture() {
    let mut s = watched();
    s.note(Event::Damaged, 1000);
    let g = s.take_due(1000).unwrap();
    // In flight: damage during it does not make a second concurrent capture.
    assert_eq!(s.note(Event::Damaged, 1010), None);
    assert_eq!(s.take_due(1020), None);
    // The capture ends; the damage since is due one gap after the start.
    assert_eq!(s.finish(g, Outcome::Done, 1050), Some(1000 + GAP));
    s.note(Event::Damaged, 1060);
    s.note(Event::Damaged, 1070);
    assert_eq!(s.take_due(1100), None);
    assert_eq!(s.take_due(1000 + GAP), Some(4));
    // That one picture covers the whole burst.
    assert_eq!(s.finish(4, Outcome::Done, 1210), None);
    assert!(s.is_current());
}

#[test]
fn nothing_while_unwatched() {
    let mut s = PictureSchedule::new(GAP);
    assert_eq!(s.note(Event::Damaged, 0), None);
    assert_eq!(s.take_due(10_000), None);
    s.note(Event::Watched, 10);
    assert_eq!(s.take_due(10), Some(1));
    s.finish(1, Outcome::Done, 20);
    s.note(Event::Damaged, 30);
    assert_eq!(s.note(Event::Unwatched, 40), None);
    assert_eq!(s.take_due(10_000), None);
}

#[test]
fn reopen_without_damage_is_current_and_not_due() {
    let mut s = watched();
    s.note(Event::Damaged, 0);
    let g = s.take_due(0).unwrap();
    s.finish(g, Outcome::Done, 5);
    s.note(Event::Unwatched, 100);
    assert_eq!(s.note(Event::Watched, 5000), None);
    assert!(s.is_current());
    assert_eq!(s.take_due(5000), None);
}

#[test]
fn unavailable_stops_retries_until_damage_or_watch() {
    let mut s = watched();
    s.note(Event::Damaged, 0);
    let g = s.take_due(0).unwrap();
    assert_eq!(s.finish(g, Outcome::Unavailable, 1), None);
    assert_eq!(s.take_due(100_000), None);
    assert!(!s.is_current());
    // Damage moves the generation: due again.
    assert!(s.note(Event::Damaged, 2000).is_some());
    let g = s.take_due(2000).unwrap();
    s.finish(g, Outcome::Unavailable, 2001);
    assert_eq!(s.take_due(100_000), None);
    // Watched again clears it.
    assert!(s.note(Event::Watched, 3000).is_some());
    assert_eq!(s.take_due(3000), Some(2));
}

#[test]
fn failure_backs_off_and_caps_at_eight_gaps() {
    let mut s = watched();
    s.note(Event::Damaged, 0);
    let mut now = 0;
    let mut gaps = Vec::new();
    for _ in 0..6 {
        let g = s.take_due(now).expect("due");
        let due = s.finish(g, Outcome::Failed, now).expect("retry");
        gaps.push(due - now);
        now = due;
    }
    assert_eq!(gaps, [2 * GAP, 4 * GAP, 8 * GAP, 8 * GAP, 8 * GAP, 8 * GAP]);
    // Success resets it.
    let g = s.take_due(now).unwrap();
    s.finish(g, Outcome::Done, now);
    s.note(Event::Damaged, now);
    assert_eq!(s.due_at(), Some(now + GAP));
}

#[test]
fn many_failures_do_not_overflow() {
    let mut s = PictureSchedule::new(u64::MAX / 2);
    s.note(Event::Watched, 0);
    s.note(Event::Damaged, 0);
    for _ in 0..100 {
        let g = s.take_due(u64::MAX).unwrap();
        s.finish(g, Outcome::Failed, u64::MAX);
    }
    assert_eq!(s.due_at(), Some(u64::MAX));
}

#[test]
fn stale_finish_keeps_its_picture_but_not_the_newer_content() {
    let mut s = watched();
    s.note(Event::Damaged, 0);
    let g = s.take_due(0).unwrap();
    s.note(Event::Damaged, 10);
    // The capture of generation 1 ends after damage made generation 2.
    assert_eq!(s.finish(g, Outcome::Done, 20), Some(GAP));
    assert!(!s.is_current());
    // A finish for an unrelated older generation does not free the in-flight one.
    let g2 = s.take_due(GAP).unwrap();
    assert_eq!(g2, 2);
    s.finish(1, Outcome::Done, GAP + 1);
    assert_eq!(s.due_at(), None, "generation 2 is still in flight");
    s.finish(2, Outcome::Done, GAP + 2);
    assert!(s.is_current());
    // A late older Done never lowers the kept generation.
    s.finish(1, Outcome::Done, GAP + 3);
    assert!(s.is_current());
}

#[test]
fn zero_work_when_idle() {
    let mut s = watched();
    let g = s.take_due(0).unwrap();
    s.finish(g, Outcome::Done, 1);
    assert_eq!(s.due_at(), None);
    assert_eq!(s.take_due(u64::MAX), None);
    assert_eq!(s.generation(), 0);
}

#[test]
fn a_stale_failure_does_not_raise_the_backoff() {
    let mut s = watched();
    s.note(Event::Damaged, 0);
    let g = s.take_due(0).unwrap();
    s.finish(g, Outcome::Done, 1);
    s.note(Event::Damaged, 1);
    let g2 = s.take_due(GAP).unwrap();
    // A late or repeated Failed for the finished generation is not the capture in flight.
    s.finish(g, Outcome::Failed, GAP + 1);
    s.finish(g, Outcome::Failed, GAP + 2);
    // The real one fails once: the first backoff step, not the third.
    // (the backoff counts from the capture's start at GAP; three counted failures would put it at GAP + 8 * GAP)
    assert_eq!(s.finish(g2, Outcome::Failed, GAP + 3), Some(GAP + 2 * GAP));
}
