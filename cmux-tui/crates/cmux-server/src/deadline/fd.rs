//! Owned Linux timer descriptors shared by the agent and HTTP runtime.
use super::ArmError;
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::Duration;

fn cvt(ret: libc::c_int) -> io::Result<libc::c_int> {
    if ret < 0 { Err(io::Error::last_os_error()) } else { Ok(ret) }
}

fn owned(ret: libc::c_int) -> io::Result<OwnedFd> {
    // SAFETY: `ret` is a fresh descriptor this process owns exclusively.
    cvt(ret).map(|fd| unsafe { OwnedFd::from_raw_fd(fd) })
}

/// Reads into `buf`; `Ok(None)` on `EAGAIN`.
fn read_fd(fd: RawFd, buf: &mut [u8]) -> io::Result<Option<usize>> {
    loop {
        // SAFETY: `buf` is valid for `buf.len()` writable bytes.
        let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
        if n >= 0 {
            return Ok(Some(n as usize));
        }
        let err = io::Error::last_os_error();
        match err.raw_os_error() {
            Some(libc::EINTR) => continue,
            Some(libc::EAGAIN) => return Ok(None),
            _ => return Err(err),
        }
    }
}

#[derive(Clone, Copy)]
pub enum Clock {
    Realtime,
    Monotonic,
    Boottime,
}

pub struct TimerFd(OwnedFd);

impl AsRawFd for TimerFd {
    fn as_raw_fd(&self) -> RawFd {
        self.raw()
    }
}

impl TimerFd {
    pub fn new(clock: Clock) -> io::Result<Self> {
        let id = match clock {
            Clock::Realtime => libc::CLOCK_REALTIME,
            Clock::Monotonic => libc::CLOCK_MONOTONIC,
            Clock::Boottime => libc::CLOCK_BOOTTIME,
        };
        // SAFETY: plain syscall.
        owned(unsafe { libc::timerfd_create(id, libc::TFD_NONBLOCK | libc::TFD_CLOEXEC) }).map(Self)
    }

    pub fn raw(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    fn settime(&self, flags: libc::c_int, value: libc::timespec) -> io::Result<()> {
        let spec = libc::itimerspec {
            it_interval: libc::timespec { tv_sec: 0, tv_nsec: 0 },
            it_value: value,
        };
        // SAFETY: `spec` outlives the call; the old value is not requested.
        cvt(unsafe { libc::timerfd_settime(self.raw(), flags, &spec, std::ptr::null_mut()) })
            .map(drop)
    }

    /// Arms an absolute deadline ten years ahead with
    /// `TFD_TIMER_CANCEL_ON_SET`: the descriptor becomes readable (and the
    /// read fails with `ECANCELED`) whenever the realtime clock is set.
    pub fn arm_clock_set(&self) -> Result<(), ArmError> {
        let mut now = MaybeUninit::<libc::timespec>::uninit();
        // SAFETY: `now` is written by the call.
        if unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, now.as_mut_ptr()) } < 0 {
            return Err(ArmError::Other(io::Error::last_os_error().raw_os_error().unwrap_or(0)));
        }
        // SAFETY: initialized by the successful call above.
        let now = unsafe { now.assume_init() };
        let value = libc::timespec { tv_sec: now.tv_sec + 10 * 365 * 86_400, tv_nsec: 0 };
        match self.settime(libc::TFD_TIMER_ABSTIME | libc::TFD_TIMER_CANCEL_ON_SET, value) {
            Ok(()) => Ok(()),
            Err(err) if err.raw_os_error() == Some(libc::ECANCELED) => Err(ArmError::Cancelled),
            Err(err) => Err(ArmError::Other(err.raw_os_error().unwrap_or(0))),
        }
    }

    /// One-shot relative timer.
    pub fn arm_after(&self, delay: Duration) -> io::Result<()> {
        let delay = delay.max(Duration::from_millis(1));
        let value = libc::timespec {
            tv_sec: delay.as_secs() as libc::time_t,
            tv_nsec: delay.subsec_nanos() as libc::c_long,
        };
        self.settime(0, value)
    }

    /// Absolute time on this descriptor's clock. Zero would disarm the timer,
    /// so it is refused rather than silently removing an expiry boundary.
    pub fn arm_at(&self, deadline: Duration) -> io::Result<()> {
        if deadline.is_zero() {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        let value = libc::timespec {
            tv_sec: deadline.as_secs().try_into().map_err(|_| io::ErrorKind::InvalidInput)?,
            tv_nsec: deadline.subsec_nanos().into(),
        };
        self.settime(libc::TFD_TIMER_ABSTIME, value)
    }

    pub fn read_expirations(&self) -> io::Result<u64> {
        let mut bytes = [0; 8];
        match read_fd(self.raw(), &mut bytes)? {
            Some(8) => Ok(u64::from_ne_bytes(bytes)),
            None => Err(io::ErrorKind::WouldBlock.into()),
            Some(_) => Err(io::ErrorKind::UnexpectedEof.into()),
        }
    }

    pub fn disarm(&self) -> io::Result<()> {
        self.settime(0, libc::timespec { tv_sec: 0, tv_nsec: 0 })
    }

    /// Consumes a readable state. `ECANCELED` (clock set) counts as fired.
    pub fn drain(&self) {
        let mut buf = [0u8; 8];
        let _ = read_fd(self.raw(), &mut buf);
    }
}
