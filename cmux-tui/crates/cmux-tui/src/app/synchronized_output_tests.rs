use super::*;
use ghostty_vt::{Callbacks, RenderState, Rgb, Terminal};

fn frame_of(text: &str) -> Arc<SurfaceRenderFrame> {
    let mut term = Terminal::new(10, 2, 0, Callbacks::default()).unwrap();
    term.vt_write(text.as_bytes());
    let mut state = RenderState::new().unwrap();
    state.update(&mut term).unwrap();
    Arc::new(SurfaceRenderFrame {
        frame: state.build_frame().unwrap(),
        content_generation: 1,
        scrollback_rows: 0,
        history_epoch: 0,
        pointer_semantics: term.pointer_semantic_snapshot(),
        palette_colors: [Rgb::default(); 256],
        palette_overridden: [false; 256],
    })
}

fn text(frame: &SurfaceRenderFrame) -> String {
    frame.frame.styled_row(0).unwrap().iter().map(|cell| cell.text.as_str()).collect()
}

fn draw(hold: &mut SynchronizedOutput, synchronized: bool, at: Instant, live: &str) -> String {
    let built = frame_of(live);
    text(&hold.frame::<()>(1, synchronized.then_some(1), at, || Ok(built)).unwrap())
}

#[test]
fn a_synchronized_update_draws_as_one_frame() {
    let mut hold = SynchronizedOutput::default();
    let start = Instant::now();
    assert_eq!(draw(&mut hold, false, start, "before"), "before");
    assert_eq!(hold.deadline(), None);
    let ms = |n| start + Duration::from_millis(n);
    assert_eq!(draw(&mut hold, true, ms(10), "half"), "before", "a half-drawn update shows");
    assert_eq!(hold.deadline(), Some(ms(10) + SYNCHRONIZED_OUTPUT_HOLD));
    assert_eq!(draw(&mut hold, true, ms(500), "more"), "before");
    assert_eq!(draw(&mut hold, false, ms(600), "whole"), "whole", "the update ended");
    assert_eq!(hold.deadline(), None);
}

#[test]
fn an_update_that_never_ends_is_drawn_after_the_hold() {
    let mut hold = SynchronizedOutput::default();
    let start = Instant::now();
    let ms = |n| start + Duration::from_millis(n);
    assert_eq!(draw(&mut hold, false, start, "before"), "before");
    assert_eq!(draw(&mut hold, true, ms(1), "stuck"), "before");
    let deadline = hold.deadline().unwrap();
    assert_eq!(draw(&mut hold, true, deadline, "stuck"), "stuck", "the hold ran out");
    assert_eq!(hold.deadline(), None, "no wake after the hold ran out");
    assert_eq!(draw(&mut hold, true, deadline + Duration::from_secs(5), "live"), "live");
    // A new update after the stuck one ended holds again.
    assert_eq!(draw(&mut hold, false, ms(7000), "after"), "after");
    assert_eq!(draw(&mut hold, true, ms(7001), "next"), "after");
}

#[test]
fn a_hold_of_a_pane_no_longer_drawn_stops_waking_the_loop() {
    let mut hold = SynchronizedOutput::default();
    let start = Instant::now();
    assert_eq!(draw(&mut hold, false, start, "before"), "before");
    assert_eq!(draw(&mut hold, true, start, "held"), "before");
    let deadline = hold.deadline().unwrap();
    assert!(!hold.release_expired(deadline - Duration::from_millis(1)));
    assert!(hold.release_expired(deadline));
    assert_eq!(hold.deadline(), None, "a hidden pane's hold must not keep waking the loop");
    assert_eq!(draw(&mut hold, true, deadline, "live"), "live");
}

#[test]
fn the_loop_wait_ends_at_a_hold_and_is_unchanged_without_one() {
    let mut hold = SynchronizedOutput::default();
    let start = Instant::now();
    let ms = Duration::from_millis;
    assert_eq!(hold.cap_wait(None, start), None, "no hold: an idle loop waits for an event");
    assert_eq!(hold.cap_wait(Some(ms(30)), start), Some(ms(30)));
    assert_eq!(draw(&mut hold, false, start, "before"), "before");
    assert_eq!(hold.cap_wait(None, start), None, "a drawn pane with no update holds nothing");
    assert_eq!(draw(&mut hold, true, start, "held"), "before");
    let at = start + ms(400);
    assert_eq!(hold.cap_wait(None, at), Some(SYNCHRONIZED_OUTPUT_HOLD - ms(400)));
    assert_eq!(hold.cap_wait(Some(ms(16)), at), Some(ms(16)));
    let late = start + SYNCHRONIZED_OUTPUT_HOLD + ms(5);
    assert_eq!(hold.cap_wait(None, late), Some(Duration::ZERO), "a passed hold wakes at once");
    assert!(hold.release_expired(late));
    assert_eq!(hold.cap_wait(None, late), None, "a released hold never wakes the loop again");
}

/// A program that never leaves the mode at a draw but begins a new update
/// every few milliseconds is still drawn live: a hold a new update began
/// draws live at its end before another new update can hold again.
#[test]
fn a_program_that_keeps_starting_updates_is_still_drawn() {
    let mut hold = SynchronizedOutput::default();
    let start = Instant::now();
    let ms = |n| start + Duration::from_millis(n);
    assert_eq!(draw(&mut hold, false, start, "before"), "before");
    let bound = 2 * SYNCHRONIZED_OUTPUT_HOLD.as_millis() as u64 + 16;
    let drawn_live = (1..=bound).step_by(8).enumerate().find(|&(starts, at)| {
        let built = frame_of("live");
        let shown = hold.frame::<()>(1, Some(starts as u64 + 1), ms(at), || Ok(built));
        text(&shown.unwrap()) == "live"
    });
    assert!(drawn_live.is_some(), "a program always starting a new update was never drawn");
}

/// The next update holds again even when its output reaches the pane
/// past the old hold's end but before the event loop released it.
#[test]
fn an_update_that_starts_past_an_unreleased_hold_end_holds_again() {
    let mut hold = SynchronizedOutput::default();
    let start = Instant::now();
    let ms = |n| start + Duration::from_millis(n);
    let draw_update = |hold: &mut SynchronizedOutput, starts, at, live: &str| {
        let built = frame_of(live);
        text(&hold.frame::<()>(1, Some(starts), at, || Ok(built)).unwrap())
    };
    assert_eq!(draw(&mut hold, false, start, "before"), "before");
    assert_eq!(draw_update(&mut hold, 1, ms(1), "stuck"), "before");
    let late = ms(1) + SYNCHRONIZED_OUTPUT_HOLD + Duration::from_millis(5);
    assert_eq!(draw_update(&mut hold, 2, late, "half"), "before", "the next update held");
}

#[test]
fn a_pane_never_drawn_before_draws_the_update_live() {
    let mut hold = SynchronizedOutput::default();
    assert_eq!(draw(&mut hold, true, Instant::now(), "first"), "first");
    hold.remove(&1);
    assert_eq!(hold.deadline(), None);
}
