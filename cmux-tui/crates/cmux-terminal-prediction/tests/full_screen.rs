//! Prediction inside a full-screen application (`predict_in_full_screen_apps`):
//! each glyph is confirmed by the application printing it in its cell.

use cmux_terminal_prediction::{
    PredictionConfiguration, Standing, Status, TerminalPredictionEngine,
};
use std::time::Duration;

fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

/// The input box sits on row 30 (1-based); typing starts at column 3, after "> ".
const INPUT_ROW: usize = 30;
const INPUT_COLUMN: usize = 3;

/// An agent's TUI in the alternate screen: it echoes a key by moving to its
/// cell, printing it styled, and parking the cursor after it.
struct Tui {
    engine: TerminalPredictionEngine,
    clock: Duration,
    /// What the application has put in the input box so far.
    line: String,
}

impl Tui {
    fn with(predict_in_full_screen_apps: bool) -> Self {
        let configuration = PredictionConfiguration {
            predict_in_full_screen_apps,
            ..PredictionConfiguration::default()
        };
        let mut tui = Self {
            engine: TerminalPredictionEngine::new(configuration, true, true),
            clock: Duration::ZERO,
            line: String::new(),
        };
        tui.output("\x1b[?1049h\x1b[H\x1b[2J");
        tui.output(&format!("\x1b[{INPUT_ROW};1H> \x1b[{INPUT_ROW};{INPUT_COLUMN}H"));
        tui
    }

    fn new() -> Self {
        Self::with(true)
    }

    fn after(&mut self, step: u64) {
        self.clock += ms(step);
    }

    fn output(&mut self, text: &str) -> bool {
        self.engine.observed_output(text.as_bytes(), self.clock)
    }

    fn key(&mut self, key: u8) {
        self.after(10);
        self.engine.typed(Some(key), self.clock);
    }

    fn unmodelled_key(&mut self) {
        self.after(10);
        self.engine.typed(None, self.clock);
    }

    /// The application echoes the next character of the line, 70 ms later.
    fn echo(&mut self, key: u8) {
        self.after(70);
        let column = INPUT_COLUMN + self.line.len();
        self.line.push(char::from(key));
        let text = format!(
            "\x1b[{INPUT_ROW};{column}H\x1b[1m{}\x1b[0m\x1b[{INPUT_ROW};{}H",
            char::from(key),
            column + 1
        );
        self.output(&text);
    }

    /// The application takes a typed space: it prints nothing, the cell is
    /// blank already, and only parks the cursor past it.
    fn park_past_space(&mut self) {
        self.after(70);
        self.line.push(' ');
        let column = INPUT_COLUMN + self.line.len();
        self.output(&format!("\x1b[?25l\x1b[{INPUT_ROW};{column}H\x1b[?25h"));
    }

    /// A transcript line streams in above the input box, the cursor parked
    /// back after the input.
    fn stream(&mut self, row: usize, text: &str) {
        let back = INPUT_COLUMN + self.line.len();
        self.output(&format!("\x1b[{row};1H\x1b[2K{text}\x1b[{INPUT_ROW};{back}H"));
    }

    fn drawn(&self) -> String {
        self.engine
            .glyphs()
            .iter()
            .filter(|glyph| glyph.standing == Standing::Speculative)
            .map(|glyph| char::from(glyph.character))
            .collect()
    }

    fn status(&self) -> Status {
        self.engine.status(self.clock)
    }

    /// Two keys echoed in their cells arm the run.
    fn arm(&mut self) {
        for key in [b'h', b'i'] {
            self.key(key);
            self.echo(key);
        }
        self.after(20);
        self.engine.presented_frame(self.clock);
    }
}

#[test]
fn off_by_default_the_alternate_screen_withholds_prediction() {
    let mut tui = Tui::with(false);
    tui.arm();
    tui.key(b'x');
    assert_eq!(tui.status(), Status::AlternateScreen);
    assert_eq!(tui.drawn(), "");
}

#[test]
fn two_keys_echoed_in_their_cells_arm_and_the_next_key_draws_at_once() {
    let mut tui = Tui::new();
    tui.key(b'h');
    assert_eq!(tui.drawn(), "", "nothing before an echo was seen");
    tui.echo(b'h');
    tui.key(b'i');
    assert_eq!(tui.drawn(), "", "one echo is not a run");
    tui.echo(b'i');
    assert_eq!(tui.status(), Status::Predicting);
    tui.key(b'x');
    tui.key(b'y');
    assert_eq!(tui.drawn(), "xy");
    let glyphs = tui.engine.glyphs();
    assert_eq!(glyphs.iter().map(|g| g.offset).collect::<Vec<_>>(), [0, 1]);
}

