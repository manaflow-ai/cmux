//! Part of `host_pressure.rs`: the daemon's [`Meter`]. It samples only when a
//! request asks, at most once per `sample_seconds`, on a blocking thread and one
//! sample at a time, and keeps the last verdict and the swap baseline. No timer.

use super::{Budget, HostProbe, Probe, Verdict, evaluate, host_name, load_budget};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

/// How long a request waits for a sample before it takes the last verdict.
pub const SAMPLE_WAIT: Duration = Duration::from_millis(250);

/// The oldest verdict a turn's acceptance repeats ([`Meter::peek`]).
const RECENT: Duration = Duration::from_secs(60);

/// A swap baseline older than this gives no rate; the next sample starts a new one.
const SWAP_WINDOW: Duration = Duration::from_secs(600);

const MIB: f64 = 1024.0 * 1024.0;

/// Samples on demand, at most once per `sample_seconds`, and remembers the swap
/// baseline between samples. No timer: a verdict is made only when one is asked for.
pub struct Meter {
    host: String,
    probe: Box<dyn Probe>,
    budget: Box<dyn Fn(&str) -> Budget + Send + Sync>,
    state: Mutex<MeterState>,
    /// Set while a sample is taken: one at a time, and no request waits for another's.
    sampling: AtomicBool,
}

#[derive(Default)]
struct MeterState {
    /// When the last verdict was made, and it.
    cached: Option<(Instant, Verdict)>,
    /// The swap-out counter at the last sample that had one.
    swap: Option<(Instant, u64)>,
}

/// Clears [`Meter::sampling`] when a sample ends, however it ends.
struct Sampling<'a>(&'a AtomicBool);

impl Drop for Sampling<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

/// A [`Meter::sampling`] claim taken before a blocking job is queued, so a queued
/// job also counts as in flight; it clears the flag even if the job never runs.
struct Claim(Arc<Meter>);

impl Drop for Claim {
    fn drop(&mut self) {
        self.0.sampling.store(false, Ordering::SeqCst);
    }
}

impl Meter {
    /// This host's one meter, shared by the process: the budget is the host's, not a
    /// daemon's. Its probe and the override file are read at each fresh sample.
    pub fn shared() -> &'static Arc<Meter> {
        static SHARED: OnceLock<Arc<Meter>> = OnceLock::new();
        SHARED.get_or_init(|| {
            Arc::new(Self::new(host_name(), Box::new(HostProbe), Box::new(load_budget)))
        })
    }

    pub fn new(
        host: String,
        probe: Box<dyn Probe>,
        budget: Box<dyn Fn(&str) -> Budget + Send + Sync>,
    ) -> Self {
        Self { host, probe, budget, state: Mutex::default(), sampling: AtomicBool::new(false) }
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, MeterState> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The last verdict, however old.
    pub fn last(&self) -> Option<Verdict> {
        self.lock().cached.as_ref().map(|(_, v)| v.clone())
    }

    /// The last verdict while it is from the last `sample_seconds`.
    pub fn fresh_at(&self, now: Instant) -> Option<Verdict> {
        let state = self.lock();
        let (at, v) = state.cached.as_ref()?;
        (now.saturating_duration_since(*at).as_secs_f64() < v.formula.sample_seconds)
            .then(|| v.clone())
    }

    /// The verdict for a daemon request (never blocks a runtime worker): a fresh
    /// one, or one sampled on a blocking thread within [`SAMPLE_WAIT`], or else
    /// the last one (`None` before the first sample ends).
    pub async fn current(self: &Arc<Self>) -> Option<Verdict> {
        if let Some(v) = self.fresh_at(Instant::now()) {
            return Some(v);
        }
        let Some(sample) = self.start_sample() else {
            return self.last();
        };
        match tokio::time::timeout(SAMPLE_WAIT, sample).await {
            Ok(Ok(Some(v))) => Some(v),
            _ => self.last(),
        }
    }

    /// Claims [`Meter::sampling`] and then queues one sample on a blocking thread;
    /// `None` while another is queued or running, so a stalled probe never piles
    /// up blocking jobs.
    fn start_sample(self: &Arc<Self>) -> Option<tokio::task::JoinHandle<Option<Verdict>>> {
        if self.sampling.swap(true, Ordering::SeqCst) {
            return None;
        }
        let claim = Claim(self.clone());
        Some(tokio::task::spawn_blocking(move || claim.0.take_sample(Instant::now())))
    }

    /// For a turn's acceptance, which must not wait: the last verdict while it is
    /// at most a minute old. When it is not fresh, a sample starts on a blocking
    /// thread for the next request (none while one is in flight).
    pub fn peek(self: &Arc<Self>) -> Option<Verdict> {
        let now = Instant::now();
        let last = self.lock().cached.as_ref().map(|(at, v)| {
            let age = now.saturating_duration_since(*at);
            (age.as_secs_f64() < v.formula.sample_seconds, age <= RECENT, v.clone())
        });
        let fresh = last.as_ref().is_some_and(|(fresh, _, _)| *fresh);
        if !fresh {
            drop(self.start_sample());
        }
        last.filter(|(_, recent, _)| *recent).map(|(_, _, v)| v)
    }

    /// Samples now, unless the last verdict is fresh (it) or another sample is in
    /// flight (`None`). Blocking: reads the probe and the override file with no
    /// lock held.
    pub fn sample_at(&self, now: Instant) -> Option<Verdict> {
        if let Some(v) = self.fresh_at(now) {
            return Some(v);
        }
        if self.sampling.swap(true, Ordering::SeqCst) {
            return None;
        }
        let _sampling = Sampling(&self.sampling);
        self.take_sample(now)
    }

    /// Samples now unless the last verdict is fresh; the caller holds the
    /// [`Meter::sampling`] claim. Blocking.
    fn take_sample(&self, now: Instant) -> Option<Verdict> {
        if let Some(v) = self.fresh_at(now) {
            return Some(v);
        }
        let budget = (self.budget)(&self.host);
        let sample = self.probe.sample();
        let mut state = self.lock();
        let rate = match (sample.swapout_bytes, state.swap) {
            (Some(bytes), Some((at, before))) => {
                let elapsed = now.saturating_duration_since(at);
                (elapsed.as_secs_f64() >= budget.formula.sample_seconds && elapsed <= SWAP_WINDOW)
                    .then(|| {
                        bytes.saturating_sub(before) as f64 / MIB / (elapsed.as_secs_f64() / 60.0)
                    })
            }
            _ => None,
        };
        if let Some(bytes) = sample.swapout_bytes {
            state.swap = Some((now, bytes));
        }
        let v = evaluate(&self.host, &sample, rate, &budget);
        let was_ok = state.cached.as_ref().is_none_or(|(_, before)| before.ok);
        state.cached = Some((now, v.clone()));
        // Logged after the lock is released: a slow log writer never holds a turn.
        drop(state);
        if let Some(line) = v.warning.as_deref().filter(|_| was_ok) {
            tracing::warn!("{line}");
        } else if v.ok && !was_ok {
            tracing::info!("host-budget: {} is within its CPU/RAM budget again", self.host);
        }
        Some(v)
    }
}

#[cfg(test)]
#[path = "host_pressure_meter_tests.rs"]
mod tests;
