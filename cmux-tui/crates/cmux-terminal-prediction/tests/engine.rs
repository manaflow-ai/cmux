//! Port of classic cmux's `TerminalPredictionEngineTests.swift`.

use cmux_terminal_prediction::{
    PredictionConfiguration, Standing, Status, TerminalPredictionEngine,
};
use std::time::Duration;

fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

/// What Swift's `typed(_ text: String, at:)` did with the literal bytes cmux
/// was about to send: a lone DEL or BS is Backspace, a lone printable ASCII
/// byte is that key, and anything else withdraws.
fn typed_text(engine: &mut TerminalPredictionEngine, text: &str, now: Duration) -> bool {
    match text.as_bytes() {
        [0x7F | 0x08] => engine.typed_backspace(now),
        [byte @ 0x20..=0x7E] => engine.typed(Some(*byte), now),
        _ => engine.typed(None, now),
    }
}

/// Drives the engine the way the host does: keystrokes in, PTY bytes back.
struct Session {
    engine: TerminalPredictionEngine,
    clock: Duration,
}

impl Session {
    fn new() -> Self {
        Self {
            engine: TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true),
            clock: Duration::ZERO,
        }
    }

    fn advance(&mut self, step: Duration) {
        self.clock += step;
    }

    /// Types 10 ms after the previous event.
    fn type_key(&mut self, text: &str) {
        self.type_key_after(text, ms(10));
    }

    fn type_key_after(&mut self, text: &str, step: Duration) {
        self.advance(step);
        typed_text(&mut self.engine, text, self.clock);
    }

    /// The remote answers 70 ms after the previous event.
    fn remote(&mut self, text: &str) {
        self.remote_after(text, ms(70));
    }

    fn remote_after(&mut self, text: &str, step: Duration) {
        self.advance(step);
        self.engine.observed_output(text.as_bytes(), self.clock);
    }

    /// The characters drawn, without the blanks over deleted cells.
    fn drawn(&self) -> String {
        self.engine
            .glyphs()
            .iter()
            .filter(|glyph| glyph.standing != Standing::Erased)
            .map(|glyph| char::from(glyph.character))
            .collect()
    }

    /// Offsets of the cells drawn blank because the user deleted them.
    fn blanks(&self) -> Vec<i32> {
        self.engine
            .glyphs()
            .iter()
            .filter(|glyph| glyph.standing == Standing::Erased)
            .map(|glyph| glyph.offset)
            .collect()
    }

    fn live_offsets(&self) -> Vec<i32> {
        self.engine
            .glyphs()
            .iter()
            .filter(|glyph| glyph.standing != Standing::Erased)
            .map(|glyph| glyph.offset)
            .collect()
    }

    fn standings(&self) -> Vec<Standing> {
        self.engine.glyphs().iter().map(|glyph| glyph.standing).collect()
    }

    fn first_standing(&self) -> Option<Standing> {
        self.engine.glyphs().first().map(|glyph| glyph.standing)
    }

    fn status(&self) -> Status {
        self.engine.status(self.clock)
    }
}

/// Reaches the state where the engine is willing to draw: two echoed
/// characters over a link slow enough to be worth predicting.
fn armed_session() -> Session {
    let mut session = Session::new();
    session.type_key("l");
    session.remote("l");
    session.type_key("s");
    session.remote("s");
    session.engine.presented_frame(session.clock);
    session
}

