//! The terminal stream still arriving while a bench runs: the recorded Claude Code session looped
//! at its own pace to fill `stream_seconds`, topped up with synthesized transcript rows (in
//! bursts a few tens of milliseconds apart, as Claude Code writes) until the schedule averages
//! `stream_kbps`, then shaped by the link. A recording that alone exceeds the rate is cut at the
//! byte budget and spread over the whole length instead.

use cmux_fault::Rng;

use crate::history::Rows;
use crate::inputs::PtyChunk;
use crate::link::Link;

/// One write as the reader plays it: `t_ms` after the stream starts.
#[derive(Clone, Debug, PartialEq)]
pub struct Chunk {
    pub t_ms: u64,
    pub bytes: Vec<u8>,
}

/// The stream's writes, delivery times nondecreasing. `filler` draws the top-up rows' timing,
/// `rows` writes them.
pub fn stream(
    recorded: &[PtyChunk],
    kbps: u64,
    seconds: u64,
    filler: &mut Rng,
    rows: &mut Rows,
    link: &mut Link,
) -> Vec<Chunk> {
    let length_us = seconds * 1_000_000;
    let budget = (kbps * 125 * seconds) as usize; // kbit/s * 1000 / 8 bytes, over the length
    if budget == 0 || recorded.is_empty() {
        return Vec::new();
    }
    // Sent writes, microseconds since the start.
    let mut base = loop_recording(recorded, length_us);
    let base_bytes: usize = base.iter().map(|(_, bytes)| bytes.len()).sum();
    let sent = if base_bytes >= budget {
        cut_and_spread(&mut base, budget, length_us);
        base
    } else {
        merge(base, top_up(budget - base_bytes, length_us, filler, rows))
    };
    sent.into_iter()
        .map(|(at_us, bytes)| {
            let delivered = link.deliver(at_us, bytes.len());
            Chunk { t_ms: delivered / 1000, bytes }
        })
        .collect()
}

/// The recording replayed back to back until `length_us`; one replay lasts its span plus one
/// mean gap, so the loop's seam looks like any other pause.
fn loop_recording(recorded: &[PtyChunk], length_us: u64) -> Vec<(u64, Vec<u8>)> {
    let span_ms = recorded.last().map_or(0, |chunk| chunk.t_ms);
    let mean_gap_ms = span_ms / (recorded.len() as u64).max(2).saturating_sub(1);
    let period_us = (span_ms + mean_gap_ms.max(1)) * 1000;
    let mut out = Vec::new();
    for replay in 0.. {
        for chunk in recorded {
            let at_us = replay * period_us + chunk.t_ms * 1000;
            if at_us >= length_us {
                return out;
            }
            out.push((at_us, chunk.bytes.clone()));
        }
    }
    out
}

/// Keeps the writes inside `budget` bytes (the last one cut to fit) and spreads them over the
/// length.
fn cut_and_spread(writes: &mut Vec<(u64, Vec<u8>)>, budget: usize, length_us: u64) {
    let mut total = 0;
    let mut keep = writes.len();
    for (index, (_, bytes)) in writes.iter_mut().enumerate() {
        if total + bytes.len() >= budget {
            bytes.truncate(budget - total);
            keep = index + 1;
            break;
        }
        total += bytes.len();
    }
    writes.truncate(keep);
    let last_us = writes.last().map_or(0, |(at, _)| *at).max(1);
    for (at_us, _) in writes.iter_mut() {
        *at_us = (u128::from(*at_us) * u128::from(length_us) / u128::from(last_us)) as u64;
    }
}

/// `deficit` bytes of synthesized rows, cut at row boundaries into bursts every 8 to 40 ms
/// across the length, each burst's share drawn around the mean.
fn top_up(deficit: usize, length_us: u64, rng: &mut Rng, rows: &mut Rows) -> Vec<(u64, Vec<u8>)> {
    let mut ticks = Vec::new();
    let mut at_us = 0;
    while at_us < length_us {
        ticks.push(at_us);
        at_us += rng.range(8, 40) * 1000;
    }
    let mean = deficit as f64 / ticks.len() as f64;
    let mut out = Vec::with_capacity(ticks.len());
    let mut written = 0;
    let mut quota = 0.0;
    for (index, at_us) in ticks.iter().enumerate() {
        let last = index + 1 == ticks.len();
        quota += mean * (0.5 + rng.range(0, 100) as f64 / 100.0);
        let goal = if last { deficit } else { (quota as usize).min(deficit) };
        let mut burst = Vec::new();
        while written + burst.len() < goal {
            rows.push_row(&mut burst);
        }
        written += burst.len();
        if !burst.is_empty() {
            out.push((*at_us, burst));
        }
    }
    out
}

/// Two time-ordered write lists as one, the recording's first on a tie.
fn merge(a: Vec<(u64, Vec<u8>)>, b: Vec<(u64, Vec<u8>)>) -> Vec<(u64, Vec<u8>)> {
    let mut out = Vec::with_capacity(a.len() + b.len());
    let mut a = a.into_iter().peekable();
    let mut b = b.into_iter().peekable();
    loop {
        let take_a = match (a.peek(), b.peek()) {
            (Some(x), Some(y)) => x.0 <= y.0,
            (Some(_), None) => true,
            (None, Some(_)) => false,
            (None, None) => return out,
        };
        out.extend(if take_a { a.next() } else { b.next() });
    }
}
