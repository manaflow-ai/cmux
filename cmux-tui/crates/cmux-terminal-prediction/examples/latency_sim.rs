//! Keystroke-to-glyph latency with and without prediction, on a virtual clock,
//! and the engine's real CPU cost per call.
//!
//! `cargo run --release -p cmux-terminal-prediction --example latency_sim`
//!
//! A shell prompt echoes every byte after one round trip (half up, half
//! down, plus uniform jitter, never reordered). Each leg is lost with the
//! given probability and then arrives one retransmit timeout later
//! (max(200 ms, 2 x rtt)), holding the echoes behind it, as one in-order
//! stream does. 200 printable keystrokes
//! arrive about every 120 ms (uniform 80..160 ms, a space every 4 to 8
//! letters), and the host presents a frame every 16.7 ms. A glyph counts as
//! visible one frame (16.7 ms) after it is first on screen:
//!
//! - no prediction: after its echo reaches the host;
//! - prediction: after the overlay first shows it (the engine said to redraw
//!   and the newest glyph is that keystroke's), or after its echo when the
//!   overlay never showed it.
//!
//! A visible withdrawal is an event after which fewer speculative glyphs are
//! drawn than before, beyond the ones that event's echo confirmed.

use cmux_terminal_prediction::ffi::{
    cmux_terminal_prediction_free, cmux_terminal_prediction_new, cmux_terminal_prediction_output,
    cmux_terminal_prediction_presented_frame, cmux_terminal_prediction_sent,
};
use cmux_terminal_prediction::{PredictionConfiguration, Standing, TerminalPredictionEngine};
use std::time::{Duration, Instant};

const FRAME_US: u64 = 16_667;
const KEYS: usize = 200;

/// xorshift64*, so every run replays the same session.
struct Random(u64);

impl Random {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    /// Uniform in `low..=high`.
    fn range(&mut self, low: i64, high: i64) -> i64 {
        let span = u64::try_from(high - low + 1).unwrap_or(1);
        low + i64::try_from(self.next() % span).unwrap_or(0)
    }
}

#[derive(Clone, Copy)]
enum Event {
    Key(usize),
    Echo(usize),
    Frame,
}

struct Outcome {
    without: Vec<f64>,
    with: Vec<f64>,
    predicted: usize,
    withdrawals: usize,
}

fn us(time: u64) -> Duration {
    Duration::from_micros(time)
}

fn speculative_count(engine: &TerminalPredictionEngine) -> usize {
    engine.glyphs().iter().filter(|g| g.standing == Standing::Speculative).count()
}

fn simulate(rtt_ms: i64, jitter_ms: i64, loss_percent: u64, seed: u64) -> Outcome {
    let mut random = Random(seed);
    let mut typed_at = Vec::with_capacity(KEYS);
    let mut bytes = Vec::with_capacity(KEYS);
    let mut echo_at = Vec::with_capacity(KEYS);
    let mut clock: u64 = 1_000_000;
    let mut word_left = random.range(4, 8);
    let mut last_echo: u64 = 0;
    for _ in 0..KEYS {
        clock += u64::try_from(random.range(80_000, 160_000)).unwrap_or(120_000);
        let byte = if word_left == 0 {
            word_left = random.range(4, 8);
            b' '
        } else {
            word_left -= 1;
            b'a' + u8::try_from(random.range(0, 25)).unwrap_or(0)
        };
        let mut trip =
            (rtt_ms * 1000 + random.range(-jitter_ms * 1000, jitter_ms * 1000)).max(1000);
        let retransmit = (rtt_ms * 2000).max(200_000);
        for _leg in 0..2 {
            while random.next() % 100 < loss_percent {
                trip += retransmit;
            }
        }
        // The remote reads and replies in order: an echo never overtakes the
        // one before it.
        let arrival = (clock + u64::try_from(trip).unwrap_or(0)).max(last_echo + 1);
        last_echo = arrival;
        typed_at.push(clock);
        bytes.push(byte);
        echo_at.push(arrival);
    }

    let mut events: Vec<(u64, u8, Event)> = Vec::new();
    for key in 0..KEYS {
        events.push((typed_at[key], 1, Event::Key(key)));
        events.push((echo_at[key], 0, Event::Echo(key)));
    }
    let end = last_echo + 2_000_000;
    let mut frame = FRAME_US;
    while frame < end {
        events.push((frame, 2, Event::Frame));
        frame += FRAME_US;
    }
    events.sort_by_key(|&(time, order, _)| (time, order));

    let mut engine = TerminalPredictionEngine::new(PredictionConfiguration::default(), true, true);
    let mut shown_at: Vec<Option<u64>> = vec![None; KEYS];
    let mut withdrawals = 0;
    for &(time, _, event) in &events {
        let before = speculative_count(&engine);
        let confirmed = match event {
            Event::Key(key) => {
                if engine.typed(Some(bytes[key]), us(time)) {
                    let newest = engine.glyphs().last().copied();
                    if newest.is_some_and(|g| {
                        g.standing == Standing::Speculative && g.character == bytes[key]
                    }) {
                        shown_at[key] = Some(time);
                    }
                }
                0
            }
            Event::Echo(key) => {
                engine.observed_output(&[bytes[key]], us(time));
                1
            }
            Event::Frame => {
                engine.presented_frame(us(time));
                0
            }
        };
        if speculative_count(&engine) + confirmed < before {
            withdrawals += 1;
        }
    }

    let frame = FRAME_US as f64 / 1000.0;
    let ms = |from: u64, to: u64| (to - from) as f64 / 1000.0 + frame;
    let without: Vec<f64> = (0..KEYS).map(|k| ms(typed_at[k], echo_at[k])).collect();
    let with: Vec<f64> = (0..KEYS)
        .map(|k| ms(typed_at[k], shown_at[k].unwrap_or(echo_at[k]).min(echo_at[k])))
        .collect();
    Outcome {
        without,
        with,
        predicted: shown_at.iter().filter(|s| s.is_some()).count(),
        withdrawals,
    }
}