#[test]
fn an_echo_in_its_cell_confirms_and_the_next_frame_retires_it() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    tui.echo(b'x');
    let glyphs = tui.engine.glyphs();
    assert_eq!(glyphs.len(), 1);
    assert_eq!(glyphs[0].standing, Standing::Confirmed);
    assert_eq!(glyphs[0].offset, -1, "over the cell the echo landed in");
    tui.after(16);
    tui.engine.presented_frame(tui.clock);
    assert!(tui.engine.glyphs().is_empty());
}

#[test]
fn output_streaming_elsewhere_keeps_the_prediction_and_the_run() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    for row in 2..20 {
        tui.after(5);
        tui.stream(row, "Thinking about the lag on LTE...");
    }
    assert_eq!(tui.drawn(), "x");
    tui.echo(b'x');
    tui.key(b'y');
    assert_eq!(tui.drawn(), "y");
}

#[test]
fn a_different_character_in_the_cell_withdraws_and_disarms() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    assert_eq!(tui.drawn(), "x");
    tui.after(70);
    // The application put something else where `x` was predicted.
    let column = INPUT_COLUMN + tui.line.len();
    tui.output(&format!("\x1b[{INPUT_ROW};{column}HQ"));
    assert_eq!(tui.drawn(), "");
    assert_eq!(tui.status(), Status::Listening);
    tui.key(b'y');
    assert_eq!(tui.drawn(), "", "never predicts right after a mismatch");
}

#[test]
fn a_blank_repainted_in_the_cell_is_an_older_frame_not_a_mismatch() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    tui.after(30);
    let column = INPUT_COLUMN + tui.line.len();
    tui.output(&format!("\x1b[{INPUT_ROW};{column}H   \x1b[{INPUT_ROW};{column}H"));
    assert_eq!(tui.drawn(), "x");
    tui.echo(b'x');
    assert_eq!(tui.status(), Status::Predicting);
}

#[test]
fn an_application_that_does_not_echo_never_sees_a_glyph() {
    let mut tui = Tui::new();
    // A password field, or vim's normal mode: keys go in, nothing prints there.
    for key in b"secret" {
        tui.key(*key);
        assert_eq!(tui.drawn(), "");
        tui.after(70);
        tui.stream(5, "Password:");
    }
    tui.after(2000);
    tui.engine.tick(tui.clock);
    assert_eq!(tui.status(), Status::Listening);
}

#[test]
fn an_unmodelled_key_withdraws_and_waits_for_a_fresh_echo() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    assert_eq!(tui.drawn(), "x");
    tui.unmodelled_key();
    assert_eq!(tui.drawn(), "");
    tui.echo(b'x');
    tui.key(b'y');
    assert_eq!(tui.drawn(), "", "one confirmation first");
    tui.echo(b'y');
    tui.key(b'z');
    assert_eq!(tui.drawn(), "z");
}

#[test]
fn a_cursor_parked_off_the_row_hides_the_overlay_until_it_returns() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    tui.after(5);
    tui.output("\x1b[3;40H");
    assert_eq!(tui.drawn(), "");
    tui.after(5);
    let back = INPUT_COLUMN + tui.line.len();
    tui.output(&format!("\x1b[{INPUT_ROW};{back}H"));
    assert_eq!(tui.drawn(), "x");
}

#[test]
fn an_unconfirmed_glyph_expires() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    tui.after(1600);
    tui.engine.tick(tui.clock);
    assert_eq!(tui.drawn(), "");
    assert_eq!(tui.status(), Status::Listening);
}

#[test]
fn leaving_the_alternate_screen_mid_chunk_drops_every_cell_prediction() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    tui.after(30);
    tui.output("\x1b[?1049l$ ");
    assert!(tui.engine.glyphs().is_empty());
    assert_ne!(tui.status(), Status::AlternateScreen);
}

#[test]
fn a_fast_link_draws_nothing() {
    let mut tui = Tui::new();
    for key in b"hello" {
        tui.key(*key);
        tui.after(2);
        let column = INPUT_COLUMN + tui.line.len();
        tui.line.push(char::from(*key));
        tui.output(&format!("\x1b[{INPUT_ROW};{column}H{}", char::from(*key)));
    }
    assert_eq!(tui.status(), Status::LinkIsFastEnough);
    tui.key(b'x');
    assert_eq!(tui.drawn(), "");
}

#[test]
fn a_resize_drops_the_run() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    tui.engine.layout_changed(tui.clock);
    assert_eq!(tui.drawn(), "");
    tui.key(b'y');
    assert_eq!(tui.drawn(), "");
}

/// xorshift64*, so every run replays the same sessions.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, bound: u64) -> u64 {
        self.next() % bound
    }
}

