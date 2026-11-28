//! Memory stall shaped as PSI where the kernel's PSI is off (cmuxterm-hq RFD 0182 B1).
//!
//! Freestyle guests boot with `CONFIG_PSI_DEFAULT_DISABLED`, so `/proc/pressure/memory` is
//! absent and AutoSize's PSI rule never fires there (RFD 0133, RFD 0182 S4). Every kernel still
//! counts reclaim in `/proc/vmstat` ([`Reclaim`]). This module reads those counters once a
//! second and folds them into the shape PSI prints, `some` and `full` with `avg10`, `avg60` and
//! `avg300` in percent, so one rule reads either source:
//!
//! - a second is a `some` second when an allocation stalled on direct reclaim (an
//!   `allocstall_*` rise) or evicted pages were read back at [`REFAULT_PAGES_PER_SEC`] or more:
//!   the same test as `acpmux machine load --watch`'s `reclaim` event;
//! - a second is a `full` second when both happened: tasks stalled freeing memory while the
//!   working set thrashed, the state RFD 0182 T4 watched sit ~540 s with MemAvailable flat.
//!
//! The averages decay as the kernel's do (`kernel/sched/psi.c` `calc_avgs`): each update moves
//! the average toward the share of the elapsed time that stalled by `1 - exp(-dt / window)`.
//! It is an estimate: PSI counts the time tasks wait, these count seconds in which some did.
//!
//! [`StallAverages`] is the whole estimate and is pure; [`start_global`] owns the one thread
//! (Linux only; one `/proc/vmstat` read a second, tens of microseconds).

use crate::Reclaim;
use serde::{Deserialize, Serialize};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// How often the thread reads `/proc/vmstat`.
pub const INTERVAL: Duration = Duration::from_secs(1);
/// Refaults per second that count as a stalled second: 10 MiB of 4 KiB pages, as the watch's.
pub const REFAULT_PAGES_PER_SEC: u64 = 2560;
/// A gap longer than this between readings (a suspended VM, a stopped thread) is not folded in:
/// the next reading is a new baseline.
pub const MAX_GAP: Duration = Duration::from_secs(30);
/// PSI's windows, in seconds.
const WINDOWS: [f64; 3] = [10.0, 60.0, 300.0];

/// One line of PSI's shape, in percent of time (0..100).
#[derive(Debug, Default, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Avgs {
    pub avg10: f64,
    pub avg60: f64,
    pub avg300: f64,
}

impl Avgs {
    fn fold(&mut self, stalled_share: f64, dt_secs: f64) {
        let pct = stalled_share.clamp(0.0, 1.0) * 100.0;
        for (avg, window) in
            [&mut self.avg10, &mut self.avg60, &mut self.avg300].into_iter().zip(WINDOWS)
        {
            let keep = (-dt_secs / window).exp();
            *avg = *avg * keep + pct * (1.0 - keep);
        }
    }

    fn rounded(self) -> Self {
        let r = |v: f64| (v * 100.0).round() / 100.0;
        Self { avg10: r(self.avg10), avg60: r(self.avg60), avg300: r(self.avg300) }
    }
}

/// The estimate as `acpmux machine load --json` (`memStall`) and `daemon status` print it.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MemStall {
    pub source: Source,
    pub some: Avgs,
    pub full: Avgs,
    /// Seconds of readings folded in since the thread started: `avg300` means little under 300.
    pub covered_secs: u64,
}

/// Where the estimate came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// Estimated from `/proc/vmstat`'s reclaim counters, not the kernel's PSI.
    Vmstat,
}

/// The pure estimator: feed it `(when, counters)` readings; read [`StallAverages::get`].
#[derive(Debug, Default, Clone, PartialEq)]
pub struct StallAverages {
    last: Option<(Instant, Reclaim)>,
    some: Avgs,
    full: Avgs,
    covered: Duration,
}

impl StallAverages {
    /// Folds in a reading taken at `at`. The first reading, one after a gap over [`MAX_GAP`] and
    /// one whose counters went down (a new boot) are baselines and change no average.
    pub fn push(&mut self, at: Instant, now: Reclaim) {
        let before = self.last.replace((at, now));
        let Some((then, before)) = before else { return };
        let dt = at.saturating_duration_since(then);
        if dt.is_zero()
            || dt > MAX_GAP
            || now.alloc_stalls < before.alloc_stalls
            || now.refaults < before.refaults
        {
            return;
        }
        let secs = dt.as_secs_f64();
        let stalled = now.alloc_stalls > before.alloc_stalls;
        let refaults_per_sec = (now.refaults - before.refaults) as f64 / secs;
        let thrashing = refaults_per_sec >= REFAULT_PAGES_PER_SEC as f64;
        self.some.fold(f64::from(u8::from(stalled || thrashing)), secs);
        self.full.fold(f64::from(u8::from(stalled && thrashing)), secs);
        self.covered += dt;
    }

    /// The averages now; none before two readings a gap apart.
    pub fn get(&self) -> Option<MemStall> {
        (!self.covered.is_zero()).then(|| MemStall {
            source: Source::Vmstat,
            some: self.some.rounded(),
            full: self.full.rounded(),
            covered_secs: self.covered.as_secs(),
        })
    }
}

static GLOBAL: OnceLock<Mutex<StallAverages>> = OnceLock::new();

/// Starts the process's one reader thread (once; Linux only, elsewhere a no-op). The daemon
/// calls it at start so the averages are warm when `acpmux machine load` asks.
pub fn start_global() {
    #[cfg(target_os = "linux")]
    {
        let mut first = false;
        GLOBAL.get_or_init(|| {
            first = true;
            Mutex::new(StallAverages::default())
        });
        if first {
            let started = std::thread::Builder::new().name("cmux-mem-stall".into()).spawn(|| {
                loop {
                    let read = std::fs::read_to_string("/proc/vmstat").ok();
                    if let Some(r) = read.as_deref().and_then(crate::parse_vmstat_reclaim) {
                        if let Some(g) = GLOBAL.get() {
                            g.lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .push(Instant::now(), r);
                        }
                    } else if read.is_none() {
                        // No `/proc/vmstat`: nothing will ever be read here.
                        return;
                    }
                    std::thread::sleep(INTERVAL);
                }
            });
            drop(started);
        }
    }
}

/// The process's estimate; none when [`start_global`] never ran or has under two readings.
pub fn global() -> Option<MemStall> {
    GLOBAL.get()?.lock().unwrap_or_else(PoisonError::into_inner).get()
}

#[cfg(test)]
#[path = "mem_stall_tests.rs"]
mod tests;
