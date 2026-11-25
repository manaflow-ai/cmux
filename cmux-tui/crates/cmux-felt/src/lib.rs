//! The net graph of cmux: what a person feels, as numbers (hq docs/design/game-patterns-for-cmux.md
//! item 6).
//!
//! Leo, 2026-11-24: "huh. speaking of game stuff. i feel like we are probably not using as many
//! gigabrain optimizations and even regular brain optimizations and patterns that they have wrt
//! ergo and connectivity and sync and de-lagging and maybe more other stuff". Every shipped game
//! engine keeps a net graph and frame-time histograms, so a felt regression shows in the running
//! game and not only in a lab harness. This is that: one histogram per [`Metric`], read by
//! `felt.snapshot` as p50/p90/p99, count and max, over the last minute and since start.
//!
//! Cost: a record is one clock read and four relaxed atomic operations (the bucket is arithmetic
//! on the value), no allocation, no lock, constant memory (about 60 KB for every metric, static).
//! Buckets are log-linear: exact below 4 µs, then four per power of two, so a reported percentile
//! (its bucket's upper bound, capped at the maximum seen) is at most 25 % above the true one.
//!
//! The last minute is six 10 s slots, each tagged with the 10 s epoch it holds. A record into a
//! slot of an older epoch claims it (one compare-and-swap) and clears it; a record that races the
//! clear of its own slot may be dropped, at most a few samples once per 10 s per metric. Reads
//! skip slots older than the window. Nothing runs on a timer.
//!
//! Metrics are names and numbers only: no prompt, path, key or terminal text is ever passed in.
#![deny(clippy::indexing_slicing, clippy::expect_used, clippy::unwrap_used)]

use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// What is timed. The set is small and fixed: it is the histogram's index.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
#[repr(u8)]
pub enum Metric {
    /// A typed key to its echo from the remote shell (the prediction engine's samples).
    TerminalEcho,
    /// A prompt from the request reaching the daemon to the chat taking it (the ack).
    PromptSendToAck,
    /// A prompt from the request to the agent's first token of its turn.
    PromptSendToFirstToken,
    /// Time between two presented frames of a terminal surface.
    FrameIntervalTerminal,
    /// Time between two presented frames of a chat surface.
    FrameIntervalChat,
    /// Time between two presented frames of a browser surface.
    FrameIntervalBrowser,
}

/// Every metric, in index order.
pub const METRICS: [Metric; 6] = [
    Metric::TerminalEcho,
    Metric::PromptSendToAck,
    Metric::PromptSendToFirstToken,
    Metric::FrameIntervalTerminal,
    Metric::FrameIntervalChat,
    Metric::FrameIntervalBrowser,
];

impl Metric {
    /// The stable name `felt.snapshot` reports it under.
    pub const fn name(self) -> &'static str {
        match self {
            Self::TerminalEcho => "terminal_echo",
            Self::PromptSendToAck => "prompt_send_to_ack",
            Self::PromptSendToFirstToken => "prompt_send_to_first_token",
            Self::FrameIntervalTerminal => "frame_interval_terminal",
            Self::FrameIntervalChat => "frame_interval_chat",
            Self::FrameIntervalBrowser => "frame_interval_browser",
        }
    }

    const fn index(self) -> usize {
        self as usize
    }
}

/// Buckets: values 0 to 3 µs are one each; then four per power of two up to 2^36 µs (about 19
/// hours); the last bucket holds anything above.
pub const BUCKETS: usize = 141;
const SUB_BITS: u32 = 2;
const SUBS: u64 = 1 << SUB_BITS;
/// The top power of two with its own buckets.
const TOP_POWER: u32 = 35;

/// Slots in the window, and how long each is held.
const SLOTS: usize = 6;
const SLOT_MS: u64 = 10_000;
/// The window `felt.snapshot` calls "last_60s".
pub const WINDOW_MS: u64 = SLOTS as u64 * SLOT_MS;

