//! Port of classic cmux's `PredictionBreakSecretTests.swift`
//! (`PredictionBreakSecretTests` and `PredictionBreakShellTests`).

use cmux_terminal_prediction::{
    PredictionConfiguration, Standing, Status, TerminalPredictionEngine,
};
use std::time::Duration;

fn ms(milliseconds: u64) -> Duration {
    Duration::from_millis(milliseconds)
}

/// Drives one engine with explicit millisecond timestamps.
struct Clocked {
    engine: TerminalPredictionEngine,
}

impl Clocked {
    fn new() -> Self {
        Self {
            engine: TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true),
        }
    }

    fn key(&mut self, text: &str, at: u64) {
        if text == "\r" {
            self.engine.typed(None, ms(at));
            return;
        }
        for byte in text.bytes() {
            self.engine.typed(Some(byte), ms(at));
        }
    }

    fn out(&mut self, text: &str, at: u64) {
        self.engine.observed_output(text.as_bytes(), ms(at));
    }

    fn frame(&mut self, at: u64) {
        self.engine.presented_frame(ms(at));
    }

    fn drawn(&self) -> String {
        self.engine
            .glyphs()
            .iter()
            .filter(|glyph| glyph.standing == Standing::Speculative)
            .map(|glyph| char::from(glyph.character))
            .collect()
    }
}

/// Type-ahead into a password prompt. `ssh host` (or `sudo`, `git push`
/// over https) takes a moment to ask; meanwhile the tty is still in
/// cooked mode, so it echoes the first key typed ahead. That echo arms the
/// run. readpassphrase() then turns echo off (TCSAFLUSH) and prints its
/// prompt, but every key typed between the arm and the prompt's arrival
/// is drawn in clear, though the remote never shows it.
#[test]
fn type_ahead_into_a_password_prompt_is_not_drawn() {
    let mut s = Clocked::new();
    // A slow link, measured: 200 ms round trip.
    s.key("l", 0);
    s.out("l", 200);
    s.frame(210);
    s.key("\r", 1_000);
    s.out("\r\n", 1_200); // the shell runs `ssh host`, which is connecting
    // 1.5 s later the user starts typing the password ahead of the prompt.
    s.key("h", 2_500);
    s.out("h", 2_700); // cooked-mode tty echo: the run arms
    s.frame(2_710);
    for (index, character) in "unter2".chars().enumerate() {
        s.key(&character.to_string(), 2_720 + index as u64 * 40);
    }
    // ssh turned echo off at 2 650 remote time; its prompt is still in flight.
    let drawn = s.drawn();
    assert!(
        drawn.is_empty(),
        "password characters drawn in clear before the prompt arrived: \"{drawn}\""
    );
}

/// sudo with `pwfeedback`, npm/inquirer and most TUI prompts mask each
/// key as `*`. A password character that is itself `*` matches its own
/// masked echo, arms the run, and the characters after it are drawn in
/// clear until the next mask comes back.
#[test]
fn a_masked_prompt_never_arms_on_the_mask() {
    let mut s = Clocked::new();
    s.key("l", 0);
    s.out("l", 200);
    s.frame(210);
    s.key("\r", 1_000);
    s.out("\r\n[sudo] password for leo: ", 1_200);
    s.key("*", 2_000);
    s.out("*", 2_200);
    s.frame(2_210);
    for (index, character) in "hunter2".chars().enumerate() {
        s.key(&character.to_string(), 2_250 + index as u64 * 40);
    }
    let drawn = s.drawn();
    assert!(drawn.is_empty(), "password characters drawn in clear: \"{drawn}\"");
}

// PredictionBreakShellTests

/// fish, and zsh with zsh-autosuggestions, print the suggestion after
/// every key in a dim colour and move the cursor back over it. The
/// cursor move withdraws everything drawn as a misprediction, so a few
/// commands suspend prediction for 30 s. fish does this by default.
#[test]
fn autosuggestions_do_not_suspend_prediction() {
    let mut s = Clocked::new();
    s.key("x", 0);
    s.out("x", 150);
    s.frame(160);
    s.key("\r", 400);
    s.out("\r\n> ", 550);
    let mut t: u64 = 1_300;
    let commands =
        [("ls", "s -la"), ("cd", "d src"), ("git", "it status"), ("ls", "s -la"), ("cd", "d src")];
    for (command, suggestion) in commands {
        let first = &command[..1];
        let rest = &command[1..];
        s.key(first, t);
        s.out(
            &format!("{first}\x1b[90m{}\x1b[0m\x1b[{}D", &suggestion[1..], suggestion.len() - 1),
            t + 150,
        );
        s.frame(t + 160);
        for (index, character) in rest.chars().enumerate() {
            s.key(&character.to_string(), t + 200 + index as u64 * 60);
        }
        t += 200 + command.len() as u64 * 60;
        s.out(rest, t + 150);
        s.key("\r", t + 300);
        s.out("\r\n> ", t + 450);
        t += 1_200;
    }
    assert_ne!(
        s.engine.status(ms(t)),
        Status::Suspended,
        "autosuggestions suspended prediction by {t} ms"
    );
}

/// tmux or screen with a status-line clock repaints it every second with
/// a cursor save, move and restore. Each repaint withdraws what is drawn
/// as a misprediction, and continuous typing never re-arms. (tmux also
/// uses the alternate screen, which turns prediction off outright; this is
/// the non-alternate-screen case: a shell prompt clock, `screen` with
/// altscreen off, an async prompt segment.)
#[test]
fn a_one_second_status_repaint_does_not_stop_prediction() {
    let mut s = Clocked::new();
    s.key("x", 0);
    s.out("x", 150);
    s.frame(160);
    let mut drawn_keys = 0;
    let text = b"the quick brown fox jumps over the lazy dog ";
    let mut events: Vec<(u64, u8, String)> = Vec::new();
    for index in 0..80_u64 {
        let t = 1_000 + index * 110;
        let character = char::from(text[(index % 44) as usize]).to_string();
        events.push((t, 1, character.clone()));
        events.push((t + 150, 0, character));
    }
    for second in 1..=9_u64 {
        events.push((second * 1_000 + 500, 0, format!("\x1b7\x1b[24;70H12:0{second}\x1b8")));
    }
    events.sort_by_key(|&(t, kind, _)| (t, kind));
    for (t, kind, text) in &events {
        if *kind == 1 {
            s.key(text, *t);
            if s.engine.glyphs().last().is_some_and(|glyph| glyph.standing == Standing::Speculative)
            {
                drawn_keys += 1;
            }
        } else {
            s.out(text, *t);
        }
        s.frame(t + 8);
    }
    let final_status = s.engine.status(ms(10_000));
    assert!(
        drawn_keys > 40,
        "only {drawn_keys}/80 keys drawn with a 1 s status repaint; status {final_status:?}"
    );
}
