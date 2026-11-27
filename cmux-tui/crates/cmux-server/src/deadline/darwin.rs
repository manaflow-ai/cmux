//! A continuous one-shot timer owned by the wait, without a worker thread.
use std::io;
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::Duration;

use cmux_link::elapsed::Deadline;
use tokio::io::{Interest, unix::AsyncFd};

pub(super) async fn expired(budget: Deadline) {
    if budget.remaining().is_none() {
        return;
    }
    let timer = match ContinuousTimer::new() {
        Ok(timer) => timer,
        Err(_) => return,
    };
    // A kqueue is readable when a timer is pending; it has no writable filter.
    let descriptor = match AsyncFd::with_interest(timer, Interest::READABLE) {
        Ok(descriptor) => descriptor,
        Err(_) => return,
    };
    let Some(remaining) = budget.remaining() else { return };
    if descriptor.get_ref().arm_after(remaining).is_err() {
        return;
    }
    super::descriptor_expired(budget, descriptor, ContinuousTimer::consume).await;
}

struct ContinuousTimer(OwnedFd);

impl AsRawFd for ContinuousTimer {
    fn as_raw_fd(&self) -> RawFd {
        self.0.as_raw_fd()
    }
}

impl ContinuousTimer {
    fn new() -> io::Result<Self> {
        // SAFETY: no pointers. Darwin creates kqueues close-on-exec and
        // close-on-fork; this queue belongs exclusively to the current wait.
        let fd = unsafe { libc::kqueue() };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: the successful syscall returned a fresh, exclusively owned fd.
        Ok(Self(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    fn arm_after(&self, remaining: Duration) -> io::Result<()> {
        let nanoseconds =
            remaining.as_nanos().try_into().map_err(|_| io::ErrorKind::InvalidInput)?;
        if remaining.is_zero() {
            return Err(io::ErrorKind::InvalidInput.into());
        }
        // An interval with this flag uses continuous time and ticks through
        // sleep. NOTE_ABSOLUTE without NOTE_MACHTIME would use the wall epoch.
        let change = libc::kevent64_s {
            ident: 1,
            filter: libc::EVFILT_TIMER,
            flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
            fflags: libc::NOTE_NSECONDS | libc::NOTE_MACH_CONTINUOUS_TIME | libc::NOTE_CRITICAL,
            data: nanoseconds,
            udata: 0,
            ext: [0; 2],
        };
        // SAFETY: change names one initialized entry. With no output entries
        // this registers the timer without waiting; errors use errno.
        let result = unsafe {
            libc::kevent64(
                self.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                0,
                std::ptr::null(),
            )
        };
        if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
    }

    fn consume(&self) -> io::Result<()> {
        let mut event = MaybeUninit::<libc::kevent64_s>::uninit();
        let timeout = libc::timespec { tv_sec: 0, tv_nsec: 0 };
        loop {
            // SAFETY: one writable event, initialized only on result=1. The
            // zero timeout makes this safe for AsyncFd's nonblocking callback.
            let result = unsafe {
                libc::kevent64(
                    self.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    event.as_mut_ptr(),
                    1,
                    0,
                    &timeout,
                )
            };
            if result < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error);
            }
            if result == 0 {
                return Err(io::ErrorKind::WouldBlock.into());
            }
            // SAFETY: kevent64 wrote exactly one event.
            let event = unsafe { event.assume_init() };
            if event.flags & libc::EV_ERROR != 0 {
                let errno = event.data.try_into().map_err(|_| io::ErrorKind::InvalidData)?;
                return Err(io::Error::from_raw_os_error(errno));
            }
            return if event.ident == 1 && event.filter == libc::EVFILT_TIMER && event.data > 0 {
                Ok(())
            } else {
                Err(io::ErrorKind::InvalidData.into())
            };
        }
    }
}