#[test]
fn draws_nothing_before_the_remote_has_echoed_anything() {
    let mut session = Session::new();
    session.type_key("l");

    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn a_password_prompt_never_displays_a_typed_character() {
    // Established echo run at the shell, then sudo prints its prompt and
    // stops echoing. Every keystroke after that must stay invisible.
    let mut session = armed_session();
    session.remote("\r\n[sudo] password for leo: ");

    for character in ["h", "u", "n", "t", "e", "r", "2"] {
        session.type_key(character);
        assert_eq!(session.drawn(), "");
    }
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn an_unterminated_string_sequence_does_not_hide_a_password_prompt() {
    // An interrupted image transfer leaves an APC open. Ghostty closes it
    // at the next ESC and prints the prompt; the engine must see the
    // prompt too, or it keeps the echo run alive and draws the password.
    let mut session = armed_session();
    session.remote("\x1b_Gi=1\x1b[2J\r\n[sudo] password for leo: ");

    for character in ["h", "u", "n", "t", "e", "r", "2"] {
        session.type_key(character);
        assert_eq!(session.drawn(), "");
    }
}

#[test]
fn output_that_arrived_before_the_keystroke_is_not_its_echo() {
    // The IO thread stamps arrivals; the main actor drains them later. A
    // key typed in between must not claim output that was already in
    // flight, or a prompt could arm the echo run.
    //
    // The link is already measured slow, so claiming that output re-arms
    // a run that draws the next key. A fresh session would not show the
    // bug: its first latency sample would be negative, and a link that
    // measures fast draws nothing either way.
    let mut session = armed_session();
    session.remote("\r\n");
    assert_eq!(session.status(), Status::Listening);

    session.advance(ms(10));
    let arrival = session.clock;
    session.type_key("$");
    session.engine.observed_output(b"$", arrival);

    session.type_key("s");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.observed_echo_latency(), Some(ms(70)));
}

#[test]
fn an_erase_that_arrived_before_the_backspace_is_not_its_echo() {
    // The erase counterpart of the case above: a cursor-left and clear
    // already in flight when Backspace was pressed must not complete
    // that Backspace's erase, or the glyph typed after it stays drawn
    // while the real erase is still to come.
    let mut session = armed_session();
    let typed_a = session.clock + ms(10);
    session.type_key("a");
    session.type_key("\u{7f}");
    let typed_backspace = session.clock;
    session.type_key("b");
    assert_eq!(session.drawn(), "b");

    session.engine.observed_output(b"a", typed_a + ms(5));
    session.engine.observed_output(b"\x08\x1b[K", typed_backspace - ms(1));
    assert_eq!(session.drawn(), "");
}

#[test]
fn predicts_once_the_echo_run_is_established() {
    let mut session = armed_session();

    session.type_key("s");
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.first_standing(), Some(Standing::Speculative));

    session.type_key("-");
    session.type_key("a");
    assert_eq!(session.drawn(), "s-a");
    assert_eq!(session.live_offsets(), [0, 1, 2]);
}

