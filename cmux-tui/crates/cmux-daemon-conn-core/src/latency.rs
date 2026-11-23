//! The app's daemon-request probe: each request's time from its send to its
//! reply (or its failure), in a fixed log-linear histogram
//! (`debug.daemon_requests`, the Austin's-day load scenario).
//!
//! Recording is lock-free and allocation-free: the bucket index is arithmetic
//! on the value, and each bucket, count and maximum is one atomic. Buckets:
//! [0, 64 µs], then four per power of two up to 64 µs << 20 (about 67 s),
//! then one overflow bucket. A reported percentile is its bucket's upper
//! bound, so at most 25 % above the true value (the daemon's `server-stats`
//! histograms use the same 4 sub-buckets).

use std::sync::atomic::{AtomicU64, Ordering};

pub const FIRST_BOUND_US: u64 = 64;
pub const POWERS: u64 = 20;
pub const SUB_BUCKETS: u64 = 4;
/// Every bucket: the bounded ones and the overflow bucket.
/// (1 + 20 * 4 + 1; a literal, checked by a test, so no cast or arithmetic.)
pub const BUCKET_COUNT: usize = 82;

/// The upper bound of each bucket but the overflow one, in microseconds, rising.
pub fn bounds_us() -> Vec<u64> {
    let mut bounds = vec![FIRST_BOUND_US];
    for power in 0..POWERS {
        let base = FIRST_BOUND_US << power;
        let step = base / SUB_BUCKETS;
        for sub in 1..=SUB_BUCKETS {
            bounds.push(base.saturating_add(step.saturating_mul(sub)));
        }
    }
    bounds
}

/// The bucket of a value: the smallest bound at or above it, or the overflow bucket.
pub fn bucket(micros: u64) -> usize {
    if micros <= FIRST_BOUND_US {
        return 0;
    }
    // (64 << k, 64 << (k + 1)] holds `micros`; `micros - 1` puts each bound in its own bucket.
    // `micros` > 64, so none of these wraps; saturating ops keep that visible to the lint.
    let overflow = BUCKET_COUNT.saturating_sub(1);
    let below = micros.saturating_sub(1);
    let high_bit = u64::from(63u32.saturating_sub(below.leading_zeros()));
    let power = high_bit.saturating_sub(u64::from(FIRST_BOUND_US.trailing_zeros()));
    if power >= POWERS {
        return overflow;
    }
    let base = FIRST_BOUND_US << power;
    let sub = below.saturating_sub(base).checked_div(base / SUB_BUCKETS).unwrap_or(0);
    let index = power.saturating_mul(SUB_BUCKETS).saturating_add(sub).saturating_add(1);
    usize::try_from(index).unwrap_or(overflow)
}

/// How a request ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// An `ok:true` reply.
    Reply,
    /// An `ok:false` reply, a closed connection or another failure.
    Error,
    /// No reply within the request's deadline.
    TimedOut,
}

impl Outcome {
    pub fn from_code(code: u32) -> Self {
        match code {
            1 => Self::Error,
            2 => Self::TimedOut,
            _ => Self::Reply,
        }
    }
}

/// The histogram (one per probe; shared by every connection that records).
pub struct Latency {
    buckets: Vec<AtomicU64>,
    errors: AtomicU64,
    timeouts: AtomicU64,
    max_us: AtomicU64,
}

impl Default for Latency {
    fn default() -> Self {
        Self {
            buckets: (0..BUCKET_COUNT).map(|_| AtomicU64::new(0)).collect(),
            errors: AtomicU64::new(0),
            timeouts: AtomicU64::new(0),
            max_us: AtomicU64::new(0),
        }
    }
}

/// A read of the probe (each read is atomic; a request recorded during the
/// read may be in some counts and not yet in others).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub counts: Vec<u64>,
    pub errors: u64,
    pub timeouts: u64,
    pub max_us: u64,
}

impl Latency {
    /// Records one request that took `nanoseconds` from its send to its end.
    pub fn record(&self, nanoseconds: u64, outcome: Outcome) {
        let micros = nanoseconds / 1000;
        if let Some(count) = self.buckets.get(bucket(micros)) {
            count.fetch_add(1, Ordering::Relaxed);
        }
        match outcome {
            Outcome::Reply => {}
            Outcome::Error => {
                self.errors.fetch_add(1, Ordering::Relaxed);
            }
            Outcome::TimedOut => {
                self.timeouts.fetch_add(1, Ordering::Relaxed);
            }
        }
        self.max_us.fetch_max(micros, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            counts: self.buckets.iter().map(|c| c.load(Ordering::Relaxed)).collect(),
            errors: self.errors.load(Ordering::Relaxed),
            timeouts: self.timeouts.load(Ordering::Relaxed),
            max_us: self.max_us.load(Ordering::Relaxed),
        }
    }
}

/// The upper bound of the bucket that holds the `percent`th percentile
/// (nearest rank, `percent` from 1 to 100) of `counts` (one per bucket, the
/// overflow last); `max_us` when that is the overflow bucket; `None` with no
/// requests.
pub fn percentile_us(counts: &[u64], max_us: u64, percent: u64) -> Option<u64> {
    let total: u64 = counts.iter().sum();
    if total == 0 {
        return None;
    }
    let rank = percent.min(100).saturating_mul(total).div_ceil(100).max(1);
    let bounds = bounds_us();
    let mut seen = 0u64;
    for (index, count) in counts.iter().enumerate() {
        seen = seen.saturating_add(*count);
        if seen >= rank {
            return Some(bounds.get(index).copied().unwrap_or(max_us));
        }
    }
    Some(max_us)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bucket_count_is_one_per_bound_and_the_overflow() {
        assert_eq!(BUCKET_COUNT, 1 + (POWERS * SUB_BUCKETS) as usize + 1);
        assert_eq!(bounds_us().len(), BUCKET_COUNT - 1);
    }

    #[test]
    fn each_bound_is_in_its_own_bucket() {
        for (index, bound) in bounds_us().into_iter().enumerate() {
            assert_eq!(bucket(bound), index);
            assert_eq!(bucket(bound + 1), index + 1);
        }
        assert_eq!(bucket(u64::MAX), BUCKET_COUNT - 1);
    }
}
