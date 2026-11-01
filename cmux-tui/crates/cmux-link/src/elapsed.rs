//! A captured elapsed-time source that includes system suspend. It supplies no
//! wall time or authority; callers still authenticate and bound their policy.
use std::sync::{Arc, Mutex};
use std::time::Duration;

type Source = dyn Fn() -> Option<Duration> + Send + Sync;

/// The kernel clock captured by `Elapsed::system`. Injected observations never
/// acquire a kernel identity, even if their numbers resemble a system clock.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KernelClock {
    Boottime,
    MachContinuous,
}

struct State {
    last: Duration,
    valid: bool,
}

/// Clones retain the original observation and its clock-failure latch. A failed
/// or backwards source cannot recover an old request when the clock catches up.
#[derive(Clone)]
pub struct Elapsed {
    source: Arc<Source>,
    started: Duration,
    state: Arc<Mutex<State>>,
    kernel_clock: Option<KernelClock>,
}

/// An expiry on a captured elapsed clock. Renewals replace the expiry while
/// retaining its clock and irreversible failure latch.
#[derive(Clone)]
pub struct Deadline {
    source: Elapsed,
    at: Duration,
}

impl PartialEq for Deadline {
    fn eq(&self, other: &Self) -> bool {
        self.at == other.at
            && self.source.started == other.source.started
            && Arc::ptr_eq(&self.source.state, &other.source.state)
    }
}
impl Eq for Deadline {}

impl Deadline {
    pub fn kernel_clock(&self) -> Option<KernelClock> {
        self.source.kernel_clock
    }

    pub fn remaining(&self) -> Option<Duration> {
        self.at.checked_sub(self.source.elapsed()?).filter(|left| !left.is_zero())
    }

    /// Only a Linux system-clock observation can arm a BOOTTIME descriptor.
    /// An injected clock or another platform never supplies an OS clock value.
    pub fn boottime(&self) -> Option<Duration> {
        if self.kernel_clock() != Some(KernelClock::Boottime) {
            return None;
        }
        self.remaining()?;
        self.source.started.checked_add(self.at)
    }

    pub fn shortened_by(&self, debit: Duration) -> Option<Self> {
        // A shortened wake may already be due. It must complete immediately,
        // rather than losing that wake while the original budget is still live.
        Some(Self { source: self.source.clone(), at: self.at.checked_sub(debit)? })
    }

    /// Retry scheduling keeps the owner's clock failure latch, while starting
    /// a new wait budget rather than extending an authority lease.
    pub fn after(&self, delay: Duration) -> Option<Self> {
        self.source.restart()?.deadline_at(delay)
    }

    pub(crate) fn bounded_by(mut self, other: Self) -> Option<Self> {
        if self.source.started != other.source.started
            || !Arc::ptr_eq(&self.source.state, &other.source.state)
        {
            return None;
        }
        self.at = self.at.min(other.at);
        self.remaining()?;
        Some(self)
    }
}

impl Elapsed {
    pub fn system() -> Option<Self> {
        let mut source = Self::capture(system_time)?;
        source.kernel_clock = if cfg!(target_os = "linux") {
            Some(KernelClock::Boottime)
        } else if cfg!(target_vendor = "apple") {
            Some(KernelClock::MachContinuous)
        } else {
            None
        };
        Some(source)
    }

    /// An explicit source permits tests to advance elapsed time while keeping
    /// active uptime frozen. Source values are local and never serialized.
    pub fn capture(source: impl Fn() -> Option<Duration> + Send + Sync + 'static) -> Option<Self> {
        let started = source()?;
        Some(Self {
            source: Arc::new(source),
            started,
            state: Arc::new(Mutex::new(State { last: started, valid: true })),
            kernel_clock: None,
        })
    }

    pub fn elapsed(&self) -> Option<Duration> {
        self.sample()?.checked_sub(self.started)
    }

    /// A new read starts a new budget on the same clock and failure latch.
    pub fn restart(&self) -> Option<Self> {
        Some(Self {
            source: self.source.clone(),
            started: self.sample()?,
            state: self.state.clone(),
            kernel_clock: self.kernel_clock,
        })
    }

    /// Shorten a captured budget without restarting it. Public remaining-time
    /// caps must debit both elapsed and active clocks by the same amount.
    pub fn rewind(&self, debit: Duration) -> Option<Self> {
        Some(Self {
            source: self.source.clone(),
            started: self.started.checked_sub(debit)?,
            state: self.state.clone(),
            kernel_clock: self.kernel_clock,
        })
    }

    /// `at` is elapsed since this observation, never wall time. Constructing an
    /// already expired deadline or losing its clock cannot produce authority.
    pub fn deadline_at(&self, at: Duration) -> Option<Deadline> {
        let deadline = Deadline { source: self.clone(), at };
        deadline.remaining()?;
        Some(deadline)
    }

    fn sample(&self) -> Option<Duration> {
        // Sample under the lock so concurrent callers cannot reorder readings
        // and mistake an older, delayed sample for a clock regression.
        let mut state = self.state.lock().ok()?;
        if !state.valid {
            return None;
        }
        match (self.source)().filter(|now| *now >= state.last) {
            Some(now) => {
                state.last = now;
                Some(now)
            }
            None => {
                state.valid = false;
                None
            }
        }
    }
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
fn system_time() -> Option<Duration> {
    #[cfg(target_os = "linux")]
    let clock = libc::CLOCK_BOOTTIME;
    #[cfg(target_vendor = "apple")]
    let clock = libc::CLOCK_MONOTONIC_RAW;
    let mut time = std::mem::MaybeUninit::<libc::timespec>::uninit();
    // SAFETY: time is a writable timespec; initialization is checked below.
    if unsafe { libc::clock_gettime(clock, time.as_mut_ptr()) } != 0 {
        return None;
    }
    // SAFETY: the successful call initialized time.
    let time = unsafe { time.assume_init() };
    if !(0..1_000_000_000).contains(&time.tv_nsec) {
        return None;
    }
    Some(Duration::new(time.tv_sec.try_into().ok()?, time.tv_nsec.try_into().ok()?))
}

#[cfg(not(any(target_os = "linux", target_vendor = "apple")))]
fn system_time() -> Option<Duration> {
    None
}
