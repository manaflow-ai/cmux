//! The bound on `server ensure`'s wait for a restoring owner: it measures the
//! owner's work, not wall time.
//!
//! An owner restores its session before it answers `identify` (it parks its
//! connections), and a large registry can make that take many minutes. A
//! fixed 120 s bound killed such owners partway (2026-11-08: a 59 GB
//! registry, every owner killed at 120 s and a new one spawned, so none ever
//! finished and the app never connected). The wait now ends only once the
//! owner has done no work for [`RESTORE_DEADLINE`]: its CPU time and disk
//! bytes, read from the kernel by pid and measured over a sliding window
//! ([`WINDOW`]), are its progress. A restoring owner
//! (scanning the registry, copying tables) advances them; a deadlocked or
//! blocked one does not. Where the kernel's counters cannot be read (Linux,
//! whose `/proc` stays out of product code, and Windows) the bound is the
//! old fixed one.

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::RESTORE_DEADLINE;

/// The span the owner's work is measured over. Progress is the work done
/// within the last window only: nothing carries over from earlier windows,
/// so idle threads' trickle never adds up to progress.
const WINDOW: Duration = Duration::from_secs(10);

/// How often the owner's counters are read.
const READ_INTERVAL: Duration = Duration::from_secs(1);

/// The least share of one core, over a window, that counts as work: 5%, or
/// 500 ms per 10 s. An owner's idle threads (log writer, memory guard) use
/// well under 1%; a restoring owner's main thread runs flat out, and still
/// gets several times this on a box at load 100 (15 cores).
const MIN_CPU_PER_MILLE: u128 = 50;

/// The least disk traffic (read plus written) per second of window that
/// counts as work: 4 MiB per 10 s.
const MIN_DISK_BYTES_PER_SEC: u64 = 400 * 1024;

/// An owner's cumulative work, as the kernel counts it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Work {
    pub cpu: Duration,
    pub disk_bytes: u64,
}

impl Work {
    /// Whether `self` is enough more work than `earlier`, taken `span`
    /// before it, to count as progress.
    pub(crate) fn advanced_from(self, earlier: Work, span: Duration) -> bool {
        let cpu = self.cpu.saturating_sub(earlier.cpu).as_micros();
        let disk = self.disk_bytes.saturating_sub(earlier.disk_bytes);
        cpu * 1000 >= span.as_micros() * MIN_CPU_PER_MILLE
            || u128::from(disk) * 1_000_000 >= span.as_micros() * u128::from(MIN_DISK_BYTES_PER_SEC)
    }
}

/// `mach_timebase_info_data_t` (`<mach/mach_time.h>`). Declared here because
/// libc deprecates its copy in favour of the `mach2` crate, which no crate of
/// this workspace depends on directly.
#[cfg(target_vendor = "apple")]
#[repr(C)]
struct Timebase {
    numer: u32,
    denom: u32,
}

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    /// `mach_timebase_info(3)`: the ratio of Mach absolute time units to nanoseconds.
    fn mach_timebase_info(info: *mut Timebase) -> libc::c_int;
}

/// The work of process `pid` so far, or `None` when it cannot be read.
#[cfg(target_vendor = "apple")]
pub(crate) fn process_work(pid: u32) -> Option<Work> {
    let pid = i32::try_from(pid).ok()?;
    // SAFETY: an all-zero rusage_info_v2 is a valid out-buffer.
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: the buffer is a rusage_info_v2, the flavor RUSAGE_INFO_V2 writes.
    let read = unsafe {
        libc::proc_pid_rusage(
            pid,
            libc::RUSAGE_INFO_V2,
            (&raw mut info).cast::<libc::rusage_info_t>(),
        )
    };
    if read != 0 {
        return None;
    }
    // The times are in Mach absolute time units (not nanoseconds on Apple
    // silicon).
    let mut timebase = Timebase { numer: 0, denom: 0 };
    // SAFETY: the out-pointer is a valid `mach_timebase_info_data_t`.
    if unsafe { mach_timebase_info(&raw mut timebase) } != 0 || timebase.denom == 0 {
        return None;
    }
    let ticks = u128::from(info.ri_user_time) + u128::from(info.ri_system_time);
    let nanos = ticks * u128::from(timebase.numer) / u128::from(timebase.denom);
    Some(Work {
        cpu: Duration::from_nanos(u64::try_from(nanos).unwrap_or(u64::MAX)),
        disk_bytes: info.ri_diskio_bytesread.saturating_add(info.ri_diskio_byteswritten),
    })
}

#[cfg(not(target_vendor = "apple"))]
pub(crate) fn process_work(_pid: u32) -> Option<Work> {
    None
}

/// The stall bound: [`RESTORE_DEADLINE`], or a debug build's
/// `CMUX_TUI_DEBUG_RESTORE_STALL_MS` (behavior tests of the bound).
fn restore_stall() -> Duration {
    #[cfg(debug_assertions)]
    if let Some(ms) =
        std::env::var("CMUX_TUI_DEBUG_RESTORE_STALL_MS").ok().and_then(|value| value.parse().ok())
    {
        return Duration::from_millis(ms);
    }
    RESTORE_DEADLINE
}