/// The bucket of `micros`.
pub fn bucket_of(micros: u64) -> usize {
    if micros < SUBS {
        return usize::try_from(micros).unwrap_or(0);
    }
    let power = 63u32.saturating_sub(micros.leading_zeros());
    if power > TOP_POWER {
        return BUCKETS.saturating_sub(1);
    }
    let sub = (micros >> power.saturating_sub(SUB_BITS)) & (SUBS - 1);
    let index = u64::from(power.saturating_sub(1)) * SUBS + sub;
    usize::try_from(index).unwrap_or(0)
}

/// The largest value the bucket holds (`u64::MAX` for the last).
pub fn bucket_upper(index: usize) -> u64 {
    let index = u64::try_from(index).unwrap_or(u64::MAX);
    if index < SUBS {
        return index;
    }
    if index >= u64::try_from(BUCKETS).unwrap_or(0).saturating_sub(1) {
        return u64::MAX;
    }
    let power = u32::try_from(index / SUBS).unwrap_or(0).saturating_add(1);
    let sub = index % SUBS;
    let step = 1u64 << power.saturating_sub(SUB_BITS);
    (1u64 << power).saturating_add(step.saturating_mul(sub.saturating_add(1))).saturating_sub(1)
}

struct Counts {
    buckets: [AtomicU64; BUCKETS],
    max_us: AtomicU64,
}

impl Counts {
    const fn new() -> Self {
        Self { buckets: [const { AtomicU64::new(0) }; BUCKETS], max_us: AtomicU64::new(0) }
    }

    fn add(&self, micros: u64) {
        if let Some(count) = self.buckets.get(bucket_of(micros)) {
            count.fetch_add(1, Ordering::Relaxed);
        }
        // A read first: the maximum rarely moves, and a read-modify-write on one shared word is
        // what 8 threads would queue on.
        if micros > self.max_us.load(Ordering::Relaxed) {
            self.max_us.fetch_max(micros, Ordering::Relaxed);
        }
    }

    fn clear(&self) {
        for count in &self.buckets {
            count.store(0, Ordering::Relaxed);
        }
        self.max_us.store(0, Ordering::Relaxed);
    }
}

struct Slot {
    /// The epoch (`now_ms / SLOT_MS`) plus one this slot holds; 0 for never used.
    epoch: AtomicU64,
    counts: Counts,
}

struct One {
    total: Counts,
    slots: [Slot; SLOTS],
}

impl One {
    const fn new() -> Self {
        Self {
            total: Counts::new(),
            slots: [const { Slot { epoch: AtomicU64::new(0), counts: Counts::new() } }; SLOTS],
        }
    }
}

/// A set of histograms, one per [`Metric`]. The process has one ([`record`], [`snapshot`]); tests
/// make their own.
pub struct Felt {
    metrics: [One; 6],
}

impl Default for Felt {
    fn default() -> Self {
        Self::new()
    }
}

impl Felt {
    pub const fn new() -> Self {
        Self { metrics: [const { One::new() }; 6] }
    }

    /// Records one sample of `metric` at `now_ms` (any monotonic clock, in milliseconds).
    pub fn record_at(&self, metric: Metric, micros: u64, now_ms: u64) {
        let Some(one) = self.metrics.get(metric.index()) else { return };
        one.total.add(micros);
        let epoch = (now_ms / SLOT_MS).saturating_add(1);
        let Some(slot) = usize::try_from(epoch)
            .ok()
            .and_then(|e| e.checked_rem(SLOTS))
            .and_then(|i| one.slots.get(i))
        else {
            return;
        };
        let held = slot.epoch.load(Ordering::Acquire);
        if held != epoch {
            // A sample for an older epoch than the slot holds (a clock read before a newer
            // record) is dropped from the window; the total keeps it.
            if held > epoch {
                return;
            }
            if slot.epoch.compare_exchange(held, epoch, Ordering::AcqRel, Ordering::Acquire).is_ok()
            {
                slot.counts.clear();
            }
        }
        slot.counts.add(micros);
    }

