//! Port of classic cmux's `PredictionBreakDeleteTests.swift`.
//!
//! Leo's report: type fast, then Backspace, and characters he deleted are
//! back on screen. The engine retracts a speculative glyph at once, but the
//! remote still echoes that character and erases it a round trip later, and
//! nothing covers its cell in between. Backspace, Ctrl-U or Ctrl-W over
//! anything the remote already echoed withdraws every glyph still in flight,
//! and each of those echoes back too.

mod common;

use common::{PredictionBreakRig, RigKey, RigScript, SimulationRandom};

fn run(script: &RigScript) -> PredictionBreakRig {
    let mut rig = PredictionBreakRig::new(script.keystrokes.clone());
    rig.run();
    rig
}

fn expect_no_resurrection(rig: &PredictionBreakRig, label: &str) {
    assert!(rig.ever_drew_speculative, "{label}: never predicted, so the case proves nothing");
    let findings: Vec<String> = rig.resurrections.iter().take(6).map(ToString::to_string).collect();
    assert!(
        rig.resurrections.is_empty(),
        "{label}: deleted text shown again for {} ms in total\n{}",
        rig.resurrected_micros / 1000,
        findings.join("\n")
    );
}

/// 100 ms round trip. "s" is drawn at once and Backspace 40 ms later
/// retracts it. The echo of "s" lands 60 ms after that and ghostty paints
/// it; nothing covers it until the erase lands 40 ms later still.
#[test]
fn a_retracted_glyph_is_not_painted_again_by_its_own_echo() {
    let mut script = RigScript::new(100);
    script.arm();
    script.type_text("s");
    script.press_after(RigKey::Backspace, 40);
    expect_no_resurrection(&run(&script), "type s, Backspace 40 ms later");
}

/// A 20-key burst at 30 ms a key over 250 ms, then Backspace held at
/// key-repeat speed. The first Backspaces retract glyphs in flight; the
/// one that reaches an echoed glyph withdraws the rest; every in-flight
/// character then echoes back onto the line the user is deleting.
#[test]
fn holding_backspace_after_a_burst_does_not_regrow_the_line() {
    let mut script = RigScript::new(250);
    script.arm();
    script.type_text("abcdefghijklmnopqrst");
    script.hold(RigKey::Backspace, 20, 60);
    expect_no_resurrection(&run(&script), "20-key burst, hold Backspace");
}

/// Type, Backspace, retype while the first echo is still in flight.
#[test]
fn type_backspace_retype_mid_flight() {
    let mut script = RigScript::new(200);
    script.arm();
    script.type_text("gti");
    script.hold(RigKey::Backspace, 2, 40);
    script.type_text_after("it", 45);
    expect_no_resurrection(&run(&script), "gti ⌫⌫ it");
}

#[test]
fn ctrl_u_after_a_burst_does_not_bring_the_burst_back() {
    let mut script = RigScript::new(200);
    script.arm();
    script.type_text("git commit -m wip");
    script.press_after(RigKey::KillLine, 50);
    expect_no_resurrection(&run(&script), "burst then Ctrl-U");
}

#[test]
fn ctrl_w_after_a_burst_does_not_bring_the_word_back() {
    let mut script = RigScript::new(200);
    script.arm();
    script.type_text("git checkout mian");
    script.press_after(RigKey::KillWord, 50);
    expect_no_resurrection(&run(&script), "burst then Ctrl-W");
}

/// Typing, a paste, more typing, then Backspace back across the paste.
#[test]
fn backspace_across_a_paste_boundary() {
    let mut script = RigScript::new(200);
    script.arm();
    script.type_text("echo ");
    script.press_after(RigKey::Paste(b"PASTED".to_vec()), 40);
    script.type_text_after("tail", 40);
    script.hold(RigKey::Backspace, 12, 80);
    expect_no_resurrection(&run(&script), "type, paste, type, hold Backspace");
}

/// Backspace while earlier keystrokes are still unconfirmed, the mixed
/// case: some retracted, the next one lands on an echoed glyph.
#[test]
fn backspace_while_earlier_keystrokes_are_unconfirmed() {
    let mut script = RigScript::new(150);
    script.arm();
    script.type_text_after("abcdef", 40);
    script.hold_repeating(RigKey::Backspace, 4, 20, 60);
    expect_no_resurrection(&run(&script), "Backspace over a half-echoed burst");
}

/// The sweep behind the numbers in the report: 100 to 300 ms with
/// ±25% jitter, bursts of 20 to 50 keys, held Backspace.
#[test]
fn sweep_bursts_then_held_backspace_under_jitter() {
    let mut failing = 0;
    let mut total = 0;
    let mut worst_micros = 0;
    let mut worst_label = String::new();
    for round_trip in (100..=300).step_by(50) {
        for burst in [20_usize, 35, 50] {
            for seed in 1..=8_u64 {
                let mut script = RigScript::with_jitter(
                    round_trip,
                    round_trip / 4,
                    seed.wrapping_mul(7919).wrapping_add(burst as u64),
                );
                script.arm();
                let mut random = SimulationRandom::new(seed);
                for _ in 0..burst {
                    let byte = random.element(b"asdfjkl ");
                    let gap = random.int_in(25..=60);
                    script.press_after(RigKey::Character(byte), gap);
                }
                let initial_delay = random.int_in(20..=300);
                script.hold(RigKey::Backspace, burst, initial_delay);
                let rig = run(&script);
                total += 1;
                if let Some(first) = rig.resurrections.first() {
                    failing += 1;
                    if rig.resurrected_micros > worst_micros {
                        worst_micros = rig.resurrected_micros;
                        worst_label =
                            format!("rtt {round_trip} ms, burst {burst}, seed {seed}: {first}");
                    }
                }
            }
        }
    }
    assert_eq!(
        failing,
        0,
        "{failing}/{total} runs showed deleted text again; worst {} ms, {worst_label}",
        worst_micros / 1000
    );
}
