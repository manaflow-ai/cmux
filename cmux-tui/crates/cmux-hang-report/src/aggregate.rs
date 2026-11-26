//! The watchdog's day: a count per duration bucket and the longest few stalls and hangs, kept
//! with their stacks. The app holds it between reports (and in `pending.json` across a quit);
//! these are its rules.

use serde::{Deserialize, Serialize};

use crate::report::{HangSample, HistogramBucket, Kind, MAX_MS, Source};

pub const BUCKET_EDGES_MS: [i64; 8] = [50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000];
pub const SAMPLED_STALL_MS: i64 = 250;
pub const HANG_MS: i64 = 2_000;
pub const MAX_SAMPLES: usize = 8;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StallAggregate {
    pub counts: Vec<i64>,
    pub hangs: Vec<HangSample>,
    pub stalls: Vec<HangSample>,
}

impl Default for StallAggregate {
    fn default() -> Self {
        Self { counts: vec![0; BUCKET_EDGES_MS.len()], hangs: Vec::new(), stalls: Vec::new() }
    }
}

impl StallAggregate {
    pub fn is_empty(&self) -> bool {
        self.counts.iter().all(|count| *count == 0)
            && self.stalls.is_empty()
            && self.hangs.is_empty()
    }

    pub fn count(&mut self, duration_ms: i64) {
        if let Some(slot) = bucket_index(duration_ms).and_then(|index| self.counts.get_mut(index)) {
            *slot = slot.saturating_add(1);
        }
    }

    pub fn wants_stall_sample(&self, duration_ms: i64) -> bool {
        duration_ms >= SAMPLED_STALL_MS
            && (self.stalls.len() < MAX_SAMPLES
                || duration_ms > self.stalls.last().map_or(0, |last| last.duration_ms))
    }

    pub fn wants_hang_sample(&self, duration_ms: i64) -> bool {
        self.hangs.len() < MAX_SAMPLES
            || duration_ms > self.hangs.last().map_or(0, |last| last.duration_ms)
    }

    pub fn keep(&mut self, sample: HangSample) {
        if sample.kind == Kind::Hang {
            insert(sample, &mut self.hangs)
        } else {
            insert(sample, &mut self.stalls)
        }
    }

    pub fn merge(&mut self, other: &StallAggregate) {
        for (slot, count) in self.counts.iter_mut().zip(&other.counts) {
            *slot = slot.saturating_add(*count);
        }
        for stall in &other.stalls {
            insert(stall.clone(), &mut self.stalls);
        }
        for hang in &other.hangs {
            insert(hang.clone(), &mut self.hangs);
        }
    }

    /// The counts as report buckets (the last one runs to a day).
    pub fn histogram(&self) -> Vec<HistogramBucket> {
        self.counts
            .iter()
            .enumerate()
            .filter(|(_, count)| **count > 0)
            .filter_map(|(index, count)| {
                let low = *BUCKET_EDGES_MS.get(index)?;
                let high = BUCKET_EDGES_MS.get(index + 1).copied().unwrap_or(MAX_MS);
                Some(HistogramBucket::new(low, high, *count))
            })
            .collect()
    }
}

/// The last edge at or under `duration_ms`; nothing under the first.
pub fn bucket_index(duration_ms: i64) -> Option<usize> {
    BUCKET_EDGES_MS.iter().rposition(|edge| duration_ms >= *edge)
}

/// Longest first; a tie goes after the ones already kept.
fn insert(sample: HangSample, list: &mut Vec<HangSample>) {
    let index =
        list.iter().position(|kept| kept.duration_ms < sample.duration_ms).unwrap_or(list.len());
    list.insert(index, sample);
    list.truncate(MAX_SAMPLES);
}

/// A nanosecond reading as whole milliseconds, at most a day.
pub fn milliseconds(nanos: u64) -> i64 {
    (nanos / 1_000_000).min(MAX_MS as u64) as i64
}

/// What one watchdog stall does to the day: the bucket it counts in, and the sample to keep
/// (frames still empty: the app resolves its addresses off the main thread) when it is one of the
/// day's longest. A stall of a hang's length is only counted: `note_hang` sampled it while it ran.
#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Noted {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bucket: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sample: Option<HangSample>,
}

/// `stall_count` and `last_stall_ms` are the aggregate's kept stalls (count and shortest).
pub fn note_stall(
    duration_nanos: u64,
    cpu_nanos: u64,
    has_addresses: bool,
    stall_count: usize,
    last_stall_ms: Option<i64>,
) -> Noted {
    let ms = milliseconds(duration_nanos);
    let wants =
        ms >= SAMPLED_STALL_MS && (stall_count < MAX_SAMPLES || ms > last_stall_ms.unwrap_or(0));
    let sample = (has_addresses && ms < HANG_MS && wants).then(|| {
        HangSample::new(
            Source::Watchdog,
            Kind::Stall,
            ms,
            Some(milliseconds(cpu_nanos)),
            Vec::new(),
        )
    });
    Noted { bucket: bucket_index(ms), sample }
}

pub fn note_hang(
    duration_nanos: u64,
    has_addresses: bool,
    hang_count: usize,
    last_hang_ms: Option<i64>,
) -> Noted {
    let ms = milliseconds(duration_nanos);
    let wants = hang_count < MAX_SAMPLES || ms > last_hang_ms.unwrap_or(0);
    let sample = (has_addresses && wants)
        .then(|| HangSample::new(Source::Watchdog, Kind::Hang, ms, None, Vec::new()));
    Noted { bucket: None, sample }
}