/// The window and read interval for a stall bound: [`WINDOW`] and
/// [`READ_INTERVAL`], or shorter for a short bound (a debug build's), so a
/// working owner shows progress within a third of the bound and is read at
/// least four times per window.
fn window_for(stall: Duration) -> (Duration, Duration) {
    let window = WINDOW.min(stall / 3).max(Duration::from_millis(100));
    (window, READ_INTERVAL.min(window / 4))
}

/// Debug seams for behavior tests of a long restore, run by the owner after
/// it binds its socket and before it restores: `CMUX_TUI_DEBUG_SLOW_RESTORE_MS`
/// keeps a core busy that long (an owner that works, as one scanning a large
/// registry does), `CMUX_TUI_DEBUG_IDLE_RESTORE_MS` sleeps that long (an owner
/// that does no work, as a deadlocked one). Off in release builds.
pub(crate) fn debug_slow_restore() {
    #[cfg(debug_assertions)]
    {
        let ms = |name: &str| {
            std::env::var(name)
                .ok()
                .and_then(|value| value.parse::<u64>().ok())
                .map(Duration::from_millis)
        };
        if let Some(busy) = ms("CMUX_TUI_DEBUG_SLOW_RESTORE_MS") {
            let started = Instant::now();
            let mut spin = 0_u64;
            while started.elapsed() < busy {
                spin = std::hint::black_box(spin.wrapping_add(1));
            }
        }
        if let Some(idle) = ms("CMUX_TUI_DEBUG_IDLE_RESTORE_MS") {
            std::thread::sleep(idle);
        }
    }
}

/// The deadline of one ensure's wait on a restoring owner.
pub(crate) struct RestoreBound {
    /// The bound with no work seen: the wait's start plus the stall bound,
    /// or the caller's later deadline.
    floor: Instant,
    stall: Duration,
    window: Duration,
    read_interval: Duration,
    /// The last time a window ended with enough work in it.
    last_progress: Cell<Option<Instant>>,
    owner: Cell<Option<u32>>,
    /// Readings of the owner's counters, oldest first, kept for one window.
    samples: RefCell<VecDeque<(Instant, Work)>>,
    read: fn(u32) -> Option<Work>,
}

impl RestoreBound {
    pub(crate) fn new(deadline: Instant) -> Self {
        let stall = restore_stall();
        let (window, read_interval) = window_for(stall);
        Self::with(deadline, stall, window, read_interval, process_work)
    }

    pub(crate) fn with(
        deadline: Instant,
        stall: Duration,
        window: Duration,
        read_interval: Duration,
        read: fn(u32) -> Option<Work>,
    ) -> Self {
        Self {
            floor: deadline.max(Instant::now() + stall),
            stall,
            window,
            read_interval,
            last_progress: Cell::new(None),
            owner: Cell::new(None),
            samples: RefCell::new(VecDeque::new()),
            read,
        }
    }

    /// The owner the wait is on, when a probe, the socket's listener or the
    /// spawn names it. Another pid starts its measurement over.
    pub(crate) fn note_owner(&self, pid: Option<u64>) {
        let Some(pid) = pid.and_then(|pid| u32::try_from(pid).ok()) else { return };
        if self.owner.get() != Some(pid) {
            self.owner.set(Some(pid));
            self.samples.borrow_mut().clear();
        }
    }

    /// Reads the owner's work (at most once per read interval). When the
    /// work done since the reading one window ago is enough, the deadline
    /// moves to a full stall bound from now.
    fn sample(&self) {
        let Some(pid) = self.owner.get() else { return };
        let now = Instant::now();
        let mut samples = self.samples.borrow_mut();
        if samples.back().is_some_and(|(read, _)| now.duration_since(*read) < self.read_interval) {
            return;
        }
        let Some(work) = (self.read)(pid) else { return };
        // The newest reading at least one window old is the window's start;
        // older ones are dropped.
        while samples.get(1).is_some_and(|(read, _)| now.duration_since(*read) >= self.window) {
            samples.pop_front();
        }
        if let Some(&(read, start)) = samples.front() {
            let span = now.duration_since(read);
            if span >= self.window && work.advanced_from(start, span) {
                self.last_progress.set(Some(now));
            }
        }
        samples.push_back((now, work));
    }

    /// The deadline now.
    pub(crate) fn deadline(&self) -> Instant {
        self.sample();
        match self.last_progress.get() {
            Some(progress) => self.floor.max(progress + self.stall),
            None => self.floor,
        }
    }

    /// Whether the owner has done no work for the stall bound (or, with no
    /// readable counters, the fixed bound has passed).
    pub(crate) fn expired(&self) -> bool {
        Instant::now() >= self.deadline()
    }
}

#[cfg(test)]
mod tests;