#[test]
fn a_consumed_binding_does_not_raise_an_input_barrier() {
    let mut session = armed_session();
    session.type_key("s");
    session.engine.typed_nothing(session.clock + ms(1));
    session.type_key("-");

    assert_eq!(session.drawn(), "s-");
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn a_confirmed_glyph_keeps_drawing_until_a_frame_is_presented() {
    // The tee fires before the VT parser, so dropping the glyph at
    // confirmation blanks the cell until the paint catches up.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("s");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.first_standing(), Some(Standing::Confirmed));

    session.advance(ms(5));
    session.engine.presented_frame(session.clock);
    assert_eq!(session.drawn(), "");
}

#[test]
fn offsets_shift_down_as_confirmed_glyphs_retire() {
    let mut session = armed_session();
    session.type_key("a");
    session.type_key("b");
    assert_eq!(session.live_offsets(), [0, 1]);

    session.remote("a");
    session.advance(ms(5));
    session.engine.presented_frame(session.clock);

    assert_eq!(session.drawn(), "b");
    assert_eq!(session.live_offsets(), [0]);
}

#[test]
fn a_confirmed_glyph_sits_left_of_the_live_cursor() {
    // The host anchors on ghostty's cursor, which the parser has already
    // advanced past the echo. The held glyph has to land on the cell the
    // echo went to, not one to the right of it.
    let mut session = armed_session();
    session.type_key("a");
    session.type_key("b");
    session.remote("a");

    assert_eq!(session.drawn(), "ab");
    assert_eq!(session.live_offsets(), [-1, 0]);
    assert_eq!(session.standings(), [Standing::Confirmed, Standing::Speculative]);

    session.remote_after("b", ms(1));
    assert_eq!(session.live_offsets(), [-2, -1]);
}

#[test]
fn keystrokes_typed_before_arming_still_occupy_their_cells() {
    // "a" and "b" go out before any echo, so neither is drawn. The echo
    // of "a" arms the run; "c" is then drawn, and has to land after the
    // cell "b" is about to take rather than on top of it.
    let mut session = Session::new();
    session.type_key("x");
    session.remote("x");
    session.type_key("a");
    session.type_key_after("b", ms(5));
    session.remote("a");
    assert_eq!(session.drawn(), "");

    session.type_key_after("c", ms(5));
    assert_eq!(session.drawn(), "c");
    assert_eq!(session.live_offsets(), [1]);

    // "b" arrives: never drawn, so nothing is held, and "c" is now the
    // cell under the cursor. (The first echo, of "x", only starts the
    // streak that the echo of "a" completes.)
    session.remote_after("b", ms(1));
    assert_eq!(session.live_offsets(), [0]);
    assert_eq!(session.standings(), [Standing::Speculative]);
}

#[test]
fn a_contradicted_prediction_is_withdrawn_whole() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("t");
    assert_eq!(session.drawn(), "st");

    // Autocorrect, a completion, anything that is not the echo.
    session.remote("x");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn remote_output_we_did_not_type_ends_the_run() {
    let mut session = armed_session();
    session.type_key("s");

    // Command output arriving at the cursor moves the cell our offsets are
    // measured from.
    session.remote("total 48\r\n");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn editing_keys_and_return_stop_predicting_rather_than_guess() {
    // Backspace is not here: over an unconfirmed glyph it retracts, which
    // the backspace tests below cover.
    for input in ["\r", "\x1b[3~", "\x1b[D", "\x03"] {
        let mut session = armed_session();
        session.type_key("s");
        assert_eq!(session.drawn(), "s", "{input:?}");

        // The glyph already sent echoes ahead of the key, so it stays
        // drawn until then instead of vanishing and coming back.
        session.type_key(input);
        assert_eq!(session.drawn(), "s", "{input:?}");
        session.type_key("x");
        assert_eq!(session.drawn(), "s", "{input:?}");

        // Confirmed, it retires with the frame that paints its echo.
        session.remote("s");
        session.engine.presented_frame(session.clock);
        assert_eq!(session.drawn(), "", "{input:?}");
        session.type_key("y");
        assert_eq!(session.drawn(), "", "{input:?}");
    }
}

#[test]
fn return_answered_by_a_newline_is_not_a_misprediction() {
    // Typing a command and Return faster than the round trip: the remote
    // answers with the echo, then CR LF. The newline is Return doing what
    // it does, so repeating this never suspends prediction.
    let mut session = armed_session();
    for _ in 0..6 {
        session.type_key("s");
        session.type_key("\r");
        session.remote("s\r\n$ ");
        session.engine.presented_frame(session.clock);
        assert_eq!(session.drawn(), "");
        session.advance(ms(600));
        session.type_key("l");
        session.remote("l");
    }
    assert_ne!(session.status(), Status::Suspended);
}

#[test]
fn a_line_erase_after_return_leaves_the_submitted_line_drawn() {
    // Ctrl-U acts on the new line; the submitted one keeps its glyph
    // until its echo arrives.
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("\r");
    session.advance(ms(10));
    session.engine.typed_line_erase(session.clock);
    assert_eq!(session.drawn(), "s");
    assert!(session.blanks().is_empty());
}

#[test]
fn non_ascii_text_is_never_predicted() {
    // Width is not one cell for CJK, and combining marks do not advance the
    // cursor at all.
    for input in ["é", "世", "👍"] {
        let mut session = armed_session();
        session.type_key(input);
        assert_eq!(session.drawn(), "", "{input}");
    }
}

#[test]
fn the_alternate_screen_withholds_prediction() {
    let mut session = armed_session();
    session.type_key("s");
    assert_eq!(session.drawn(), "s");

    session.remote("\x1b[?1049h");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::AlternateScreen);

    session.type_key("j");
    assert_eq!(session.drawn(), "");

    session.remote("\x1b[?1049l");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn a_seeded_alternate_screen_withholds_prediction_until_it_exits() {
    // Prediction started with vim already open: no mode switch is ever
    // seen, and vim echoes typed characters in insert mode, which would
    // otherwise arm a run.
    let mut session = Session::new();
    session.engine.seed_alternate_screen(true);
    assert_eq!(session.status(), Status::AlternateScreen);

    session.type_key("l");
    session.remote("l");
    session.type_key("s");
    assert_eq!(session.drawn(), "");

    session.remote("\x1b[?1049l");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn a_mode_switch_seen_in_output_outranks_the_seed() {
    // Output is teed ahead of the terminal's parser, so a read taken at
    // the first keystroke can predate vim's switch the engine already saw.
    let mut session = Session::new();
    session.remote("\x1b[?1049h");
    session.engine.seed_alternate_screen(false);
    assert_eq!(session.status(), Status::AlternateScreen);
}

#[test]
fn a_fast_link_is_left_alone() {
    let mut session = Session::new();
    session.type_key("l");
    session.remote_after("l", ms(2));
    session.type_key("s");
    session.remote_after("s", ms(2));

    assert_eq!(session.status(), Status::LinkIsFastEnough);
    session.type_key("s");
    assert_eq!(session.drawn(), "");
}

#[test]
fn slow_echo_measurement_drives_the_decision_to_predict() {
    let mut session = Session::new();
    session.type_key("l");
    session.remote_after("l", ms(70));
    assert_eq!(session.engine.observed_echo_latency(), Some(ms(70)));
    // One echo is what a tty in cooked mode gives a key typed ahead of a
    // password prompt; the second shows the remote really echoes.
    assert_eq!(session.status(), Status::Listening);

    session.type_key("s");
    session.remote_after("s", ms(70));
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn repeated_visible_withdrawals_suspend_prediction() {
    let mut session = armed_session();

    for _ in 0..4 {
        session.type_key("s");
        assert_eq!(session.drawn(), "s");
        session.remote("x");
        // Re-arm for the next cycle, once the dropped keystroke's echo
        // could no longer be in flight.
        session.advance(ms(200));
        session.type_key("l");
        session.remote("l");
        session.type_key("l");
        session.remote("l");
    }

    assert_eq!(session.status(), Status::Suspended);
    session.type_key("s");
    assert_eq!(session.drawn(), "");

    session.advance(Duration::from_secs(31));
    session.type_key("l");
    session.remote("l");
    session.type_key("l");
    session.remote("l");
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn a_glyph_the_remote_never_echoes_is_withdrawn() {
    let mut session = armed_session();
    session.type_key("s");
    assert_eq!(session.drawn(), "s");

    session.advance(ms(1501));
    session.engine.tick(session.clock);
    assert_eq!(session.drawn(), "");
}

#[test]
fn a_host_that_stops_presenting_frames_does_not_pin_a_glyph() {
    let mut session = armed_session();
    session.type_key("s");
    session.remote("s");
    assert_eq!(session.drawn(), "s");

    session.advance(ms(121));
    session.engine.tick(session.clock);
    assert_eq!(session.drawn(), "");
}

#[test]
fn a_long_burst_stops_predicting_instead_of_running_away() {
    let mut session = armed_session();
    for _ in 0..40 {
        session.type_key_after("x", ms(1));
    }
    assert_eq!(session.engine.glyphs().len(), 40);

    session.type_key_after("x", ms(1));
    assert_eq!(session.drawn(), "");
}

#[test]
fn a_surface_not_known_to_be_remote_never_predicts() {
    // A local shell under load can echo slower than the threshold. It
    // must still never see a predicted glyph, and a host that has not
    // classified the surface yet gets the local behavior.
    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::default(), true, false);
    engine.typed(Some(b'l'), ms(10));
    engine.observed_output(b"l", ms(80));
    engine.typed(Some(b's'), ms(90));

    assert!(engine.glyphs().is_empty());
    assert_eq!(engine.status(ms(90)), Status::LocalSurface);
}

#[test]
fn classifying_the_surface_remote_lets_the_next_echo_arm() {
    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::default(), true, false);
    engine.typed(Some(b'l'), ms(10));
    engine.is_remote_surface = true;
    engine.typed(Some(b's'), ms(20));
    engine.typed(Some(b't'), ms(25));
    engine.observed_output(b"st", ms(90));
    engine.typed(Some(b'x'), ms(100));

    assert_eq!(engine.status(ms(100)), Status::Predicting);
    assert_eq!(engine.glyphs().last().map(|glyph| glyph.character), Some(b'x'));
}

#[test]
fn untracked_input_withdraws_and_keeps_later_keystrokes_undrawn() {
    // A paste lands between keystrokes. Its echo comes back ahead of the
    // next key's, so drawing that key at the cursor would put it where the
    // pasted text is about to go.
    let mut session = armed_session();
    session.type_key("s");
    assert_eq!(session.drawn(), "s");

    session.advance(ms(5));
    let _ = session.engine.sent_untracked_input(session.clock);
    // "s" was sent before the paste, so its echo still lands first.
    assert_eq!(session.drawn(), "s");

    session.type_key("x");
    assert_eq!(session.drawn(), "s");
    session.remote("s");
    session.engine.presented_frame(session.clock);
    assert_eq!(session.drawn(), "");
    session.remote("foo");
    session.remote("x");
    assert_eq!(session.drawn(), "");
}

#[test]
fn the_setting_gates_everything() {
    let mut session = Session::new();
    session.engine.is_enabled = false;
    session.type_key("l");
    session.remote("l");
    session.type_key("s");

    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::Disabled);
}

#[test]
fn syntax_highlighting_around_the_echo_still_confirms() {
    // zsh and fish wrap the echoed character in SGR. Treating colour as a
    // screen change would withdraw a correct prediction on every keystroke.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("\x1b[0m\x1b[32ms\x1b[0m");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.first_standing(), Some(Standing::Confirmed));
}

#[test]
fn terminfo_attribute_reset_around_the_echo_still_confirms() {
    // xterm-family terminfo spells sgr0 as `ESC ( B ESC [ m`.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("\x1b(B\x1b[ms");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.first_standing(), Some(Standing::Confirmed));
}

#[test]
fn shell_integration_markers_do_not_end_the_run() {
    // cmux's shell integration emits OSC 133 and OSC 7 constantly; they
    // carry no grid content.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("\x1b]133;C\x07s");

    assert_eq!(session.first_standing(), Some(Standing::Confirmed));
}

// Deadlines

#[test]
fn nothing_drawn_means_no_deadline_to_watch() {
    let mut session = armed_session();
    assert_eq!(session.engine.next_expiry(), None);

    session.type_key("s");
    assert!(session.engine.next_expiry().is_some());

    session.remote("x");
    assert_eq!(session.engine.next_expiry(), None);
}

#[test]
fn the_deadline_is_the_oldest_glyph_and_moves_in_on_confirmation() {
    let mut session = armed_session();
    session.type_key_after("s", ms(10));
    let typed_at = session.clock;
    session.type_key_after("t", ms(10));

    // The speculative lifetime of the first glyph, not the second.
    assert_eq!(session.engine.next_expiry(), Some(typed_at + ms(1500)));

    session.remote_after("s", ms(70));
    // A confirmed glyph waits on the shorter presentation hold instead.
    assert_eq!(session.engine.next_expiry(), Some(session.clock + ms(120)));
}

#[test]
fn a_glyph_the_host_never_ticks_still_has_a_deadline_to_tick_at() {
    // The case this exists for: the link dies mid-line, so no output and
    // no frame ever arrives to drive a withdrawal.
    let mut session = armed_session();
    session.type_key("s");
    let deadline = session.engine.next_expiry().expect("a drawn glyph has a deadline");

    session.clock = deadline + ms(1);
    session.engine.tick(session.clock);
    assert_eq!(session.drawn(), "");
}

// Backspace over glyphs the remote has not echoed yet.
//
// The remote still receives, and echoes, every keystroke: the character,
// then its erase. The overlay drops the glyph at once, and the engine has to
// read that later echo as the confirmation it is rather than as output it
// did not predict.

const BACKSPACE: &str = "\u{7f}";

#[test]
fn backspace_retracts_an_unconfirmed_glyph() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    assert_eq!(session.drawn(), "sa");

    session.type_key(BACKSPACE);
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [0]);
    assert_eq!(session.status(), Status::Predicting);

    // Typing continues in the cell the retracted glyph gave back.
    session.type_key("d");
    assert_eq!(session.drawn(), "sd");
    assert_eq!(session.live_offsets(), [0, 1]);
}