/// Many sessions: keys typed while the application streams output, redraws
/// stale frames, and echoes late and in batches. At every instant each drawn
/// speculative glyph must be the character the application ends up printing
/// in that cell, and once every echo is in, nothing speculative is left.
#[test]
fn no_wrong_character_is_ever_drawn_or_left() {
    let text = b"fix the lag when typing on lte now please";
    for seed in 1..=300u64 {
        let mut random = Random(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let mut tui = Tui::new();
        let mut sent = 0;
        let mut echoed = 0;
        while echoed < text.len() {
            match random.below(6) {
                0 | 1 if sent < text.len() => {
                    tui.key(text[sent]);
                    sent += 1;
                }
                2 if echoed < sent => {
                    // Echo one or several keys at once.
                    let batch = 1 + random.below((sent - echoed) as u64) as usize;
                    for _ in 0..batch {
                        tui.echo(text[echoed]);
                        echoed += 1;
                    }
                }
                3 => {
                    tui.after(random.below(40));
                    tui.stream(2 + random.below(20) as usize, "streaming a long answer");
                }
                4 => {
                    // A stale frame repaints the input box as it was, blanks after it.
                    tui.after(random.below(30));
                    let row = INPUT_ROW;
                    let line = tui.line.clone();
                    tui.output(&format!(
                        "\x1b[{row};1H> {line}\x1b[K\x1b[{row};{}H",
                        INPUT_COLUMN + line.len()
                    ));
                }
                _ => {
                    tui.after(random.below(20));
                    tui.engine.presented_frame(tui.clock);
                }
            }
            // The cursor sits after what the application printed; offsets
            // are from it, so a glyph at offset o is text[line.len() + o].
            let base = tui.line.len() as i32;
            for glyph in tui.engine.glyphs() {
                if glyph.standing != Standing::Speculative {
                    continue;
                }
                let index =
                    usize::try_from(base + glyph.offset).expect("a glyph left of the input");
                assert_eq!(
                    Some(&glyph.character),
                    text.get(index),
                    "seed {seed}: wrong glyph at offset {}",
                    glyph.offset
                );
            }
        }
        tui.after(500);
        tui.engine.presented_frame(tui.clock);
        let left =
            tui.engine.glyphs().iter().filter(|g| g.standing == Standing::Speculative).count();
        assert_eq!(left, 0, "seed {seed}: speculative glyphs left");
    }
}

#[test]
fn a_space_the_application_only_moves_past_keeps_the_run() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b' ');
    tui.key(b'x');
    assert_eq!(tui.drawn(), " x");
    tui.park_past_space();
    assert_eq!(tui.drawn(), "x", "the space is settled by the cursor moving past it");
    tui.echo(b'x');
    assert_eq!(tui.drawn(), "");
    tui.after(2000);
    assert_eq!(tui.status(), Status::Predicting, "no space expired the run");
    tui.key(b' ');
    tui.key(b'y');
    tui.after(70);
    // Both arrive in one batch: the space never printed, y in the cell after.
    let column = INPUT_COLUMN + tui.line.len() + 1;
    tui.line.push_str(" y");
    tui.output(&format!("\x1b[{INPUT_ROW};{column}Hy\x1b[{INPUT_ROW};{}H", column + 1));
    assert_eq!(tui.drawn(), "");
    tui.after(2000);
    assert_eq!(tui.status(), Status::Predicting);
}

#[test]
fn the_frame_that_enters_the_screen_places_keys_typed_ahead_of_their_echo() {
    let configuration = PredictionConfiguration {
        predict_in_full_screen_apps: true,
        ..PredictionConfiguration::default()
    };
    let mut engine = TerminalPredictionEngine::new(configuration, true, true);
    // One chunk: enter the screen, draw the box, park the cursor in it.
    engine.observed_output(b"\x1b[?1049h\x1b[H\x1b[2J\x1b[30;1H> \x1b[30;3H", ms(0));
    // Four keys go out before the first echo is back (a slow, lossy link).
    for (i, key) in b"abcd".iter().enumerate() {
        engine.typed(Some(*key), ms(10 + 10 * i as u64));
    }
    for (i, key) in b"abcd".iter().enumerate() {
        let column = 3 + i;
        let echo = format!("\x1b[30;{column}H{}\x1b[30;{}H", char::from(*key), column + 1);
        engine.observed_output(echo.as_bytes(), ms(300 + 10 * i as u64));
    }
    engine.typed(Some(b'e'), ms(400));
    assert_eq!(engine.status(ms(400)), Status::Predicting, "every key confirmed in its cell");
    assert_eq!(engine.glyphs().len(), 1);
}

#[test]
fn turning_the_setting_off_takes_what_is_drawn_and_on_starts_unarmed() {
    let mut tui = Tui::new();
    tui.arm();
    tui.key(b'x');
    assert_eq!(tui.drawn(), "x");
    assert!(tui.engine.set_predicts_in_full_screen_apps(false), "a drawn glyph went");
    assert_eq!(tui.drawn(), "");
    assert_eq!(tui.status(), Status::AlternateScreen);
    assert!(!tui.engine.set_predicts_in_full_screen_apps(true));
    assert_eq!(tui.status(), Status::Listening, "two fresh echoes before drawing again");
}
