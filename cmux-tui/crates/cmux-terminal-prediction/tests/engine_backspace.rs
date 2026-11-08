//! Backspace over glyphs the remote has not echoed yet (port of the
//! Backspace extension of classic cmux's TerminalPredictionEngineTests).
//!
//! The remote still receives, and echoes, every keystroke: the character,
//! then its erase. The overlay drops the glyph at once, and the engine has to
//! read that later echo as the confirmation it is rather than as output it
//! did not predict.

mod session;

use cmux_terminal_prediction::{Standing, Status};
use session::{Session, armed_session, ms};
use std::time::Duration;

const BACKSPACE: &str = "\u{7F}";

#[test]
fn backspace_retracts_an_unconfirmed_glyph() {
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    assert_eq!(session.drawn(), "sa");

    session.r#type(BACKSPACE);
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [0]);
    assert_eq!(session.engine.status(session.clock), Status::Predicting);

    // Typing continues in the cell the retracted glyph gave back.
    session.r#type("d");
    assert_eq!(session.drawn(), "sd");
    assert_eq!(session.live_offsets(), [0, 1]);
}

#[test]
fn either_backspace_byte_retracts() {
    // Ghostty sends DEL by default and BS when configured to.
    for input in ["\u{7F}", "\u{8}"] {
        let mut session = armed_session();
        session.r#type("s");
        session.r#type("a");
        session.r#type(input);
        assert_eq!(session.drawn(), "s");
        assert_eq!(session.engine.status(session.clock), Status::Predicting);
    }
}

#[test]
fn the_late_echo_of_a_retracted_glyph_confirms_without_withdrawing() {
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    session.r#type(BACKSPACE);

    session.remote("s");
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [-1]);

    // The remote prints the retracted "a" before it erases it. That cell
    // is the grid's to paint; the overlay must not bring the glyph back.
    // Each echo lands inside the hold of the confirmed "s".
    session.remote_after("a", ms(10));
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [-2]);

    session.remote_after("\u{8} \u{8}", ms(10));
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [-1]);
    assert_eq!(session.engine.status(session.clock), Status::Predicting);

    // Still armed: the next keystroke predicts, and its echo confirms.
    session.r#type("d");
    assert_eq!(session.drawn(), "sd");
    assert_eq!(session.live_offsets(), [-1, 0]);
    session.remote_after("d", ms(10));
    assert_eq!(session.standings(), [Standing::Confirmed, Standing::Confirmed]);
    assert_eq!(session.live_offsets(), [-2, -1]);
}

