//! Port of classic cmux's `PredictionBreakEngineTests.swift`
//! (`PredictionBreakEngineTests` and `PredictionBreakLatencyTests`).

mod common;

use cmux_terminal_prediction::{
    PredictionConfiguration, Standing, Status, TerminalPredictionEngine,
};
use common::SimulationRandom;
use std::time::Duration;

fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

fn engine() -> TerminalPredictionEngine {
    TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true)
}

/// Engine instants cannot be negative, and the Swift cases arm the engine
/// before their time zero. The engine only compares instants with each
/// other, so these cases shift every instant by the same origin.
fn shifted(milliseconds: i64, origin: i64) -> Duration {
    Duration::from_millis(u64::try_from(milliseconds + origin).expect("after the origin"))
}

fn has_speculative(engine: &TerminalPredictionEngine) -> bool {
    engine.glyphs().iter().any(|glyph| glyph.standing == Standing::Speculative)
}

struct Session {
    engine: TerminalPredictionEngine,
    clock: Duration,
}

impl Session {
    fn new() -> Self {
        Self { engine: engine(), clock: Duration::ZERO }
    }

    fn at(&mut self, milliseconds: u64) {
        self.clock = ms(milliseconds);
    }

    fn type_byte(&mut self, byte: u8, milliseconds: u64) {
        self.at(milliseconds);
        self.engine.typed(Some(byte), self.clock);
    }

    fn remote(&mut self, text: &str, milliseconds: u64) {
        self.at(milliseconds);
        self.engine.observed_output(text.as_bytes(), self.clock);
    }

    fn drawn(&self) -> String {
        self.engine.glyphs().iter().map(|glyph| char::from(glyph.character)).collect()
    }
}

/// A 1.3 s link with ±400 ms jitter (a congested satellite or mobile link), the latency where prediction matters
/// most. `speculativeLifetime` is a fixed 1.5 s, so every late echo
/// withdraws what the user saw, counts as a misprediction, and four of
/// them suspend prediction for 30 s.
#[test]
fn a_slow_jittery_link_keeps_predicting() {
    const ORIGIN: i64 = 3_000;
    let instant = |milliseconds: i64| shifted(milliseconds, ORIGIN);
    let mut engine = engine();
    let mut random = SimulationRandom::new(42);
    let mut events: Vec<(i64, bool, u8)> = Vec::new(); // (time ms, isEcho, byte)
    let mut typed_at = 0;
    let mut last_echo = 0;
    let text = b"git log --oneline --graph --decorate --all | head -40";
    for &byte in text {
        typed_at += random.int_in(60..=160);
        let echo = i64::max(last_echo, typed_at + 1_300 + random.int_in(-400..=400));
        last_echo = echo;
        events.push((typed_at, false, byte));
        events.push((echo, true, byte));
    }
    // Arm first: one echoed key well before.
    engine.typed(Some(b'x'), instant(-3_000));
    engine.observed_output(b"x", instant(-1_800));
    engine.presented_frame(instant(-1_790));
    let mut suspended_at: Option<i64> = None;
    let mut withdrawn_visible = 0;
    let mut drawn_keys = 0;
    events.sort_by_key(|&(time, is_echo, _)| (time, if is_echo { 0 } else { 1 }));
    for (time, is_echo, byte) in events {
        let now = instant(time);
        let before = has_speculative(&engine);
        if is_echo {
            engine.observed_output(&[byte], now);
        } else {
            engine.typed(Some(byte), now);
            let glyphs = engine.glyphs();
            if let Some(last) = glyphs.last()
                && last.standing == Standing::Speculative
                && Some(last.offset) == glyphs.iter().map(|glyph| glyph.offset).max()
            {
                drawn_keys += 1;
            }
        }
        engine.presented_frame(now + ms(8));
        if before && !has_speculative(&engine) && !is_echo {
            withdrawn_visible += 1;
        }
        if suspended_at.is_none() && engine.status(now) == Status::Suspended {
            suspended_at = Some(time);
        }
    }
    assert!(
        drawn_keys * 2 >= text.len(),
        "only {drawn_keys} of {} keys were drawn at typing time; {withdrawn_visible} visible withdrawals",
        text.len()
    );
    assert!(
        suspended_at.is_none(),
        "suspended at {} after {withdrawn_visible} visible withdrawals, over a link that never lost a byte",
        suspended_at.map_or_else(|| "-".to_owned(), |time| format!("{time} ms"))
    );
}

/// zsh-syntax-highlighting recolours a word once it names a command:
/// typing the "s" of "ls" makes zle move back over "l" and rewrite "ls"
/// in the new colour. The move back withdraws the drawn "s" as a
/// misprediction, so four commands in ten seconds suspend prediction for
/// thirty.
#[test]
fn zsh_syntax_highlighting_does_not_suspend_prediction() {
    let mut session = Session::new();
    session.type_byte(b'x', 0);
    session.remote("x", 150);
    session.type_byte(0x0D, 400); // Return withdraws
    session.remote("\r\n$ ", 550);
    let mut t = 1_000;
    for command in ["ls", "cd", "ls", "vi", "ls", "cd"] {
        let bytes = command.as_bytes();
        // First key: echoed red, no move.
        session.type_byte(bytes[0], t);
        session.remote(&format!("\x1b[31m{}\x1b[39m", &command[..1]), t + 150);
        t += 200;
        // Second key completes a command: zle moves back one and rewrites.
        session.type_byte(bytes[1], t);
        session.remote(&format!("\x08\x1b[32m{command}\x1b[39m"), t + 150);
        t += 200;
        session.type_byte(0x0D, t);
        session.remote("\r\n$ ", t + 150);
        t += 900;
    }
    assert_ne!(
        session.engine.status(session.clock),
        Status::Suspended,
        "zsh-syntax-highlighting suspended prediction by {:?}",
        session.clock
    );
}

