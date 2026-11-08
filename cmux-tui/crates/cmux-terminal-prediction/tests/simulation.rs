//! The randomized, seeded simulation of the whole prediction loop
//! (common/simulation.rs), swept over thousands of seeds, and the minimal
//! traces it found, pinned as regressions.

mod common;

use common::screen::SimulatedEraseForm::{BackspaceClearToEnd, CursorLeftDeleteCharacter};
use common::screen::SimulatedKey::{Backspace, Character};
use common::simulation::{PredictionSimulation, SimulationCase, ks};
use common::simulation_cases::{first_failure, make, make_burst_then_delete};

#[test]
fn every_drawn_glyph_lands_where_its_character_will() {
    if let Some(failure) = first_failure(1..=4_000, make) {
        panic!("{failure}");
    }
}

#[test]
fn a_burst_then_mashed_backspace_keeps_every_glyph_on_its_cell() {
    if let Some(failure) = first_failure(1..=4_000, make_burst_then_delete) {
        panic!("{failure}");
    }
}

#[test]
fn a_remote_that_coalesces_typeahead_keeps_every_glyph_on_its_cell() {
    let makers: [fn(u64) -> SimulationCase; 2] = [make, make_burst_then_delete];
    for maker in makers {
        if let Some(failure) = first_failure(1..=4_000, |seed| {
            let mut simulation_case = maker(seed);
            simulation_case.coalesces_typeahead = true;
            simulation_case
        }) {
            panic!("{failure}");
        }
    }
}

#[test]
fn the_simulation_actually_predicts() {
    let mut predicting = 0;
    for seed in 1..=200 {
        let mut simulation = PredictionSimulation::new(make_burst_then_delete(seed));
        let _ = simulation.run();
        if simulation.predicted_events > 0 {
            predicting += 1;
        }
    }
    assert!(predicting > 150, "{predicting} of 200 seeds predicted");
}

fn expect_passes(simulation_case: SimulationCase) {
    if let Some(failure) = PredictionSimulation::new(simulation_case).run() {
        panic!("{failure}");
    }
}

fn case(keystrokes: Vec<common::simulation::SimulatedKeystroke>, erase_form: common::screen::SimulatedEraseForm) -> SimulationCase {
    SimulationCase { keystrokes, erase_form, coalesces_typeahead: false }
}

/// Minimal trace behind the dogfood report of a burst's own glyph drawn
/// cells right of the cursor. "d" and "f" go out before any echo, so neither
/// is drawn; "a" is. Ghostty parses the echo of "f" and renders a frame
/// before the engine drains it, so the overlay re-anchors on the advanced
/// cursor with the old offsets. Draining the echo of an undrawn keystroke
/// changed nothing drawn, so nothing asked for a redraw, and "a" stayed one
/// cell right per such echo until the next frame.
#[test]
fn an_undrawn_echo_still_reanchors_the_overlay() {
    expect_passes(case(
        vec![
            ks(Character(b'd'), 39435, 99559, 72095, 9648886400068060533),
            ks(Character(b'f'), 97648, 70486, 62507, 15040563541741120241),
            ks(Character(b'a'), 94418, 62630, 62631, 13166747327335888811),
        ],
        CursorLeftDeleteCharacter,
    ));
}

/// Backspace on an empty line withdraws. The engine then dropped every
/// keystroke in flight, so the echo of the first "d" was matched to the
/// second, arming a run one cell behind the remote, and "a" was drawn where
/// the second "d" lands.
#[test]
fn echoes_of_dropped_keystrokes_do_not_arm_a_new_run() {
    expect_passes(case(
        vec![
            ks(Backspace, 2307225, 181125, 81375, 15060688257749113825),
            ks(Character(b's'), 93828, 90200, 129800, 12550267593603473558),
            ks(Character(b'd'), 173569, 106750, 68250, 4262448622762034288),
            ks(Character(b'd'), 109962, 112500, 112500, 10403133260724467383),
            ks(Character(b'a'), 125999, 98175, 94325, 16371842306727156016),
        ],
        CursorLeftDeleteCharacter,
    ));
}

/// The same misalignment from Backspace over echoed text followed by fast
/// typing, over bash's `\b\e[K`.
#[test]
fn backspace_over_echoed_text_then_typing_stays_aligned() {
    expect_passes(case(
        vec![
            ks(Character(b's'), 464991, 82596, 59812, 12520115931017865071),
            ks(Backspace, 518660, 54152, 52030, 16642402136693730543),
            ks(Character(b'a'), 91549, 59624, 79037, 15997237259192702023),
            ks(Character(b'j'), 117581, 61385, 84771, 9661113692231963010),
            ks(Character(b's'), 73487, 56663, 44522, 11641246956492036942),
            ks(Character(b's'), 88214, 56214, 68706, 2456294479701936419),
            ks(Character(b'a'), 103111, 64083, 78325, 16277613484114632174),
        ],
        BackspaceClearToEnd,
    ));
}

/// Backspace over the echoed "f" withdraws, and a remote that coalesces
/// typeahead sends nothing for "⌫f", whose net change is none. The echo of
/// the second "f" arrived after the untracked window and was matched to the
/// first, re-arming one cell behind the remote, so "d" was drawn right of
/// where it lands and stayed there until it expired.
#[test]
fn a_key_typed_while_echoes_are_untracked_does_not_arm_a_run() {
    let mut simulation_case = case(
        vec![
            ks(Character(b'f'), 245673, 30870, 42630, 2300655970432197423),
            ks(Backspace, 139067, 47124, 24276, 13452741299809415594),
            ks(Character(b'f'), 17750, 20384, 43316, 14211843459011219229),
            ks(Character(b'f'), 116774, 52542, 44758, 5850673420601723284),
            ks(Character(b'd'), 909700, 28980, 13020, 16764482466942078549),
        ],
        BackspaceClearToEnd,
    );
    simulation_case.coalesces_typeahead = true;
    expect_passes(simulation_case);
}

/// The link measures fast mid-run, so "j" is typed undrawn behind a held
/// "s". Removing "j" at its echo dropped a cell the cursor had passed, and
/// the held "s" slid onto the cell after it.
#[test]
fn a_held_glyph_keeps_its_cell_when_an_undrawn_echo_follows() {
    expect_passes(case(
        vec![
            ks(Character(b's'), 57475, 13398, 9702, 13857595088430517430),
            ks(Character(b'j'), 666034, 16638, 18762, 8691134027776269367),
            ks(Character(b'a'), 329636, 19323, 14577, 4221019582071791041),
            ks(Character(b's'), 6539567, 9792, 10608, 1270321287885520511),
            ks(Character(b's'), 18044, 8118, 11682, 17235541091325165141),
            ks(Character(b'j'), 60004, 9936, 11664, 5103199448813725791),
        ],
        CursorLeftDeleteCharacter,
    ));
}
