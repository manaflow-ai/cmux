//! The always-on frame tally of the visible chat: how long the chat pages of this Mac's app took
//! per display frame while they drew, over the last [`WINDOW_MS`], as p50, p95 and p99. The goal it
//! feeds: "the visible chat draws at p95 <= 16.7 ms per frame while the Mac's load is at least 4x
//! its cores" (perf-tap's `perf_sensor.leo_nightly.frame_p95_ms`, read with
//! `cmux debug perf frames`), a number that must exist without the perf commentator
//! (`perf_watch.rs`) being on, since turning that on changes the app it measures.
//!
//! The chat page counts its frames where it already reads them (webviews
//! `conversation/frameBudget.ts`: a display frame loop that runs only while the chat does work and
//! only while the page is visible, so a hidden or idle chat counts nothing and asks for no frame)
//! into fixed buckets of [`BUCKET_MS`], and sends the non-empty buckets at most every few seconds
//! (`_acpmux/perf {op:"tally"}`, `frameTally.ts`). The daemon adds them to the current
//! [`SLOT_MS`] slot of a fixed ring: no allocation, no growth, one lock for a few hundred adds.
//! `{op:"frames"}` reads the window and changes nothing.
//!
//! Local only: the perf method is refused to any connection that is not this Mac's app or unix
//! socket (`server/requests.rs`), and nothing here leaves the machine.

use std::sync::Mutex;

use serde_json::{Value, json};

use crate::no_panic::LockExt;

/// The width of one bucket (ms). A 60 Hz frame (16.67 ms) falls in [16.6, 16.7), said as 16.65.
pub const BUCKET_MS: f64 = 0.1;
/// Buckets up to [`LIMIT_MS`]; one more holds every frame at or past it.
pub const BUCKETS: usize = 1000;
/// The longest frame a bucket of its own holds (ms).
pub const LIMIT_MS: f64 = BUCKET_MS * BUCKETS as f64;
/// One slot of the ring (ms).
pub const SLOT_MS: u64 = 10_000;
/// Slots in the ring: [`WINDOW_MS`] in all.
pub const SLOTS: usize = 30;
/// How far back a read reaches (ms): the last 5 minutes.
pub const WINDOW_MS: u64 = SLOT_MS * SLOTS as u64;
/// The frame budget the goal names (ms): frames over it are counted apart.
pub const FRAME_BUDGET_MS: f64 = 16.7;

const EMPTY: u64 = u64::MAX;

/// The ring: `counts[s % SLOTS]` holds slot `s`'s frames when `stamps[s % SLOTS] == s`.
pub struct Tally {
    counts: [[u32; BUCKETS + 1]; SLOTS],
    stamps: [u64; SLOTS],
    /// When the first frame came (ms since 1970); 0 before any.
    started_ms: u64,
}

impl Tally {
    pub const fn new() -> Self {
        Self { counts: [[0; BUCKETS + 1]; SLOTS], stamps: [EMPTY; SLOTS], started_ms: 0 }
    }

    /// Adds `count` frames to bucket `index` (past [`BUCKETS`]: the overflow bucket) at `now_ms`.
    pub fn add(&mut self, now_ms: u64, index: usize, count: u32) {
        if count == 0 {
            return;
        }
        if self.started_ms == 0 {
            self.started_ms = now_ms;
        }
        let slot = now_ms / SLOT_MS;
        let at = (slot % SLOTS as u64) as usize;
        let (Some(stamp), Some(counts)) = (self.stamps.get_mut(at), self.counts.get_mut(at)) else {
            return;
        };
        if *stamp != slot {
            *stamp = slot;
            *counts = [0; BUCKETS + 1];
        }
        if let Some(bucket) = counts.get_mut(index.min(BUCKETS)) {
            *bucket = bucket.saturating_add(count);
        }
    }

    /// The frames of the last [`WINDOW_MS`] up to `now_ms`, per bucket. Reads only.
    pub fn window(&self, now_ms: u64) -> [u64; BUCKETS + 1] {
        let slot = now_ms / SLOT_MS;
        let mut sum = [0u64; BUCKETS + 1];
        for (stamp, counts) in self.stamps.iter().zip(self.counts.iter()) {
            if *stamp == EMPTY || *stamp > slot || slot - *stamp >= SLOTS as u64 {
                continue;
            }
            for (total, count) in sum.iter_mut().zip(counts.iter()) {
                *total += u64::from(*count);
            }
        }
        sum
    }