fn percentile(sorted: &[f64], p: f64) -> f64 {
    let rank = ((p / 100.0) * sorted.len() as f64).ceil() as usize;
    sorted[rank.clamp(1, sorted.len()) - 1]
}

fn summary(values: &[f64]) -> String {
    let mut sorted = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    format!(
        "{:>7.1} {:>7.1} {:>7.1} {:>7.1}",
        percentile(&sorted, 50.0),
        percentile(&sorted, 95.0),
        percentile(&sorted, 99.0),
        sorted[sorted.len() - 1]
    )
}

/// Wall-clock cost of one FFI call, sampled `count` times, as (p50, p99) ns.
fn cost(count: usize) -> ((u128, u128), (u128, u128)) {
    // A fresh handle, used from this thread only and freed below.
    let handle = cmux_terminal_prediction_new(true, true);
    let mut input = Vec::with_capacity(count);
    let mut output = Vec::with_capacity(count);
    let mut now: u64 = 1_000_000_000;
    for index in 0..count {
        let byte = b'a' + u8::try_from(index % 26).unwrap_or(0);
        now += 120_000_000;
        let started = Instant::now();
        // SAFETY: `handle` is live; the byte outlives the call.
        unsafe { cmux_terminal_prediction_sent(handle, &byte, 1, now) };
        input.push(started.elapsed().as_nanos());
        now += 70_000_000;
        let started = Instant::now();
        // SAFETY: as above.
        unsafe { cmux_terminal_prediction_output(handle, &byte, 1, now) };
        output.push(started.elapsed().as_nanos());
        // SAFETY: as above.
        unsafe { cmux_terminal_prediction_presented_frame(handle, now + 1_000_000) };
    }
    // SAFETY: from `cmux_terminal_prediction_new`, freed once.
    unsafe { cmux_terminal_prediction_free(handle) };
    let quantiles = |mut samples: Vec<u128>| {
        samples.sort_unstable();
        (samples[samples.len() / 2], samples[samples.len() * 99 / 100])
    };
    (quantiles(input), quantiles(output))
}

fn main() {
    println!(
        "keystroke-to-glyph latency, ms ({KEYS} keys at ~120 ms, +1 frame of {:.1} ms)",
        FRAME_US as f64 / 1000.0
    );
    println!(
        "{:<12} {:<13} {:>7} {:>7} {:>7} {:>7}  {:>9} {:>11}",
        "rtt", "mode", "p50", "p95", "p99", "max", "predicted", "withdrawals"
    );
    for (rtt, jitter, loss) in
        [20, 50, 150, 300].into_iter().flat_map(|rtt| [0, 2, 5].map(|loss| (rtt, rtt / 10, loss)))
    {
        let outcome = simulate(rtt, jitter, loss, 0x5EED ^ u64::try_from(rtt).unwrap_or(0));
        let label = format!("{rtt}±{jitter} {loss}%");
        println!(
            "{label:<12} {:<13} {}  {:>9} {:>11}",
            "no predict",
            summary(&outcome.without),
            "-",
            "-"
        );
        println!(
            "{label:<12} {:<13} {}  {:>8.1}% {:>11}",
            "predict",
            summary(&outcome.with),
            outcome.predicted as f64 * 100.0 / KEYS as f64,
            outcome.withdrawals
        );
    }
    let ((input_p50, input_p99), (output_p50, output_p99)) = cost(100_000);
    println!();
    println!("CPU per call over the C ABI, 100000 calls each (wall clock, ns)");
    println!("on_input   p50 {input_p50:>6}  p99 {input_p99:>6}");
    println!("on_output  p50 {output_p50:>6}  p99 {output_p99:>6}");
}