#[test]
fn either_backspace_byte_retracts() {
    // Ghostty sends DEL by default and BS when configured to.
    for input in ["\u{7f}", "\u{8}"] {
        let mut session = armed_session();
        session.type_key("s");
        session.type_key("a");
        session.type_key(input);
        assert_eq!(session.drawn(), "s", "{input:?}");
        assert_eq!(session.status(), Status::Predicting, "{input:?}");
    }
}

#[test]
fn the_late_echo_of_a_retracted_glyph_confirms_without_withdrawing() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    session.type_key(BACKSPACE);

    session.remote("s");
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [-1]);

    // The remote prints the retracted "a" before it erases it. That cell
    // is the grid's to paint; the overlay must not bring the glyph back.
    // Each echo lands inside the hold of the confirmed "s".
    session.remote_after("a", ms(10));
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [-2]);

    session.remote_after("\x08 \x08", ms(10));
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.live_offsets(), [-1]);
    assert_eq!(session.status(), Status::Predicting);

    // Still armed: the next keystroke predicts, and its echo confirms.
    session.type_key("d");
    assert_eq!(session.drawn(), "sd");
    assert_eq!(session.live_offsets(), [-1, 0]);
    session.remote_after("d", ms(10));
    assert_eq!(session.standings(), [Standing::Confirmed, Standing::Confirmed]);
    assert_eq!(session.live_offsets(), [-2, -1]);
}

