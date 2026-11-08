//! The bound on `server ensure`'s wait for a restoring owner: it measures the
//! owner's work, not wall time.
//!
//! An owner restores its session before it answers `identify` (it parks its
//! connections), and a large registry can make that take many minutes. A
//! fixed 120 s bound killed such owners partway (2026-11-08: a 59 GB
//! registry, every owner killed at 120 s and a new one spawned, so none ever
//! finished and the app never connected). The wait now ends only once the
//! owner has done no work for [`RESTORE_DEADLINE`]: its CPU time and disk
//! bytes, read from the kernel by pid, are its progress. A restoring owner
//! (scanning the registry, copying tables) advances them; a deadlocked or
//! blocked one does not. Where the kernel's counters cannot be read (Linux,
//! whose `/proc` stays out of product code, and Windows) the bound is the
//! old fixed one.

use std::cell::Cell;
use std::time::{Duration, Instant};

use super::RESTORE_DEADLINE;

/// The least CPU time between two readings that counts as work. An owner's
/// idle threads (log writer, memory guard) use far less than this in a
/// reading interval; a restoring owner uses a core.
const MIN_CPU: Duration = Duration::from_millis(100);

/// The least disk traffic (read plus written) between two readings that
/// counts as work.
const MIN_DISK_BYTES: u64 = 1024 * 1024;

/// How often the owner's counters are read.
const READ_INTERVAL: Duration = Duration::from_secs(1);

/// An owner's cumulative work, as the kernel counts it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Work {
    pub cpu: Duration,
    pub disk_bytes: u64,
}

impl Work {
    /// Whether `self` is enough more work than `earlier` to count as progress.
    pub(crate) fn advanced_from(self, earlier: Work) -> bool {
        self.cpu.saturating_sub(earlier.cpu) >= MIN_CPU
            || self.disk_bytes.saturating_sub(earlier.disk_bytes) >= MIN_DISK_BYTES
    }
}

