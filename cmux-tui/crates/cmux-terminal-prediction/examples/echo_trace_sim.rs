//! Keystroke-to-paint latency on recorded echoes, per link profile.
//!
//! `cargo run --release -p cmux-terminal-prediction --example echo_trace_sim -- TRACE...`
//!
//! `latency_sim` echoes each key as its own byte, as a bare shell does. The
//! programs people type into answer otherwise: a line editor with a colored
//! prompt, or an agent's TUI that redraws its input box. A trace is what one
//! program wrote back for each typed key, recorded in a pty
//! (`capture_echo.py`): one line of hex for everything before the first key,
//! then one line per key, `KEYHEX ECHOHEX`.
//!
//! Each trace is replayed on the link profiles of `cmux-fault/link-profiles.json`
//! (good-wifi, lte, lossy-3): a key is sent after 80..160 ms, its echo comes
//! back one round trip later plus 0..=jitter each way, a lost leg arrives one
//! retransmit timeout later (max(200 ms, 2 x rtt)), never reordered. The phone
//! presents a frame every 16.7 ms. A key is painted one frame after the overlay
//! first draws it (the engine said to redraw and its newest speculative glyph
//! is that key), else one frame after its echo arrives.
//!
//! Reported per row: key-to-paint p50, p95, max and the keys over 100 ms,
//! the share of keys predicted, visible withdrawals, the speculative glyphs
//! left once every echo is in (must be 0), and why the engine was not
//! predicting when a key was pressed (its `Status`).

use cmux_terminal_prediction::{
    PredictionConfiguration, Standing, Status, TerminalPredictionEngine,
};
use std::collections::BTreeMap;
use std::time::Duration;

const FRAME_US: u64 = 16_667;
const ROUNDS: u64 = 8;

struct Profile {
    name: &'static str,
    rtt_ms: u64,
    jitter_ms: u64,
    loss_per_mille: u64,
}

/// The rows of `cmux-tui/crates/cmux-fault/link-profiles.json` (version 1).
const PROFILES: [Profile; 3] = [
    Profile { name: "good-wifi@1", rtt_ms: 2, jitter_ms: 0, loss_per_mille: 0 },
    Profile { name: "lte@1", rtt_ms: 70, jitter_ms: 0, loss_per_mille: 5 },
    Profile { name: "lossy-3@1", rtt_ms: 70, jitter_ms: 300, loss_per_mille: 30 },
];

/// xorshift64*, so every run replays the same session.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn range(&mut self, low: u64, high: u64) -> u64 {
        low + self.next() % (high - low + 1)
    }
}

struct Trace {
    name: String,
    preamble: Vec<u8>,
    keys: Vec<(Vec<u8>, Vec<u8>)>,
}

fn unhex(text: &str) -> Vec<u8> {
    (0..text.len() / 2)
        .filter_map(|i| u8::from_str_radix(&text[2 * i..2 * i + 2], 16).ok())
        .collect()
}

fn load(path: &str) -> Trace {
    let text = std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{path}: {e}"));
    let mut lines = text.lines();
    let preamble = unhex(lines.next().unwrap_or_default().trim());
    let keys = lines
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            let mut parts = line.split_whitespace();
            (unhex(parts.next().unwrap_or_default()), unhex(parts.next().unwrap_or_default()))
        })
        .collect();
    let name = std::path::Path::new(path)
        .file_stem()
        .map_or_else(|| path.to_owned(), |s| s.to_string_lossy().into_owned());
    Trace { name, preamble, keys }
}

#[derive(Clone, Copy)]
enum Event {
    Key(usize),
    Echo(usize),
    Frame,
}

#[derive(Default)]
struct Row {
    paint_ms: Vec<f64>,
    predicted: usize,
    withdrawals: usize,
    left_over: usize,
    status: BTreeMap<&'static str, usize>,
}

fn status_name(status: Status) -> &'static str {
    match status {
        Status::Disabled => "disabled",
        Status::LocalSurface => "local",
        Status::Listening => "listening",
        Status::LinkIsFastEnough => "fast-link",
        Status::AlternateScreen => "alt-screen",
        Status::Suspended => "suspended",
        Status::Predicting => "predicting",
    }
}

fn us(time: u64) -> Duration {
    Duration::from_micros(time)
}

fn speculative(engine: &TerminalPredictionEngine) -> usize {
    engine.glyphs().iter().filter(|g| g.standing == Standing::Speculative).count()
}

