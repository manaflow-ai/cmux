//! Port of classic cmux's `PredictionBreakRenderRaceTests.swift`.
//!
//! The engine's offsets assume ghostty's parser has applied every byte the
//! engine has drained ("the tee runs ahead of the parser, and the engine
//! drains after it"). In the fork, `Termio.processOutput` calls the tee and
//! only then takes `renderer_state.mutex`, while the host's
//! `ghostty_surface_grid_metrics` read takes it with `lockDemand`. So the
//! main-actor drain can run, and re-anchor, before the IO thread parses the
//! same read. `presentedFrame` then retires held glyphs on a frame built
//! before the parse.

mod common;

use common::{PredictionBreakRig, RigScript};

fn script() -> RigScript {
    let mut script = RigScript::new(120);
    script.arm();
    script.type_text_after("echo.hello", 70);
    script
}

#[test]
fn with_the_parser_first_nothing_is_drawn_over_other_text() {
    let mut rig = PredictionBreakRig::new(script().keystrokes);
    rig.run();
    assert!(rig.ever_drew_speculative);
    assert!(rig.wrong_text.is_empty(), "{:?}", &rig.wrong_text[..rig.wrong_text.len().min(5)]);
}

/// The drain wins by 3 ms, less than one frame.
#[test]
fn a_drain_that_beats_the_parser_draws_echoed_glyphs_over_the_cells_to_their_left() {
    let mut rig = PredictionBreakRig::new(script().keystrokes);
    rig.parse_lag_micros = 3_000;
    rig.run();
    assert!(
        rig.wrong_text.is_empty(),
        "{}",
        rig.wrong_text[..rig.wrong_text.len().min(6)].join("\n")
    );
}

/// A frame presented between the drain and the parse retires the held
/// glyph, and that frame does not contain its character yet.
#[test]
fn a_frame_between_drain_and_parse_blanks_an_echoed_character() {
    let mut rig = PredictionBreakRig::new(script().keystrokes);
    rig.parse_lag_micros = 20_000;
    rig.run();
    assert!(rig.blankings.is_empty(), "{}", rig.blankings[..rig.blankings.len().min(6)].join("\n"));
}