/// A kitty graphics placement (APC) or a sixel image (DCS) moves the
/// cursor, but the scanner classifies every string sequence as
/// ignorable, so glyphs keep offsets measured from the old cursor and the
/// host draws them wherever the image left it.
#[test]
fn an_image_that_moves_the_cursor_withdraws_predictions() {
    let mut session = Session::new();
    session.type_byte(b'k', 0);
    session.remote("k", 150);
    session.type_byte(b'l', 200);
    session.remote("l", 350);
    session.type_byte(b's', 400);
    assert_eq!(session.drawn(), "s");
    // An async job (a prompt segment, `kitten icat` in the background)
    // places a 1x4-cell image at the cursor; kitty moves the cursor past it.
    session.remote("\x1b_Ga=T,f=100,c=4,r=1;iVBORw0KGgo=\x1b\\", 450);
    assert_eq!(session.drawn(), "", "'s' is still drawn after an image moved the cursor 4 cells");
    // Sixel: the cursor ends up below the image.
    let mut sixel = Session::new();
    sixel.type_byte(b'k', 0);
    sixel.remote("k", 150);
    sixel.type_byte(b'l', 200);
    sixel.remote("l", 350);
    sixel.type_byte(b's', 400);
    sixel.remote("\x1bPq#0;2;0;0;0#0~~~~-~~~~\x1b\\", 450);
    assert_eq!(sixel.drawn(), "", "'s' is still drawn after a sixel image moved the cursor");
}

// PredictionBreakLatencyTests

/// Typing steadily over a constant link, report how many keys were
/// drawn when typed and whether prediction suspended itself.
fn steady_typing(round_trip: i64, keys: i64, gap: i64) -> (usize, bool) {
    const ORIGIN: i64 = 10_000;
    let instant = |milliseconds: i64| shifted(milliseconds, ORIGIN);
    let mut engine = engine();
    for (index, &byte) in b"xy".iter().enumerate() {
        let typed_at = -10_000 + index as i64 * 3_000;
        engine.typed(Some(byte), instant(typed_at));
        engine.observed_output(&[byte], instant(typed_at + round_trip));
        engine.presented_frame(instant(typed_at + round_trip + 8));
    }
    let mut events: Vec<(i64, u8, u8)> = Vec::new(); // time, 0 = echo first, byte
    for index in 0..keys {
        let byte = b'a' + (index % 26) as u8;
        events.push((index * gap, 1, byte));
        events.push((index * gap + round_trip, 0, byte));
    }
    let mut drawn = 0;
    let mut suspended = false;
    events.sort_by_key(|&(time, kind, _)| (time, kind));
    for (time, kind, byte) in events {
        let now = instant(time);
        if kind == 0 {
            engine.observed_output(&[byte], now);
        } else {
            engine.typed(Some(byte), now);
            if engine
                .glyphs()
                .iter()
                .any(|glyph| glyph.standing == Standing::Speculative && glyph.character == byte)
            {
                drawn += 1;
            }
        }
        engine.presented_frame(now + ms(8));
        if engine.status(now) == Status::Suspended {
            suspended = true;
        }
    }
    (drawn, suspended)
}

/// `speculativeLifetime` is a fixed 1.5 s. Past that round trip every
/// keystroke expires before its echo arrives, so no echo ever matches,
/// the run never arms, and the links that need prediction most get none.
#[test]
fn a_round_trip_longer_than_the_lifetime_still_predicts() {
    let (drawn, suspended) = steady_typing(1_600, 60, 120);
    assert!(drawn > 40 && !suspended, "1.6 s link: {drawn}/60 drawn, suspended {suspended}");
}

#[test]
fn a_second_round_trip_predicts_every_key() {
    let (drawn, _) = steady_typing(1_000, 60, 120);
    assert!(drawn > 55, "1.0 s link: {drawn}/60 drawn");
}

/// One late echo (a 2 s stall on a 300 ms link) withdraws. Every key
/// typed within the untracked-echo window pushes the window out again,
/// so while the user keeps typing, nothing is drawn for the rest of the
/// line.
#[test]
fn one_stall_does_not_turn_prediction_off_until_the_user_pauses() {
    let mut engine = engine();
    engine.typed(Some(b'x'), Duration::ZERO);
    engine.observed_output(b"x", ms(300));
    engine.presented_frame(ms(308));
    let mut events: Vec<(u64, u8, u8)> = Vec::new();
    for index in 0..40_u64 {
        let typed_at = 1_000 + index * 120;
        // The fifth key's echo stalls 2 s; everything behind it queues.
        let echo_at = if index < 4 {
            typed_at + 300
        } else {
            u64::max(1_000 + 4 * 120 + 2_300, typed_at + 300)
        };
        let byte = b'a' + (index % 26) as u8;
        events.push((typed_at, 1, byte));
        events.push((echo_at, 0, byte));
    }
    let mut drawn_after_stall = 0;
    events.sort_by_key(|&(time, kind, _)| (time, kind));
    for (time, kind, byte) in events {
        let now = ms(time);
        if kind == 0 {
            engine.observed_output(&[byte], now);
        } else {
            engine.typed(Some(byte), now);
            if time > 4_500 && has_speculative(&engine) {
                drawn_after_stall += 1;
            }
        }
        engine.presented_frame(now + ms(8));
    }
    assert!(
        drawn_after_stall > 0,
        "no key typed after the stall cleared (from 3.8 s to 5.7 s) was drawn"
    );
}
