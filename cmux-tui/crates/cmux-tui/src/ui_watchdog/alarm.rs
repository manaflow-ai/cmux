//! The watchdog thread's wake-up: a one-shot kernel timer the UI thread arms at each turn's start
//! and disarms at its end, plus a stop/wake event. Arming and disarming are one syscall each and
//! wake nobody, so a turn shorter than the threshold costs the watchdog thread nothing, and an idle
//! loop leaves it parked in the kernel with no timeout (the Mac app's `MainThreadWatchdogAlarm`).
//!
//! Linux: a `timerfd` and an `eventfd` under `poll`. macOS: a kqueue with an `EVFILT_TIMER` and an
//! `EVFILT_USER`. Elsewhere a condvar stands in; arming it wakes the watchdog once per turn.

#[cfg(target_os = "linux")]
use std::time::Duration;

pub(crate) use imp::Alarm;

#[cfg(target_os = "linux")]
fn millis_ceil(duration: Duration) -> i32 {
    let millis = duration.as_nanos().div_ceil(1_000_000);
    i32::try_from(millis).unwrap_or(i32::MAX)
}

#[cfg(target_os = "linux")]
mod imp {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::Duration;

    pub(crate) struct Alarm {
        timer: OwnedFd,
        event: OwnedFd,
    }

    impl Alarm {
        pub(crate) fn new() -> std::io::Result<Self> {
            // SAFETY: plain fd-creating syscalls; each result is checked before it is owned.
            unsafe {
                let timer = libc::timerfd_create(
                    libc::CLOCK_MONOTONIC,
                    libc::TFD_CLOEXEC | libc::TFD_NONBLOCK,
                );
                if timer < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let timer = OwnedFd::from_raw_fd(timer);
                let event = libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK);
                if event < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(Alarm { timer, event: OwnedFd::from_raw_fd(event) })
            }
        }

        fn set(&self, after: Duration) {
            let value = libc::timespec {
                tv_sec: libc::time_t::try_from(after.as_secs()).unwrap_or(libc::time_t::MAX),
                tv_nsec: after.subsec_nanos() as libc::c_long,
            };
            let spec = libc::itimerspec {
                it_interval: libc::timespec { tv_sec: 0, tv_nsec: 0 },
                it_value: value,
            };
            // SAFETY: a valid timerfd and a fully initialized itimerspec.
            unsafe {
                libc::timerfd_settime(self.timer.as_raw_fd(), 0, &spec, std::ptr::null_mut());
            }
        }

        /// Fires once, `after` from now (a zero duration is bumped to 1 ns: zero disarms).
        pub(crate) fn arm(&self, after: Duration) {
            self.set(after.max(Duration::from_nanos(1)));
        }

        pub(crate) fn disarm(&self) {
            self.set(Duration::ZERO);
        }

        /// Wakes a waiter now (stop).
        pub(crate) fn wake(&self) {
            let one: u64 = 1;
            // SAFETY: an 8-byte write to a valid eventfd.
            unsafe {
                libc::write(self.event.as_raw_fd(), (&one as *const u64).cast(), 8);
            }
        }