#[test]
fn an_erase_split_across_reads_keeps_offsets_on_the_live_cursor() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    session.type_key(BACKSPACE);
    session.remote("sa");
    assert_eq!(session.live_offsets(), [-2]);

    session.remote_after("\x08", ms(1));
    assert_eq!(session.live_offsets(), [-1]);
    session.remote_after(" ", ms(1));
    assert_eq!(session.live_offsets(), [-2]);
    session.remote_after("\x08", ms(1));
    assert_eq!(session.live_offsets(), [-1]);
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn every_common_erase_form_confirms_the_retraction() {
    // Tty canonical echo, readline, zsh's line editor, and the forms a
    // terminfo with delete-character or cursor-left emits.
    let erases = [
        "\x08 \x08",
        "\x08\x1b[K",
        "\x08\x1b[0K",
        "\x08\x1b[P",
        "\x08\x1b[1P",
        "\x1b[D\x1b[K",
        "\x1b[1D\x1b[K",
        "\x1b[1D\x1b[P",
    ];
    for erase in erases {
        let mut session = armed_session();
        session.type_key("s");
        session.type_key("a");
        session.type_key(BACKSPACE);
        session.remote(&format!("sa{erase}"));

        let bytes = erase.as_bytes();
        assert_eq!(session.drawn(), "s", "{bytes:?}");
        assert_eq!(session.live_offsets(), [-1], "{bytes:?}");
        assert_eq!(session.status(), Status::Predicting, "{bytes:?}");
    }
}