#[test]
fn an_erase_split_across_reads_keeps_offsets_on_the_live_cursor() {
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    session.r#type(BACKSPACE);
    session.remote("sa");
    assert_eq!(session.live_offsets(), [-2]);

    session.remote_after("\u{8}", ms(1));
    assert_eq!(session.live_offsets(), [-1]);
    session.remote_after(" ", ms(1));
    assert_eq!(session.live_offsets(), [-2]);
    session.remote_after("\u{8}", ms(1));
    assert_eq!(session.live_offsets(), [-1]);
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn every_common_erase_form_confirms_the_retraction() {
    // Tty canonical echo, readline, zsh's line editor, and the forms a
    // terminfo with delete-character or cursor-left emits.
    let erases = [
        "\u{8} \u{8}",
        "\u{8}\u{1B}[K",
        "\u{8}\u{1B}[0K",
        "\u{8}\u{1B}[P",
        "\u{8}\u{1B}[1P",
        "\u{1B}[D\u{1B}[K",
        "\u{1B}[1D\u{1B}[K",
        "\u{1B}[1D\u{1B}[P",
    ];
    for erase in erases {
        let mut session = armed_session();
        session.r#type("s");
        session.r#type("a");
        session.r#type(BACKSPACE);
        session.remote(&format!("sa{erase}"));

        assert_eq!(session.drawn(), "s", "{:?}", erase.as_bytes());
        assert_eq!(session.live_offsets(), [-1], "{:?}", erase.as_bytes());
        assert_eq!(session.engine.status(session.clock), Status::Predicting, "{:?}", erase.as_bytes());
    }
}

#[test]
fn syntax_highlighting_around_an_erase_still_confirms() {
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    session.r#type(BACKSPACE);
    session.remote("s\u{1B}[31ma\u{1B}[0m\u{8}\u{1B}[K\u{1B}[32m");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn retracting_every_glyph_then_retyping_keeps_the_run() {
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    session.r#type(BACKSPACE);
    session.r#type(BACKSPACE);
    assert_eq!(session.drawn(), "");

    session.r#type("b");
    assert_eq!(session.drawn(), "b");
    assert_eq!(session.live_offsets(), [0]);

    // The erases arrive innermost first, as the remote processed them.
    session.remote("sa\u{8} \u{8}\u{8} \u{8}b");
    assert_eq!(session.drawn(), "b");
    assert_eq!(session.standings(), [Standing::Confirmed]);
    assert_eq!(session.live_offsets(), [-1]);
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn backspace_over_confirmed_text_withdraws() {
    // The remote has already drawn "s" and a frame painted it, so erasing
    // it is the remote's business: behave as before and withdraw.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("s");
    session.present_frame();
    assert_eq!(session.drawn(), "");

    session.r#type(BACKSPACE);
    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn backspace_over_an_echo_not_yet_painted_blanks_it_until_the_erase() {
    // The echo of "s" arrived but no frame has painted it: the overlay
    // still holds it. Dropping it would show a blank, then the grid's
    // "s" for a frame, then the erase. It is blanked instead.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("s");
    assert_eq!(session.standings(), [Standing::Confirmed]);

    session.r#type(BACKSPACE);
    assert_eq!(session.drawn(), "");
    assert_eq!(session.blanks(), [-1]);
    assert_eq!(session.engine.status(session.clock), Status::Predicting);

    // The erase lands; the blank stays until a frame shows it.
    session.remote("\u{8}\u{1B}[K");
    assert!(session.engine.holds_layout_until_frame());
    session.present_frame();
    assert!(session.engine.glyphs().is_empty());
    assert!(!session.engine.holds_layout_until_frame());
}

#[test]
fn a_layout_hold_with_no_frame_releases_after_the_confirmation_hold() {
    // A host that never reports presented frames (ghostty's IOSurface
    // layer skips the drawable hook frames are counted on) must not keep
    // the overlay frozen on the blanks the erase removed.
    let mut session = armed_session();
    session.r#type("s");
    session.r#type(BACKSPACE);
    session.remote("s");
    session.remote("\u{8}\u{1B}[K");
    assert!(session.engine.holds_layout_until_frame());
    let held = session.clock;
    assert_eq!(session.engine.next_expiry(), Some(held + ms(120)));

    let changed_early = session.engine.tick(held + ms(100));
    assert!(!changed_early);
    assert!(session.engine.holds_layout_until_frame());
    let changed_after = session.engine.tick(held + ms(121));
    assert!(changed_after);
    assert!(!session.engine.holds_layout_until_frame());
    assert_eq!(session.engine.next_expiry(), None);
}

#[test]
fn backspace_on_an_empty_line_withdraws() {
    let mut session = armed_session();
    session.advance(ms(5));
    session.present_frame();
    assert_eq!(session.drawn(), "");

    session.r#type(BACKSPACE);
    assert_eq!(session.engine.status(session.clock), Status::Listening);

    session.r#type("s");
    assert_eq!(session.drawn(), "");
}

#[test]
fn backspace_at_a_password_prompt_shows_nothing() {
    let mut session = armed_session();
    session.remote("\r\n[sudo] password for leo: ");

    for character in ["h", "u", "n", BACKSPACE, "t", "e", BACKSPACE, "r", "2"] {
        session.r#type(character);
        assert_eq!(session.drawn(), "");
    }
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn unexpected_output_after_a_retraction_withdraws() {
    // Anything but the character and one of the recognised erases means
    // the remote is not a line editor doing what we modelled.
    let outcomes = [
        // A different character where the retracted one was expected.
        "sx",
        // The erase with no echo of the character first.
        "s\u{8} \u{8}",
        // A redraw of the whole line.
        "sa\r\u{1B}[K$ s",
        // Two cells erased for one keystroke.
        "sa\u{1B}[2D\u{1B}[K",
        // An erase that stops halfway and prints something else.
        "sa\u{8}x",
    ];
    for outcome in outcomes {
        let mut session = armed_session();
        session.r#type("s");
        session.r#type("a");
        session.r#type(BACKSPACE);
        session.r#type("d");
        assert_eq!(session.drawn(), "sd");

        session.remote(outcome);
        assert_eq!(session.drawn(), "", "{:?}", outcome.as_bytes());
        assert_eq!(session.engine.status(session.clock), Status::Listening, "{:?}", outcome.as_bytes());
    }
}

#[test]
fn a_remote_backspace_with_nothing_retracted_still_withdraws() {
    // Moving back over echoed text is fine as long as the remote prints
    // it again; printing something else there is a redraw.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("\u{8}x");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn an_undrawn_erase_still_sets_the_deadline_for_what_is_drawn() {
    // The erase is what expires first, and expiring it withdraws "d".
    // A deadline read off drawn glyphs alone would leave "d" drawn at an
    // offset that assumes the erase, a second past when it gave up.
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    session.r#type(BACKSPACE);
    let erased_at = session.clock;
    session.remote("sa");
    session.type_after("d", Duration::from_secs(1));
    assert_eq!(session.drawn(), "d");

    let deadline = session.engine.next_expiry().expect("a deadline");
    assert_eq!(deadline, erased_at + ms(1500));

    session.clock = deadline + ms(1);
    session.tick();
    assert_eq!(session.drawn(), "");
}

#[test]
fn unmodelled_erases_do_not_suspend_prediction() {
    // A shell that repaints the whole line on Backspace is doing nothing
    // wrong; withdrawing is enough, and counting it would suspend
    // prediction after a few corrections.
    let mut session = armed_session();
    for _ in 0..6 {
        session.r#type("s");
        session.r#type("a");
        session.r#type(BACKSPACE);
        assert_eq!(session.drawn(), "s");
        session.remote("sa\r\u{1B}[K$ s");
        assert_eq!(session.drawn(), "");
        assert_ne!(session.engine.status(session.clock), Status::Suspended);
        // Re-arm for the next cycle, once the dropped keystrokes' echo
        // could no longer be in flight.
        session.advance(ms(300));
        session.r#type("l");
        session.remote("l");
        session.r#type("l");
        session.remote("l");
        session.advance(ms(5));
        session.present_frame();
    }
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn an_echo_that_moves_the_cursor_under_a_drawn_glyph_asks_for_a_redraw() {
    // "a" goes out before the run arms, so it is never drawn; "b" is.
    // The echo of "a" changes nothing drawn but moves the cursor "b" is
    // measured from, and the host re-anchors only when asked.
    let mut session = Session::default();
    session.r#type("k");
    session.remote("k");
    session.r#type("l");
    session.type_after("a", ms(5));
    session.remote("l");
    session.type_after("b", ms(5));
    assert_eq!(session.live_offsets(), [1]);

    session.advance(ms(10));
    let redraw = session.engine.observed_output(b"a", session.clock);
    assert!(redraw);
    assert_eq!(session.live_offsets(), [0]);
}

#[test]
fn an_erase_the_remote_never_sends_is_withdrawn() {
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("a");
    session.r#type(BACKSPACE);
    session.remote("sa");
    session.type_after("d", ms(1));
    assert_eq!(session.drawn(), "sd");

    session.advance(ms(1501));
    session.tick();
    assert_eq!(session.drawn(), "");
}