        /// Blocks until the timer fires, a wake, or `timeout` (`None`: no timeout).
        pub(crate) fn wait(&self, timeout: Option<Duration>) {
            let mut fds = [
                libc::pollfd { fd: self.timer.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.event.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            ];
            let timeout = timeout.map_or(-1, super::millis_ceil);
            // SAFETY: two initialized pollfds; reads of 8 bytes into a u64 on nonblocking fds.
            unsafe {
                libc::poll(fds.as_mut_ptr(), 2, timeout);
                let mut count: u64 = 0;
                for fd in [self.timer.as_raw_fd(), self.event.as_raw_fd()] {
                    libc::read(fd, (&mut count as *mut u64).cast(), 8);
                }
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::Duration;

    const TIMER: libc::uintptr_t = 1;
    const USER: libc::uintptr_t = 2;

    pub(crate) struct Alarm {
        queue: OwnedFd,
    }

    fn event(
        ident: libc::uintptr_t,
        filter: i16,
        flags: u16,
        fflags: u32,
        data: isize,
    ) -> libc::kevent {
        libc::kevent { ident, filter, flags, fflags, data, udata: std::ptr::null_mut() }
    }

    impl Alarm {
        pub(crate) fn new() -> std::io::Result<Self> {
            // SAFETY: kqueue() returns a new fd or -1; the registration passes one valid kevent.
            unsafe {
                let queue = libc::kqueue();
                if queue < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                let queue = OwnedFd::from_raw_fd(queue);
                libc::fcntl(queue.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
                let user = event(USER, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0, 0);
                let alarm = Alarm { queue };
                if alarm.change(&user) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(alarm)
            }
        }

        fn change(&self, change: &libc::kevent) -> i32 {
            // SAFETY: one valid change, no event list.
            unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            }
        }

        pub(crate) fn arm(&self, after: Duration) {
            let micros = isize::try_from(after.as_micros()).unwrap_or(isize::MAX).max(1);
            self.change(&event(
                TIMER,
                libc::EVFILT_TIMER,
                libc::EV_ADD | libc::EV_ONESHOT,
                libc::NOTE_USECONDS,
                micros,
            ));
        }

        pub(crate) fn disarm(&self) {
            // ENOENT when it already fired: nothing to do.
            self.change(&event(TIMER, libc::EVFILT_TIMER, libc::EV_DELETE, 0, 0));
        }

        pub(crate) fn wake(&self) {
            self.change(&event(USER, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER, 0));
        }

        pub(crate) fn wait(&self, timeout: Option<Duration>) {
            let spec = timeout.map(|timeout| libc::timespec {
                tv_sec: libc::time_t::try_from(timeout.as_secs()).unwrap_or(libc::time_t::MAX),
                tv_nsec: timeout.subsec_nanos() as libc::c_long,
            });
            let mut out = [event(0, 0, 0, 0, 0); 2];
            // SAFETY: an out buffer of two kevents and an optional valid timespec.
            unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    out.as_mut_ptr(),
                    2,
                    spec.as_ref().map_or(std::ptr::null(), |spec| spec as *const _),
                );
            }
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod imp {
    use std::sync::{Condvar, Mutex};
    use std::time::{Duration, Instant};

    #[derive(Default)]
    struct State {
        deadline: Option<Instant>,
        woken: bool,
    }

    #[derive(Default)]
    pub(crate) struct Alarm {
        state: Mutex<State>,
        changed: Condvar,
    }

    impl Alarm {
        pub(crate) fn new() -> std::io::Result<Self> {
            Ok(Alarm::default())
        }

        fn state(&self) -> std::sync::MutexGuard<'_, State> {
            self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
        }

        pub(crate) fn arm(&self, after: Duration) {
            self.state().deadline = Some(Instant::now() + after);
            self.changed.notify_all();
        }

        pub(crate) fn disarm(&self) {
            self.state().deadline = None;
        }

        pub(crate) fn wake(&self) {
            self.state().woken = true;
            self.changed.notify_all();
        }

        pub(crate) fn wait(&self, timeout: Option<Duration>) {
            let limit = timeout.map(|timeout| Instant::now() + timeout);
            let mut state = self.state();
            loop {
                if std::mem::take(&mut state.woken) {
                    return;
                }
                let now = Instant::now();
                let until = match (state.deadline, limit) {
                    (Some(a), Some(b)) => Some(a.min(b)),
                    (a, b) => a.or(b),
                };
                match until {
                    Some(until) if until <= now => {
                        if state.deadline.is_some_and(|deadline| deadline <= now) {
                            state.deadline = None;
                        }
                        return;
                    }
                    Some(until) => {
                        state = self
                            .changed
                            .wait_timeout(state, until - now)
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .0;
                    }
                    None => {
                        state = self
                            .changed
                            .wait(state)
                            .unwrap_or_else(std::sync::PoisonError::into_inner);
                    }
                }
            }
        }
    }
}