    /// The window as the `frames` read says it (see [`summary`]).
    pub fn read(&self, now_ms: u64) -> Value {
        let counts = self.window(now_ms);
        let covered = if self.started_ms == 0 {
            0
        } else {
            now_ms.saturating_sub(self.started_ms).min(WINDOW_MS)
        };
        let mut chat = summary(&counts);
        if let Some(object) = chat.as_object_mut() {
            object.insert("window_s".into(), json!(covered / 1000));
            object.insert(
                "since".into(),
                if covered == 0 { Value::Null } else { json!(now_ms - covered) },
            );
        }
        json!({
            "visible_chat": chat,
            "at": now_ms,
            "bucket_ms": BUCKET_MS,
            "window_max_s": WINDOW_MS / 1000,
        })
    }
}

impl Default for Tally {
    fn default() -> Self {
        Self::new()
    }
}

/// The value of bucket `index`: its middle, or [`LIMIT_MS`] for the overflow bucket.
fn bucket_value(index: usize) -> f64 {
    if index >= BUCKETS {
        LIMIT_MS
    } else {
        let value = (index as f64 + 0.5) * BUCKET_MS;
        (value * 100.0).round() / 100.0
    }
}

/// The nearest-rank `share` percentile of the frames in `counts` (the value of the bucket that
/// holds the frame ranked `ceil(share * n)`); None with no frames.
pub fn percentile(counts: &[u64], share: f64) -> Option<f64> {
    let total: u64 = counts.iter().sum();
    if total == 0 {
        return None;
    }
    let rank = ((share * total as f64).ceil() as u64).clamp(1, total);
    let mut seen = 0u64;
    for (index, count) in counts.iter().enumerate() {
        seen += count;
        if seen >= rank {
            return Some(bucket_value(index));
        }
    }
    None
}

/// `{frames, p50_ms, p95_ms, p99_ms, max_ms, over_budget, over_limit}` of `counts`: percentiles
/// are null with no frames; one in the overflow bucket is [`LIMIT_MS`] (`over_limit` says how many
/// frames were past it).
pub fn summary(counts: &[u64]) -> Value {
    let frames: u64 = counts.iter().sum();
    let first_over = (FRAME_BUDGET_MS / BUCKET_MS).round() as usize;
    let over_budget: u64 = counts.iter().skip(first_over).sum();
    let max = counts.iter().rposition(|count| *count > 0).map(bucket_value);
    json!({
        "frames": frames,
        "p50_ms": percentile(counts, 0.50),
        "p95_ms": percentile(counts, 0.95),
        "p99_ms": percentile(counts, 0.99),
        "max_ms": max,
        "over_budget": over_budget,
        "budget_ms": FRAME_BUDGET_MS,
        "over_limit": counts.get(BUCKETS).copied().unwrap_or(0),
    })
}

static GLOBAL: Mutex<Tally> = Mutex::new(Tally::new());

/// Buckets a page sends at most in one tally (every bucket once, and the overflow).
const MAX_PAIRS: usize = BUCKETS + 1;

/// A page's tally (`{bucketMs, gaps: [[index, count], ...]}`) added to `tally` at `now_ms`. A
/// tally in other buckets than ours (a page of another build) is refused whole.
pub fn add_report(tally: &mut Tally, now_ms: u64, params: &Value) -> Result<u64, String> {
    let width = params.get("bucketMs").and_then(Value::as_f64).unwrap_or(0.0);
    if (width - BUCKET_MS).abs() > 1e-9 {
        return Err(format!("bucketMs {width} is not {BUCKET_MS}"));
    }
    let mut added = 0u64;
    for pair in params.get("gaps").and_then(Value::as_array).into_iter().flatten().take(MAX_PAIRS) {
        let Some([index, count]) = pair.as_array().map(Vec::as_slice) else { continue };
        let (Some(index), Some(count)) = (index.as_u64(), count.as_u64()) else { continue };
        let count = u32::try_from(count).unwrap_or(u32::MAX);
        tally.add(now_ms, usize::try_from(index).unwrap_or(BUCKETS), count);
        added += u64::from(count);
    }
    Ok(added)
}

/// `_acpmux/perf {op:"tally"}` on this daemon's tally.
pub fn report(params: &Value) -> Result<Value, String> {
    let now = crate::store::now_ms();
    let added = add_report(&mut GLOBAL.lock_or_recover(), now, params)?;
    Ok(json!({"ok": true, "frames": added}))
}

/// `_acpmux/perf {op:"frames"}`: this daemon's window. Reads only.
pub fn read() -> Value {
    let now = crate::store::now_ms();
    GLOBAL.lock_or_recover().read(now)
}

#[cfg(test)]
#[path = "frame_tally_tests.rs"]
mod tests;
