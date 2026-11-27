//! `cpu` and `ram` pressure on the real host, inside the test's own process: no root, no
//! `stress-ng`, and nothing left behind (each load stops when it drops).
//!
//! - [`CpuLoad`]: spinning threads at a duty cycle the scenario sets at any step (0 to 100% of
//!   each 10 ms slice). RFD 0124's legs run at 10x the cores: [`CpuLoad::cores_times`].
//! - [`RamLoad`]: resident memory the scenario grows and shrinks at any step. Every page is
//!   written, so it is resident, not only reserved. It never holds more than its ceiling
//!   (default [`RAM_CEILING_DEFAULT`], `CMUX_FAULT_RAM_MAX_MB` to change it), so a run on a shared
//!   host does not push other work into swap.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use crate::trace::Trace;

/// One duty-cycle slice: a thread spins `duty`% of it and sleeps the rest.
const SLICE: Duration = Duration::from_millis(10);

/// At most this many spinning threads, whatever a scenario asks.
pub const CPU_THREADS_MAX: usize = 256;

pub struct CpuLoad {
    stop: Arc<AtomicBool>,
    duty: Arc<AtomicU32>,
    spins: Arc<AtomicU64>,
    threads: Vec<JoinHandle<()>>,
    trace: Trace,
}

impl CpuLoad {
    /// `threads` spinning threads, idle (duty 0) until [`CpuLoad::set_duty`].
    pub fn start(threads: usize, trace: &Trace) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let duty = Arc::new(AtomicU32::new(0));
        let spins = Arc::new(AtomicU64::new(0));
        let threads = (0..threads.clamp(1, CPU_THREADS_MAX))
            .filter_map(|n| {
                let (stop, duty, spins) = (stop.clone(), duty.clone(), spins.clone());
                std::thread::Builder::new()
                    .name(format!("cmux-fault cpu {n}"))
                    .spawn(move || spin(&stop, &duty, &spins))
                    .ok()
            })
            .collect::<Vec<_>>();
        trace.note(format!("cpu load ready: {} threads", threads.len()));
        Self { stop, duty, spins, threads, trace: trace.clone() }
    }

    /// `times` threads per core this host has (RFD 0124's "load 10x cores" is 10).
    pub fn cores_times(times: usize, trace: &Trace) -> Self {
        let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
        Self::start(cores.saturating_mul(times), trace)
    }

    pub fn threads(&self) -> usize {
        self.threads.len()
    }

    /// Each thread spins this percent of every slice (clamped to 100); 0 is idle.
    pub fn set_duty(&self, percent: u32) {
        let percent = percent.min(100);
        if percent == 0 {
            self.trace.note("heal cpu");
        } else {
            self.trace.note(format!("fault cpu {percent}% x {} threads", self.threads.len()));
        }
        self.duty.store(percent, Ordering::SeqCst);
    }

    pub fn duty(&self) -> u32 {
        self.duty.load(Ordering::SeqCst)
    }

    /// Spin rounds done so far, across threads: proof the load ran.
    pub fn spins(&self) -> u64 {
        self.spins.load(Ordering::Relaxed)
    }
}

impl Drop for CpuLoad {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

fn spin(stop: &AtomicBool, duty: &AtomicU32, spins: &AtomicU64) {
    while !stop.load(Ordering::Relaxed) {
        let percent = duty.load(Ordering::Relaxed);
        let busy = SLICE * percent / 100;
        let started = Instant::now();
        let mut rounds = 0_u64;
        while started.elapsed() < busy {
            rounds = std::hint::black_box(rounds.wrapping_add(1));
        }
        if rounds > 0 {
            spins.fetch_add(rounds, Ordering::Relaxed);
        }
        let rest = SLICE.saturating_sub(started.elapsed());
        if !rest.is_zero() {
            std::thread::sleep(rest);
        }
    }
}

/// The default [`RamLoad`] ceiling: 512 MiB.
pub const RAM_CEILING_DEFAULT: u64 = 512 << 20;
/// The variable that sets the ceiling in MiB.
pub const RAM_ENV: &str = "CMUX_FAULT_RAM_MAX_MB";

const CHUNK: usize = 1 << 20;
const PAGE: usize = 4096;

pub struct RamLoad {
    chunks: Vec<Vec<u8>>,
    ceiling: u64,
    trace: Trace,
}

impl RamLoad {
    /// Nothing held; the ceiling from `CMUX_FAULT_RAM_MAX_MB`, else [`RAM_CEILING_DEFAULT`].
    pub fn new(trace: &Trace) -> Self {
        let ceiling = std::env::var(RAM_ENV)
            .ok()
            .and_then(|mb| mb.trim().parse::<u64>().ok())
            .map_or(RAM_CEILING_DEFAULT, |mb| mb << 20);
        Self::with_ceiling(ceiling, trace)
    }

    pub fn with_ceiling(ceiling: u64, trace: &Trace) -> Self {
        Self { chunks: Vec::new(), ceiling, trace: trace.clone() }
    }

    pub fn ceiling(&self) -> u64 {
        self.ceiling
    }

    /// Bytes held and resident now.
    pub fn held(&self) -> u64 {
        (self.chunks.len() * CHUNK) as u64
    }

    /// Grows or shrinks to `bytes` (rounded down to whole MiB, at most the ceiling).
    pub fn set(&mut self, bytes: u64) {
        let target = (bytes.min(self.ceiling) as usize) / CHUNK;
        if target == self.chunks.len() {
            return;
        }
        if target == 0 {
            self.trace.note("heal ram");
        } else {
            self.trace.note(format!("fault ram {} MiB held", target));
        }
        self.chunks.truncate(target);
        while self.chunks.len() < target {
            let mut chunk = vec![0_u8; CHUNK];
            // A write to every page makes it resident (a zeroed allocation is only mapped).
            for page in chunk.iter_mut().step_by(PAGE) {
                *page = 1;
            }
            self.chunks.push(std::hint::black_box(chunk));
        }
        self.chunks.shrink_to_fit();
    }

    /// The share of the ceiling, in percent.
    pub fn set_percent(&mut self, percent: u32) {
        self.set(self.ceiling.saturating_mul(u64::from(percent.min(100))) / 100);
    }
}

#[cfg(test)]
#[path = "load_tests.rs"]
mod tests;
