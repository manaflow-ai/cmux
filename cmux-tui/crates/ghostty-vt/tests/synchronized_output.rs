//! A render state never presents a half-drawn synchronized update (DECSET
//! 2026). Claude Code's fullscreen view draws each frame inside one; a frame
//! taken in the middle left its old "Jump to bottom" pill on screen beside the
//! new "6 new messages" pill (Lawrence's report, ask-f9d1d1707b).

use std::time::Instant;

use ghostty_vt::{
    Callbacks, Cell, CellWidth, RenderFrame, RenderState, SYNCHRONIZED_OUTPUT_TIMEOUT, Terminal,
};

fn line(cells: &[Cell]) -> String {
    let mut line = String::new();
    for cell in cells {
        if cell.width == CellWidth::SpacerTail {
            continue;
        }
        line.push_str(if cell.text.is_empty() { " " } else { &cell.text });
    }
    line.trim_end().to_string()
}

fn text(frame: &RenderFrame) -> Vec<String> {
    frame.styled_rows().iter().map(|row| line(row)).collect()
}

fn now() -> Instant {
    Instant::now()
}

#[test]
fn render_state_never_presents_a_torn_synchronized_update() {
    let mut term = Terminal::new(40, 3, 0, Callbacks::default()).unwrap();
    let mut render = RenderState::new().unwrap();
    term.vt_write(
        "\x1b[1;1Hask: Approve requests yourself\x1b[3;1HJump to bottom (click) ↓".as_bytes(),
    );
    assert!(render.update_for_display(&mut term, now()).unwrap());
    let complete = text(&render.build_frame().unwrap());
    assert_eq!(complete, ["ask: Approve requests yourself", "", "Jump to bottom (click) ↓"]);

    // A Claude-style frame: begin the update, erase the old pill's row, draw
    // the new pill a row up, and stop before the rest of the frame arrives.
    term.vt_write("\x1b[?2026h\x1b[3;1H\x1b[2K\x1b[2;1H6 new messages (click) ↓".as_bytes());
    assert!(!render.update_for_display(&mut term, now()).unwrap());
    assert_eq!(
        text(&render.build_frame().unwrap()),
        complete,
        "a half-drawn synchronized update reached the screen"
    );

    term.vt_write(b"\x1b[?2026l");
    assert!(render.update_for_display(&mut term, now()).unwrap());
    let frame = render.build_frame().unwrap();
    assert_eq!(text(&frame), ["ask: Approve requests yourself", "6 new messages (click) ↓", ""]);
    assert!(
        frame.dirty_rows.contains(&1) && frame.dirty_rows.contains(&2),
        "damage made during the hold must reach the frame that ends it: {:?}",
        frame.dirty_rows
    );
    assert_eq!(render.synchronized_hold_deadline(), None);
}

#[test]
fn a_plain_update_always_shows_the_terminal_as_it_is() {
    let mut term = Terminal::new(20, 2, 0, Callbacks::default()).unwrap();
    let mut render = RenderState::new().unwrap();
    render.update(&mut term).unwrap();
    term.vt_write(b"\x1b[?2026hmid-update");
    render.update(&mut term).unwrap();
    assert_eq!(text(&render.build_frame().unwrap())[0], "mid-update");
    assert_eq!(render.synchronized_hold_deadline(), None);
}

#[test]
fn a_stuck_synchronized_update_is_presented_after_the_timeout_and_then_stays_live() {
    let mut term = Terminal::new(20, 2, 0, Callbacks::default()).unwrap();
    let mut render = RenderState::new().unwrap();
    assert!(render.update_for_display(&mut term, now()).unwrap());
    term.vt_write(b"\x1b[?2026hstuck");

    let start = now();
    assert!(!render.update_for_display(&mut term, start).unwrap(), "the open update is held");
    let deadline = start + SYNCHRONIZED_OUTPUT_TIMEOUT;
    assert_eq!(render.synchronized_hold_deadline(), Some(deadline));
    assert!(render.update_for_display(&mut term, deadline).unwrap(), "presented at the deadline");
    assert_eq!(text(&render.build_frame().unwrap())[0], "stuck");
    assert_eq!(render.synchronized_hold_deadline(), None);

    // The application died inside its update: later output is live, not
    // throttled to one frame a second.
    term.vt_write(b"\r\nlive");
    assert!(render.update_for_display(&mut term, deadline).unwrap());
    assert_eq!(text(&render.build_frame().unwrap())[1], "live");

    // Once the application leaves the mode, the next update is held again.
    term.vt_write(b"\x1b[?2026l");
    assert!(render.update_for_display(&mut term, deadline).unwrap());
    term.vt_write(b"\x1b[?2026h\x1b[1;1Hhalf");
    assert!(!render.update_for_display(&mut term, deadline).unwrap(), "held afresh");
    assert_eq!(text(&render.build_frame().unwrap())[0], "stuck");
}

#[test]
fn a_render_state_that_has_not_drawn_this_terminal_presents_at_once() {
    let mut term = Terminal::new(20, 2, 0, Callbacks::default()).unwrap();
    term.vt_write(b"\x1b[?2026hfirst");
    let mut render = RenderState::new().unwrap();
    assert!(render.update_for_display(&mut term, now()).unwrap());
    assert_eq!(text(&render.build_frame().unwrap())[0], "first");
}