#[test]
fn syntax_highlighting_around_an_erase_still_confirms() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    session.type_key(BACKSPACE);
    session.remote("s\x1b[31ma\x1b[0m\x08\x1b[K\x1b[32m");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn retracting_every_glyph_then_retyping_keeps_the_run() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    session.type_key(BACKSPACE);
    session.type_key(BACKSPACE);
    assert_eq!(session.drawn(), "");

    session.type_key("b");
    assert_eq!(session.drawn(), "b");
    assert_eq!(session.live_offsets(), [0]);

    // The erases arrive innermost first, as the remote processed them.
    session.remote("sa\x08 \x08\x08 \x08b");
    assert_eq!(session.drawn(), "b");
    assert_eq!(session.standings(), [Standing::Confirmed]);
    assert_eq!(session.live_offsets(), [-1]);
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn backspace_over_confirmed_text_withdraws() {
    // The remote has already drawn "s" and a frame painted it, so erasing
    // it is the remote's business: behave as before and withdraw.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("s");
    session.engine.presented_frame(session.clock);
    assert_eq!(session.drawn(), "");

    session.type_key(BACKSPACE);
    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn backspace_over_an_echo_not_yet_painted_blanks_it_until_the_erase() {
    // The echo of "s" arrived but no frame has painted it: the overlay
    // still holds it. Dropping it would show a blank, then the grid's
    // "s" for a frame, then the erase. It is blanked instead.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("s");
    assert_eq!(session.standings(), [Standing::Confirmed]);

    session.type_key(BACKSPACE);
    assert_eq!(session.drawn(), "");
    assert_eq!(session.blanks(), [-1]);
    assert_eq!(session.status(), Status::Predicting);

    // The erase lands; the blank stays until a frame shows it.
    session.remote("\x08\x1b[K");
    assert!(session.engine.holds_layout_until_frame());
    session.engine.presented_frame(session.clock);
    assert!(session.engine.glyphs().is_empty());
    assert!(!session.engine.holds_layout_until_frame());
}

#[test]
fn a_layout_hold_with_no_frame_releases_after_the_confirmation_hold() {
    // A host that never reports presented frames (ghostty's IOSurface
    // layer skips the drawable hook frames are counted on) must not keep
    // the overlay frozen on the blanks the erase removed.
    let mut session = armed_session();
    session.type_key("s");
    session.type_key(BACKSPACE);
    session.remote("s");
    session.remote("\x08\x1b[K");
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
    session.engine.presented_frame(session.clock);
    assert_eq!(session.drawn(), "");

    session.type_key(BACKSPACE);
    assert_eq!(session.status(), Status::Listening);

    session.type_key("s");
    assert_eq!(session.drawn(), "");
}

#[test]
fn backspace_at_a_password_prompt_shows_nothing() {
    let mut session = armed_session();
    session.remote("\r\n[sudo] password for leo: ");

    for character in ["h", "u", "n", BACKSPACE, "t", "e", BACKSPACE, "r", "2"] {
        session.type_key(character);
        assert_eq!(session.drawn(), "");
    }
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn unexpected_output_after_a_retraction_withdraws() {
    // Anything but the character and one of the recognised erases means
    // the remote is not a line editor doing what we modelled.
    let outcomes = [
        // A different character where the retracted one was expected.
        "sx",
        // The erase with no echo of the character first.
        "s\x08 \x08",
        // A redraw of the whole line.
        "sa\r\x1b[K$ s",
        // Two cells erased for one keystroke.
        "sa\x1b[2D\x1b[K",
        // An erase that stops halfway and prints something else.
        "sa\x08x",
    ];
    for outcome in outcomes {
        let mut session = armed_session();
        session.type_key("s");
        session.type_key("a");
        session.type_key(BACKSPACE);
        session.type_key("d");
        assert_eq!(session.drawn(), "sd");

        session.remote(outcome);
        let bytes = outcome.as_bytes();
        assert_eq!(session.drawn(), "", "{bytes:?}");
        assert_eq!(session.status(), Status::Listening, "{bytes:?}");
    }
}

#[test]
fn a_remote_backspace_with_nothing_retracted_still_withdraws() {
    // Moving back over echoed text is fine as long as the remote prints
    // it again; printing something else there is a redraw.
    let mut session = armed_session();
    session.type_key("s");
    session.remote("\x08x");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.status(), Status::Listening);
}

#[test]
fn an_undrawn_erase_still_sets_the_deadline_for_what_is_drawn() {
    // The erase is what expires first, and expiring it withdraws "d".
    // A deadline read off drawn glyphs alone would leave "d" drawn at an
    // offset that assumes the erase, a second past when it gave up.
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    session.type_key(BACKSPACE);
    let erased_at = session.clock;
    session.remote("sa");
    session.type_key_after("d", Duration::from_secs(1));
    assert_eq!(session.drawn(), "d");

    let deadline = session.engine.next_expiry().expect("a drawn glyph has a deadline");
    assert_eq!(deadline, erased_at + ms(1500));

    session.clock = deadline + ms(1);
    session.engine.tick(session.clock);
    assert_eq!(session.drawn(), "");
}

#[test]
fn unmodelled_erases_do_not_suspend_prediction() {
    // A shell that repaints the whole line on Backspace is doing nothing
    // wrong; withdrawing is enough, and counting it would suspend
    // prediction after a few corrections.
    let mut session = armed_session();
    for _ in 0..6 {
        session.type_key("s");
        session.type_key("a");
        session.type_key(BACKSPACE);
        assert_eq!(session.drawn(), "s");
        session.remote("sa\r\x1b[K$ s");
        assert_eq!(session.drawn(), "");
        assert_ne!(session.status(), Status::Suspended);
        // Re-arm for the next cycle, once the dropped keystrokes' echo
        // could no longer be in flight.
        session.advance(ms(300));
        session.type_key("l");
        session.remote("l");
        session.type_key("l");
        session.remote("l");
        session.advance(ms(5));
        session.engine.presented_frame(session.clock);
    }
    assert_eq!(session.status(), Status::Predicting);
}

#[test]
fn an_echo_that_moves_the_cursor_under_a_drawn_glyph_asks_for_a_redraw() {
    // "a" goes out before the run arms, so it is never drawn; "b" is.
    // The echo of "a" changes nothing drawn but moves the cursor "b" is
    // measured from, and the host re-anchors only when asked.
    let mut session = Session::new();
    session.type_key("k");
    session.remote("k");
    session.type_key("l");
    session.type_key_after("a", ms(5));
    session.remote("l");
    session.type_key_after("b", ms(5));
    assert_eq!(session.live_offsets(), [1]);

    session.advance(ms(10));
    let redraw = session.engine.observed_output(b"a", session.clock);
    assert!(redraw);
    assert_eq!(session.live_offsets(), [0]);
}

#[test]
fn an_erase_the_remote_never_sends_is_withdrawn() {
    let mut session = armed_session();
    session.type_key("s");
    session.type_key("a");
    session.type_key(BACKSPACE);
    session.remote("sa");
    session.type_key_after("d", ms(1));
    assert_eq!(session.drawn(), "sd");

    session.advance(ms(1501));
    session.engine.tick(session.clock);
    assert_eq!(session.drawn(), "");
}

#[test]
fn steady_typing_after_a_paste_predicts_again_without_a_pause() {
    // An unmodelled key (here a paste) withdraws, and output stays untracked
    // for two round trips. Keys typed in that window used to push it out
    // again, so typing faster than one key per two round trips never
    // predicted until a pause. They are now tracked: while the paste's own
    // output may still be printing their echoes are ambiguous, and after
    // that the first one closes the window. Every echo comes 150 ms after
    // its key, and keys are 100 ms apart, beyond the coalescing gap.
    let mut session = Session::new();
    for key in ["l", "s", "a", "b"] {
        session.type_key_after(key, ms(100));
        session.remote_after(key, ms(150));
        session.engine.presented_frame(session.clock);
    }
    session.advance(ms(100));
    let _ = session.engine.sent_untracked_input(session.clock);
    session.type_key_after("c", ms(100));
    assert_eq!(session.drawn(), "");
    session.remote_after("pasted", ms(50));
    session.type_key_after("d", ms(50));
    assert_eq!(session.drawn(), "");
    session.remote_after("c", ms(50));
    session.type_key_after("e", ms(50));
    session.remote_after("d", ms(50));
    session.engine.presented_frame(session.clock);
    session.type_key_after("f", ms(50));
    session.remote_after("e", ms(50));
    session.type_key_after("g", ms(50));
    session.remote_after("f", ms(50));
    session.engine.presented_frame(session.clock);
    // The old window would still be open: every key pushed it 350 ms out.
    session.type_key_after("h", ms(0));
    assert!(
        session.drawn().ends_with('h'),
        "drawn {:?}, status {:?}",
        session.drawn(),
        session.status()
    );
}

#[test]
fn steady_typing_after_backspace_predicts_again_without_a_pause() {
    // The same after Backspace over echoed text, whose echo may redraw the
    // rest of the line.
    let mut session = Session::new();
    for key in ["l", "s", "a", "b"] {
        session.type_key_after(key, ms(100));
        session.remote_after(key, ms(150));
        session.engine.presented_frame(session.clock);
    }
    session.type_key_after("\x7f", ms(100));
    session.type_key_after("c", ms(100));
    session.remote_after("\x08\x1b[K", ms(50));
    for (typed, echoed) in [("d", "c"), ("e", "d"), ("f", "e"), ("g", "f")] {
        session.type_key_after(typed, ms(50));
        session.remote_after(echoed, ms(50));
        session.engine.presented_frame(session.clock);
    }
    session.type_key_after("h", ms(50));
    assert!(
        session.drawn().ends_with('h'),
        "drawn {:?}, status {:?}",
        session.drawn(),
        session.status()
    );
}
