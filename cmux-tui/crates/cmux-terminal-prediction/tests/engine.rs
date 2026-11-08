//! Port of classic cmux's TerminalPredictionEngineTests (all but the
//! Backspace cases, which are in tests/engine_backspace.rs).

mod session;

use cmux_terminal_prediction::{PredictionConfiguration, Standing, Status, TerminalPredictionEngine};
use session::{Session, armed_session, ms};
use std::time::Duration;

#[test]
fn draws_nothing_before_the_remote_has_echoed_anything() {
    let mut session = Session::default();
    session.r#type("l");

    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn a_password_prompt_never_displays_a_typed_character() {
    // Established echo run at the shell, then sudo prints its prompt and
    // stops echoing. Every keystroke after that must stay invisible.
    let mut session = armed_session();
    session.remote("\r\n[sudo] password for leo: ");

    for character in ["h", "u", "n", "t", "e", "r", "2"] {
        session.r#type(character);
        assert_eq!(session.drawn(), "");
    }
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn an_unterminated_string_sequence_does_not_hide_a_password_prompt() {
    // An interrupted image transfer leaves an APC open. Ghostty closes it
    // at the next ESC and prints the prompt; the engine must see the
    // prompt too, or it keeps the echo run alive and draws the password.
    let mut session = armed_session();
    session.remote("\u{1B}_Gi=1\u{1B}[2J\r\n[sudo] password for leo: ");

    for character in ["h", "u", "n", "t", "e", "r", "2"] {
        session.r#type(character);
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
    assert_eq!(session.engine.status(session.clock), Status::Listening);

    session.advance(ms(10));
    let arrival = session.clock;
    session.r#type("$");
    session.engine.observed_output(b"$", arrival);

    session.r#type("s");
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
    session.r#type("a");
    session.r#type("\u{7F}");
    let typed_backspace = session.clock;
    session.r#type("b");
    assert_eq!(session.drawn(), "b");

    session.engine.observed_output(b"a", typed_a + ms(5));
    session.engine.observed_output(b"\x08\x1B[K", typed_backspace - ms(1));
    assert_eq!(session.drawn(), "");
}

#[test]
fn predicts_once_the_echo_run_is_established() {
    let mut session = armed_session();

    session.r#type("s");
    assert_eq!(session.drawn(), "s");
    assert_eq!(session.engine.glyphs().first().map(|g| g.standing), Some(Standing::Speculative));

    session.r#type("-");
    session.r#type("a");
    assert_eq!(session.drawn(), "s-a");
    assert_eq!(session.live_offsets(), [0, 1, 2]);
}

#[test]
fn a_consumed_binding_does_not_raise_an_input_barrier() {
    let mut session = armed_session();
    session.r#type("s");
    session.engine.typed_nothing(session.clock + ms(1));
    session.r#type("-");

    assert_eq!(session.drawn(), "s-");
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn a_confirmed_glyph_keeps_drawing_until_a_frame_is_presented() {
    // The tee fires before the VT parser, so dropping the glyph at
    // confirmation blanks the cell until the paint catches up.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("s");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.engine.glyphs().first().map(|g| g.standing), Some(Standing::Confirmed));

    session.advance(ms(5));
    session.present_frame();
    assert_eq!(session.drawn(), "");
}

#[test]
fn offsets_shift_down_as_confirmed_glyphs_retire() {
    let mut session = armed_session();
    session.r#type("a");
    session.r#type("b");
    assert_eq!(session.live_offsets(), [0, 1]);

    session.remote("a");
    session.advance(ms(5));
    session.present_frame();

    assert_eq!(session.drawn(), "b");
    assert_eq!(session.live_offsets(), [0]);
}

#[test]
fn a_confirmed_glyph_sits_left_of_the_live_cursor() {
    // The host anchors on ghostty's cursor, which the parser has already
    // advanced past the echo. The held glyph has to land on the cell the
    // echo went to, not one to the right of it.
    let mut session = armed_session();
    session.r#type("a");
    session.r#type("b");
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
    let mut session = Session::default();
    session.r#type("x");
    session.remote("x");
    session.r#type("a");
    session.type_after("b", ms(5));
    session.remote("a");
    assert_eq!(session.drawn(), "");

    session.type_after("c", ms(5));
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
    session.r#type("s");
    session.r#type("t");
    assert_eq!(session.drawn(), "st");

    // Autocorrect, a completion, anything that is not the echo.
    session.remote("x");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn remote_output_we_did_not_type_ends_the_run() {
    let mut session = armed_session();
    session.r#type("s");

    // Command output arriving at the cursor moves the cell our offsets are
    // measured from.
    session.remote("total 48\r\n");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn editing_keys_and_return_stop_predicting_rather_than_guess() {
    // Backspace is not here: over an unconfirmed glyph it retracts, which
    // the backspace tests cover.
    for input in ["\r", "\u{1B}[3~", "\u{1B}[D", "\u{3}"] {
        let mut session = armed_session();
        session.r#type("s");
        assert_eq!(session.drawn(), "s");

        // The glyph already sent echoes ahead of the key, so it stays
        // drawn until then instead of vanishing and coming back.
        session.r#type(input);
        assert_eq!(session.drawn(), "s", "{input:?}");
        session.r#type("x");
        assert_eq!(session.drawn(), "s", "{input:?}");

        // Confirmed, it retires with the frame that paints its echo.
        session.remote("s");
        session.present_frame();
        assert_eq!(session.drawn(), "", "{input:?}");
        session.r#type("y");
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
        session.r#type("s");
        session.r#type("\r");
        session.remote("s\r\n$ ");
        session.present_frame();
        assert_eq!(session.drawn(), "");
        session.advance(ms(600));
        session.r#type("l");
        session.remote("l");
    }
    assert_ne!(session.engine.status(session.clock), Status::Suspended);
}

#[test]
fn a_line_erase_after_return_leaves_the_submitted_line_drawn() {
    // Ctrl-U acts on the new line; the submitted one keeps its glyph
    // until its echo arrives.
    let mut session = armed_session();
    session.r#type("s");
    session.r#type("\r");
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
        session.r#type(input);
        assert_eq!(session.drawn(), "", "{input}");
    }
}

#[test]
fn the_alternate_screen_withholds_prediction() {
    let mut session = armed_session();
    session.r#type("s");
    assert_eq!(session.drawn(), "s");

    session.remote("\u{1B}[?1049h");
    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::AlternateScreen);

    session.r#type("j");
    assert_eq!(session.drawn(), "");

    session.remote("\u{1B}[?1049l");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn a_seeded_alternate_screen_withholds_prediction_until_it_exits() {
    // Prediction started with vim already open: no mode switch is ever
    // seen, and vim echoes typed characters in insert mode, which would
    // otherwise arm a run.
    let mut session = Session::default();
    session.engine.seed_alternate_screen(true);
    assert_eq!(session.engine.status(session.clock), Status::AlternateScreen);

    session.r#type("l");
    session.remote("l");
    session.r#type("s");
    assert_eq!(session.drawn(), "");

    session.remote("\u{1B}[?1049l");
    assert_eq!(session.engine.status(session.clock), Status::Listening);
}

#[test]
fn a_mode_switch_seen_in_output_outranks_the_seed() {
    // Output is teed ahead of the terminal's parser, so a read taken at
    // the first keystroke can predate vim's switch the engine already saw.
    let mut session = Session::default();
    session.remote("\u{1B}[?1049h");
    session.engine.seed_alternate_screen(false);
    assert_eq!(session.engine.status(session.clock), Status::AlternateScreen);
}

#[test]
fn a_fast_link_is_left_alone() {
    let mut session = Session::default();
    session.r#type("l");
    session.remote_after("l", ms(2));
    session.r#type("s");
    session.remote_after("s", ms(2));

    assert_eq!(session.engine.status(session.clock), Status::LinkIsFastEnough);
    session.r#type("s");
    assert_eq!(session.drawn(), "");
}

#[test]
fn slow_echo_measurement_drives_the_decision_to_predict() {
    let mut session = Session::default();
    session.r#type("l");
    session.remote_after("l", ms(70));
    assert_eq!(session.engine.observed_echo_latency(), Some(ms(70)));
    // One echo is what a tty in cooked mode gives a key typed ahead of a
    // password prompt; the second shows the remote really echoes.
    assert_eq!(session.engine.status(session.clock), Status::Listening);

    session.r#type("s");
    session.remote_after("s", ms(70));
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn repeated_visible_withdrawals_suspend_prediction() {
    let mut session = armed_session();

    for _ in 0..4 {
        session.r#type("s");
        assert_eq!(session.drawn(), "s");
        session.remote("x");
        // Re-arm for the next cycle, once the dropped keystroke's echo
        // could no longer be in flight.
        session.advance(ms(200));
        session.r#type("l");
        session.remote("l");
        session.r#type("l");
        session.remote("l");
    }

    assert_eq!(session.engine.status(session.clock), Status::Suspended);
    session.r#type("s");
    assert_eq!(session.drawn(), "");

    session.advance(Duration::from_secs(31));
    session.r#type("l");
    session.remote("l");
    session.r#type("l");
    session.remote("l");
    assert_eq!(session.engine.status(session.clock), Status::Predicting);
}

#[test]
fn a_glyph_the_remote_never_echoes_is_withdrawn() {
    let mut session = armed_session();
    session.r#type("s");
    assert_eq!(session.drawn(), "s");

    session.advance(ms(1501));
    session.tick();
    assert_eq!(session.drawn(), "");
}

#[test]
fn a_host_that_stops_presenting_frames_does_not_pin_a_glyph() {
    let mut session = armed_session();
    session.r#type("s");
    session.remote("s");
    assert_eq!(session.drawn(), "s");

    session.advance(ms(121));
    session.tick();
    assert_eq!(session.drawn(), "");
}

#[test]
fn a_long_burst_stops_predicting_instead_of_running_away() {
    let mut session = armed_session();
    for _ in 0..40 {
        session.type_after("x", ms(1));
    }
    assert_eq!(session.engine.glyphs().len(), 40);

    session.type_after("x", ms(1));
    assert_eq!(session.drawn(), "");
}

#[test]
fn a_surface_not_known_to_be_remote_never_predicts() {
    // A local shell under load can echo slower than the threshold. It
    // must still never see a predicted glyph, and a host that has not
    // classified the surface yet gets the local behavior.
    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::DEFAULT, true, false);
    engine.typed(b"l", ms(10));
    engine.observed_output(b"l", ms(80));
    engine.typed(b"s", ms(90));

    assert!(engine.glyphs().is_empty());
    assert_eq!(engine.status(ms(90)), Status::LocalSurface);
}

#[test]
fn classifying_the_surface_remote_lets_the_next_echo_arm() {
    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::DEFAULT, true, false);
    engine.typed(b"l", ms(10));
    engine.is_remote_surface = true;
    engine.typed(b"s", ms(20));
    engine.typed(b"t", ms(25));
    engine.observed_output(b"st", ms(90));
    engine.typed(b"x", ms(100));

    assert_eq!(engine.status(ms(100)), Status::Predicting);
    assert_eq!(engine.glyphs().last().map(|g| g.character), Some('x'));
}

#[test]
fn untracked_input_withdraws_and_keeps_later_keystrokes_undrawn() {
    // A paste lands between keystrokes. Its echo comes back ahead of the
    // next key's, so drawing that key at the cursor would put it where the
    // pasted text is about to go.
    let mut session = armed_session();
    session.r#type("s");
    assert_eq!(session.drawn(), "s");

    session.advance(ms(5));
    let _ = session.engine.sent_untracked_input(session.clock);
    // "s" was sent before the paste, so its echo still lands first.
    assert_eq!(session.drawn(), "s");

    session.r#type("x");
    assert_eq!(session.drawn(), "s");
    session.remote("s");
    session.present_frame();
    assert_eq!(session.drawn(), "");
    session.remote("foo");
    session.remote("x");
    assert_eq!(session.drawn(), "");
}

#[test]
fn the_setting_gates_everything() {
    let mut session = Session::default();
    session.engine.is_enabled = false;
    session.r#type("l");
    session.remote("l");
    session.r#type("s");

    assert_eq!(session.drawn(), "");
    assert_eq!(session.engine.status(session.clock), Status::Disabled);
}

#[test]
fn syntax_highlighting_around_the_echo_still_confirms() {
    // zsh and fish wrap the echoed character in SGR. Treating colour as a
    // screen change would withdraw a correct prediction on every keystroke.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("\u{1B}[0m\u{1B}[32ms\u{1B}[0m");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.engine.glyphs().first().map(|g| g.standing), Some(Standing::Confirmed));
}

#[test]
fn terminfo_attribute_reset_around_the_echo_still_confirms() {
    // xterm-family terminfo spells sgr0 as `ESC ( B ESC [ m`.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("\u{1B}(B\u{1B}[ms");

    assert_eq!(session.drawn(), "s");
    assert_eq!(session.engine.glyphs().first().map(|g| g.standing), Some(Standing::Confirmed));
}

#[test]
fn shell_integration_markers_do_not_end_the_run() {
    // cmux's shell integration emits OSC 133 and OSC 7 constantly; they
    // carry no grid content.
    let mut session = armed_session();
    session.r#type("s");
    session.remote("\u{1B}]133;C\u{7}s");

    assert_eq!(session.engine.glyphs().first().map(|g| g.standing), Some(Standing::Confirmed));
}

#[test]
fn nothing_drawn_means_no_deadline_to_watch() {
    let mut session = armed_session();
    assert_eq!(session.engine.next_expiry(), None);

    session.r#type("s");
    assert!(session.engine.next_expiry().is_some());

    session.remote("x");
    assert_eq!(session.engine.next_expiry(), None);
}

#[test]
fn the_deadline_is_the_oldest_glyph_and_moves_in_on_confirmation() {
    let mut session = armed_session();
    session.type_after("s", ms(10));
    let typed_at = session.clock;
    session.type_after("t", ms(10));

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
    session.r#type("s");
    let deadline = session.engine.next_expiry().expect("a deadline");

    session.clock = deadline + ms(1);
    session.tick();
    assert_eq!(session.drawn(), "");
}