/// The work of process `pid` so far, or `None` when it cannot be read.
#[cfg(target_vendor = "apple")]
pub(crate) fn process_work(pid: u32) -> Option<Work> {
    let pid = i32::try_from(pid).ok()?;
    // SAFETY: an all-zero rusage_info_v2 is a valid out-buffer.
    let mut info: libc::rusage_info_v2 = unsafe { std::mem::zeroed() };
    // SAFETY: the buffer is a rusage_info_v2, the flavor RUSAGE_INFO_V2 writes.
    let read = unsafe {
        libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V2, (&raw mut info).cast::<libc::rusage_info_t>())
    };
    if read != 0 {
        return None;
    }
    // The times are in Mach absolute time units (not nanoseconds on Apple
    // silicon).
    let mut timebase = libc::mach_timebase_info { numer: 0, denom: 0 };
    // SAFETY: the out-pointer is valid.
    if unsafe { libc::mach_timebase_info(&raw mut timebase) } != 0 || timebase.denom == 0 {
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

/// The deadline of one ensure's wait on a restoring owner.
pub(crate) struct RestoreBound {
    /// The bound with no work seen: the wait's start plus the stall bound,
    /// or the caller's later deadline.
    floor: Instant,
    stall: Duration,
    /// The last time the owner was seen working.
    last_progress: Cell<Option<Instant>>,
    owner: Cell<Option<u32>>,
    mark: Cell<Option<Work>>,
    last_read: Cell<Option<Instant>>,
    read: fn(u32) -> Option<Work>,
}

impl RestoreBound {
    pub(crate) fn new(deadline: Instant) -> Self {
        Self::with(deadline, RESTORE_DEADLINE, process_work)
    }

    pub(crate) fn with(deadline: Instant, stall: Duration, read: fn(u32) -> Option<Work>) -> Self {
        Self {
            floor: deadline.max(Instant::now() + stall),
            stall,
            last_progress: Cell::new(None),
            owner: Cell::new(None),
            mark: Cell::new(None),
            last_read: Cell::new(None),
            read,
        }
    }

    /// The owner the wait is on, when a probe, the socket's listener or the
    /// spawn names it. Another pid starts its measurement over.
    pub(crate) fn note_owner(&self, pid: Option<u64>) {
        let Some(pid) = pid.and_then(|pid| u32::try_from(pid).ok()) else { return };
        if self.owner.get() != Some(pid) {
            self.owner.set(Some(pid));
            self.mark.set(None);
            self.last_read.set(None);
        }
    }

    /// Reads the owner's work (at most once per [`READ_INTERVAL`]); more work
    /// than at the last mark moves the deadline to a full stall bound from now.
    fn sample(&self) {
        let Some(pid) = self.owner.get() else { return };
        let now = Instant::now();
        if self.last_read.get().is_some_and(|read| now.duration_since(read) < READ_INTERVAL) {
            return;
        }
        self.last_read.set(Some(now));
        let Some(work) = (self.read)(pid) else { return };
        match self.mark.get() {
            None => self.mark.set(Some(work)),
            Some(mark) if work.advanced_from(mark) => {
                self.mark.set(Some(work));
                self.last_progress.set(Some(now));
            }
            Some(_) => {}
        }
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
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::*;

    static CPU_MS: AtomicU64 = AtomicU64::new(0);

    fn fake_work(_pid: u32) -> Option<Work> {
        Some(Work { cpu: Duration::from_millis(CPU_MS.load(Ordering::SeqCst)), disk_bytes: 0 })
    }

    fn no_counters(_pid: u32) -> Option<Work> {
        None
    }

    #[test]
    fn a_working_owner_keeps_the_wait_past_the_stall_bound_and_a_stalled_one_ends_it() {
        let stall = Duration::from_millis(2_500);
        let started = Instant::now();
        let bound = RestoreBound::with(started, stall, fake_work);
        bound.note_owner(Some(42));
        // Work for twice the stall bound: one reading per interval, each a
        // core-second more.
        while started.elapsed() < stall * 2 {
            CPU_MS.fetch_add(1_000, Ordering::SeqCst);
            assert!(!bound.expired(), "a working owner timed out at {:?}", started.elapsed());
            std::thread::sleep(READ_INTERVAL);
        }
        // Then no work: the wait ends one stall bound after the last progress.
        let stalled = Instant::now();
        while !bound.expired() {
            assert!(stalled.elapsed() < stall + READ_INTERVAL * 3, "a stalled owner kept the wait");
            std::thread::sleep(Duration::from_millis(100));
        }
        assert!(stalled.elapsed() + READ_INTERVAL * 2 >= stall);
    }

    #[test]
    fn idle_threads_are_not_progress() {
        let earlier = Work { cpu: Duration::from_millis(500), disk_bytes: 10 };
        let idle = Work { cpu: Duration::from_millis(520), disk_bytes: 4_000 };
        assert!(!idle.advanced_from(earlier));
        let scanning = Work { cpu: Duration::from_millis(500), disk_bytes: 10 + MIN_DISK_BYTES };
        assert!(scanning.advanced_from(earlier));
    }

    #[test]
    fn without_counters_the_bound_is_fixed() {
        let stall = Duration::from_millis(300);
        let bound = RestoreBound::with(Instant::now(), stall, no_counters);
        bound.note_owner(Some(42));
        assert!(!bound.expired());
        std::thread::sleep(stall + Duration::from_millis(50));
        assert!(bound.expired());
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn this_process_reports_its_own_work() {
        let work = process_work(std::process::id()).expect("own counters");
        let spin = Instant::now();
        let mut x = 0_u64;
        while spin.elapsed() < Duration::from_millis(300) {
            x = std::hint::black_box(x.wrapping_add(1));
        }
        let later = process_work(std::process::id()).expect("own counters");
        assert!(later.advanced_from(work), "{work:?} -> {later:?}");
    }
}