    /// Records one sample of `metric` now.
    pub fn record(&self, metric: Metric, elapsed: Duration) {
        let micros = u64::try_from(elapsed.as_micros()).unwrap_or(u64::MAX);
        self.record_at(metric, micros, now_ms());
    }

    /// Every metric as JSON: `{windowMs, metrics: {NAME: {since_start, last_60s}}}`, each with
    /// `count`, `p50_us`, `p90_us`, `p99_us` and `max_us` (null percentiles with no samples).
    pub fn snapshot_at(&self, now_ms: u64) -> Value {
        let epoch = (now_ms / SLOT_MS).saturating_add(1);
        let oldest = epoch.saturating_sub(u64::try_from(SLOTS).unwrap_or(0)).saturating_add(1);
        let mut out = serde_json::Map::new();
        for metric in METRICS {
            let Some(one) = self.metrics.get(metric.index()) else { continue };
            let since_start = read(std::iter::once(&one.total));
            let window = read(
                one.slots
                    .iter()
                    .filter(|s| {
                        let held = s.epoch.load(Ordering::Acquire);
                        held >= oldest && held <= epoch
                    })
                    .map(|s| &s.counts),
            );
            out.insert(
                metric.name().to_owned(),
                json!({"since_start": since_start, "last_60s": window}),
            );
        }
        json!({"windowMs": WINDOW_MS, "metrics": out})
    }

    /// [`Felt::snapshot_at`] now.
    pub fn snapshot(&self) -> Value {
        self.snapshot_at(now_ms())
    }
}

/// Merges `counts` and reads its percentiles.
fn read<'a>(counts: impl Iterator<Item = &'a Counts>) -> Value {
    let mut merged = [0u64; BUCKETS];
    let mut max_us = 0u64;
    for one in counts {
        for (into, from) in merged.iter_mut().zip(&one.buckets) {
            *into = into.saturating_add(from.load(Ordering::Relaxed));
        }
        max_us = max_us.max(one.max_us.load(Ordering::Relaxed));
    }
    let count: u64 = merged.iter().sum();
    let percentile = |percent: u64| -> Value {
        match percentile_us(&merged, max_us, percent) {
            Some(us) => json!(us),
            None => Value::Null,
        }
    };
    json!({
        "count": count,
        "p50_us": percentile(50),
        "p90_us": percentile(90),
        "p99_us": percentile(99),
        "max_us": if count == 0 { Value::Null } else { json!(max_us) },
    })
}

/// The `percent`th percentile (nearest rank) of `counts`, as its bucket's upper bound capped at
/// `max_us`; `None` with no samples.
pub fn percentile_us(counts: &[u64], max_us: u64, percent: u64) -> Option<u64> {
    let total: u64 = counts.iter().sum();
    if total == 0 {
        return None;
    }
    let rank = percent.min(100).saturating_mul(total).div_ceil(100).max(1);
    let mut seen = 0u64;
    for (index, count) in counts.iter().enumerate() {
        seen = seen.saturating_add(*count);
        if seen >= rank {
            return Some(bucket_upper(index).min(max_us));
        }
    }
    Some(max_us)
}

static GLOBAL: Felt = Felt::new();
static START: OnceLock<Instant> = OnceLock::new();

/// Milliseconds on this process's monotonic clock.
fn now_ms() -> u64 {
    let start = START.get_or_init(Instant::now);
    u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// Records one sample of `metric` in the process's histograms.
pub fn record(metric: Metric, elapsed: Duration) {
    GLOBAL.record(metric, elapsed);
}

/// The process's histograms, as `felt.snapshot` reports them.
pub fn snapshot() -> Value {
    GLOBAL.snapshot()
}

#[cfg(test)]
mod tests;