fn replay(trace: &Trace, profile: &Profile, seed: u64, row: &mut Row) {
    let mut random = Random(seed | 1);
    let count = trace.keys.len();
    let mut typed_at = Vec::with_capacity(count);
    let mut echo_at = Vec::with_capacity(count);
    let mut clock: u64 = 2_000_000;
    let mut last_echo = 0;
    let retransmit = (profile.rtt_ms * 2_000).max(200_000);
    for _ in 0..count {
        clock += random.range(80_000, 160_000);
        let mut trip = profile.rtt_ms * 1_000;
        for _leg in 0..2 {
            if profile.jitter_ms > 0 {
                trip += random.range(0, profile.jitter_ms * 1_000) / 2;
            }
            while random.next() % 1000 < profile.loss_per_mille {
                trip += retransmit;
            }
        }
        let arrival = (clock + trip).max(last_echo + 1);
        last_echo = arrival;
        typed_at.push(clock);
        echo_at.push(arrival);
    }
    let mut events: Vec<(u64, u8, Event)> = Vec::new();
    for key in 0..count {
        events.push((typed_at[key], 1, Event::Key(key)));
        events.push((echo_at[key], 0, Event::Echo(key)));
    }
    let end = last_echo + 2_000_000;
    let mut frame = 1_000_000 + FRAME_US;
    while frame < end {
        events.push((frame, 2, Event::Frame));
        frame += FRAME_US;
    }
    events.sort_by_key(|&(time, order, _)| (time, order));

    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true);
    engine.observed_output(&trace.preamble, us(1_000_000));
    engine.presented_frame(us(1_000_000));
    let mut shown_at: Vec<Option<u64>> = vec![None; count];
    let debug = std::env::var_os("ECHO_SIM_DEBUG").is_some();
    let mut log: Vec<String> = Vec::new();
    for &(time, _, event) in &events {
        let before = speculative(&engine);
        let mut confirmed = 0;
        match event {
            Event::Key(key) => {
                let status = engine.status(us(time));
                if debug && key > 2 && status != Status::Predicting {
                    eprintln!(
                        "{} key {key} at {:.0} ms: {}; glyphs {:?}; last {:?}",
                        profile.name,
                        time as f64 / 1000.0,
                        status_name(status),
                        engine.glyphs(),
                        log.iter().rev().take(4).collect::<Vec<_>>()
                    );
                }
                log.push(format!("key {key} {:.0}", time as f64 / 1000.0));
                *row.status.entry(status_name(status)).or_default() += 1;
                let (bytes, _) = &trace.keys[key];
                if engine.sent(bytes, us(time)) {
                    let newest = engine.glyphs().last().copied();
                    if newest.is_some_and(|g| {
                        g.standing == Standing::Speculative
                            && bytes.len() == 1
                            && g.character == bytes[0]
                    }) {
                        shown_at[key] = Some(time);
                    }
                }
            }
            Event::Echo(key) => {
                log.push(format!(
                    "echo {key} {:.0} {:?}",
                    time as f64 / 1000.0,
                    String::from_utf8_lossy(&trace.keys[key].1)
                ));
                let after = {
                    engine.observed_output(&trace.keys[key].1, us(time));
                    speculative(&engine)
                };
                confirmed = before.saturating_sub(after).min(1);
                let _ = after;
            }
            Event::Frame => {
                engine.presented_frame(us(time));
            }
        }
        if speculative(&engine) + confirmed < before {
            row.withdrawals += 1;
        }
    }
    engine.tick(us(end));
    row.left_over += speculative(&engine);
    let frame_ms = FRAME_US as f64 / 1000.0;
    // A program that coalesces keys (an agent TUI's render throttle) paints a
    // key with the next echo that carries anything.
    let mut painted_by = echo_at.clone();
    for key in (0..count).rev() {
        if trace.keys[key].1.is_empty() && key + 1 < count {
            painted_by[key] = painted_by[key + 1];
        }
    }
    for key in 0..count {
        let painted = shown_at[key].map_or(painted_by[key], |shown| shown.min(painted_by[key]));
        row.paint_ms.push((painted - typed_at[key]) as f64 / 1000.0 + frame_ms);
        row.predicted += usize::from(shown_at[key].is_some());
    }
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

fn main() {
    let traces: Vec<Trace> = std::env::args().skip(1).map(|path| load(&path)).collect();
    if traces.is_empty() {
        eprintln!("usage: echo_trace_sim TRACE...");
        std::process::exit(2);
    }
    println!(
        "| program | link | keys | paint p50 ms | p95 | max | keys >100 ms | predicted | withdrawals | wrong left | status at key press |"
    );
    println!("|---|---|---|---|---|---|---|---|---|---|---|");
    for trace in &traces {
        for profile in &PROFILES {
            let mut row = Row::default();
            for round in 0..ROUNDS {
                replay(trace, profile, 0x5EED ^ (round << 8) ^ profile.rtt_ms, &mut row);
            }
            let mut sorted = row.paint_ms.clone();
            sorted.sort_by(f64::total_cmp);
            let over = sorted.iter().filter(|&&ms| ms > 100.0).count();
            let status = row
                .status
                .iter()
                .map(|(name, n)| format!("{name} {n}"))
                .collect::<Vec<_>>()
                .join(", ");
            println!(
                "| {} | {} | {} | {:.1} | {:.1} | {:.1} | {} | {:.0}% | {} | {} | {} |",
                trace.name,
                profile.name,
                sorted.len(),
                percentile(&sorted, 50.0),
                percentile(&sorted, 95.0),
                sorted[sorted.len() - 1],
                over,
                row.predicted as f64 * 100.0 / sorted.len() as f64,
                row.withdrawals,
                row.left_over,
                status
            );
        }
    }
}
