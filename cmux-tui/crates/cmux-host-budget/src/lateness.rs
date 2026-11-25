//! Timer lateness: how late a thread that asked for a 10 ms sleep wakes (RFD 0072
//! "Signals"). A busy machine wakes it late before the person feels it: on a
//! saturated Mac the median was 1.6 ms against 0.09 ms idle. The thread sleeps
//! 10 ms repeatedly for [`BURST`] in every [`PERIOD`] (about 20% duty, under 0.1%
//! of a core), and the last [`WINDOW`] of wakes is judged as p50, p95 and the
//! share over 5 ms. The percentile and window code is pure ([`LatenessWindow`]);
//! only [`LatenessMonitor`] owns a thread.

use serde::Serialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

/// How long each sleep asks for.
pub const SLEEP: Duration = Duration::from_millis(10);
/// How long one burst of sleeps lasts.
pub const BURST: Duration = Duration::from_secs(1);
/// The time from the start of one burst to the next.
pub const PERIOD: Duration = Duration::from_secs(5);
/// How far back the readings reach.
pub const WINDOW: Duration = Duration::from_secs(60);
/// A wake later than this counts toward the share.
pub const LATE_MS: f64 = 5.0;
/// The most wakes kept, whatever the window (a burst makes about 100).
const MAX_WAKES: usize = 2_000;
/// Fewer wakes than this say nothing.
pub const MIN_WAKES: usize = 20;

/// The lateness over the window.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Lateness {
    pub wakes: usize,
    pub p50_ms: f64,
    pub p95_ms: f64,
    /// The share of wakes later than [`LATE_MS`] (0..1).
    pub share_over_5ms: f64,
}

/// The nearest-rank percentile `q` (0..1) of an ascending list; none when empty.
pub fn percentile(sorted: &[f64], q: f64) -> Option<f64> {
    if sorted.is_empty() {
        return None;
    }
    let rank = (q.clamp(0.0, 1.0) * sorted.len() as f64).ceil() as usize;
    sorted.get(rank.saturating_sub(1).min(sorted.len() - 1)).copied()
}

/// How late a wake was: the time slept less the time asked, never negative.
pub fn lateness_ms(asked: Duration, slept: Duration) -> f64 {
    slept.saturating_sub(asked).as_secs_f64() * 1000.0
}

/// A rolling window of wakes, each `(when in ms on any one clock, lateness in ms)`.
#[derive(Debug, Clone, Default)]
pub struct LatenessWindow {
    wakes: VecDeque<(u64, f64)>,
}

impl LatenessWindow {
    /// Records a wake at `at_ms` and drops what is older than [`WINDOW`] before it.
    pub fn push(&mut self, at_ms: u64, late_ms: f64) {
        if late_ms.is_finite() {
            self.wakes.push_back((at_ms, late_ms.max(0.0)));
        }
        self.prune(at_ms);
        while self.wakes.len() > MAX_WAKES {
            self.wakes.pop_front();
        }
    }

    fn prune(&mut self, now_ms: u64) {
        let keep_from = now_ms.saturating_sub(WINDOW.as_millis() as u64);
        while self.wakes.front().is_some_and(|(at, _)| *at < keep_from) {
            self.wakes.pop_front();
        }
    }

    /// The window's lateness as of `now_ms`; none under [`MIN_WAKES`] wakes.
    pub fn stats(&self, now_ms: u64) -> Option<Lateness> {
        let keep_from = now_ms.saturating_sub(WINDOW.as_millis() as u64);
        let mut late: Vec<f64> =
            self.wakes.iter().filter(|(at, _)| *at >= keep_from).map(|(_, l)| *l).collect();
        if late.len() < MIN_WAKES {
            return None;
        }
        late.sort_by(f64::total_cmp);
        let over = late.iter().filter(|l| **l > LATE_MS).count();
        Some(Lateness {
            wakes: late.len(),
            p50_ms: percentile(&late, 0.5)?,
            p95_ms: percentile(&late, 0.95)?,
            share_over_5ms: over as f64 / late.len() as f64,
        })
    }
}

struct Shared {
    window: Mutex<LatenessWindow>,
    stop: AtomicBool,
    started: Instant,
}

impl Shared {
    fn now_ms(&self) -> u64 {
        self.started.elapsed().as_millis() as u64
    }
}

/// The timer thread. Dropping it stops the thread within a wake or two.
pub struct LatenessMonitor {
    shared: Arc<Shared>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl LatenessMonitor {
    /// Starts the thread (user-interactive QoS on macOS, so the reading is what an
    /// interactive thread would see). None when the thread cannot start.
    pub fn start() -> Option<Self> {
        let shared = Arc::new(Shared {
            window: Mutex::new(LatenessWindow::default()),
            stop: AtomicBool::new(false),
            started: Instant::now(),
        });
        let for_thread = Arc::clone(&shared);
        let thread = std::thread::Builder::new()
            .name("cmux-lateness".into())
            .spawn(move || run(&for_thread))
            .ok()?;
        Some(Self { shared, thread: Some(thread) })
    }

    /// The lateness over the window now.
    pub fn stats(&self) -> Option<Lateness> {
        let window = self.shared.window.lock().unwrap_or_else(PoisonError::into_inner);
        window.stats(self.shared.now_ms())
    }
}

impl Drop for LatenessMonitor {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            thread.thread().unpark();
        }
    }
}

fn run(shared: &Shared) {
    set_user_interactive();
    while !shared.stop.load(Ordering::Relaxed) {
        let burst_start = Instant::now();
        while burst_start.elapsed() < BURST && !shared.stop.load(Ordering::Relaxed) {
            let before = Instant::now();
            std::thread::sleep(SLEEP);
            let late = lateness_ms(SLEEP, before.elapsed());
            let at = shared.now_ms();
            shared.window.lock().unwrap_or_else(PoisonError::into_inner).push(at, late);
        }
        // park_timeout, so a drop's unpark ends the idle part at once.
        if let Some(rest) = PERIOD.checked_sub(burst_start.elapsed()) {
            std::thread::park_timeout(rest);
        }
    }
}

#[cfg(target_os = "macos")]
fn set_user_interactive() {
    // SAFETY: sets this thread's own QoS class; no pointers.
    unsafe {
        libc::pthread_set_qos_class_self_np(libc::qos_class_t::QOS_CLASS_USER_INTERACTIVE, 0);
    }
}

#[cfg(not(target_os = "macos"))]
fn set_user_interactive() {}

static GLOBAL: OnceLock<Option<LatenessMonitor>> = OnceLock::new();

/// Starts the process's one monitor (once); [`HostProbe`](crate::HostProbe) samples read it.
/// Nothing starts a thread until a caller asks.
pub fn start_global() {
    GLOBAL.get_or_init(LatenessMonitor::start);
}

/// The process's monitor's lateness; none when it was never started or has too few wakes.
pub fn global_stats() -> Option<Lateness> {
    GLOBAL.get()?.as_ref()?.stats()
}

#[cfg(test)]
#[path = "lateness_tests.rs"]
mod tests;
