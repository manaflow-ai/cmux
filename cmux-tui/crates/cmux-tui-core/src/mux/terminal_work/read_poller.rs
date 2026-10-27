//! The readiness poller under [`super::read_loop`]: kqueue on macOS and the
//! BSDs, epoll on Linux, as Chromium's `MessagePumpKqueue`
//! (base/message_loop/message_pump_kqueue.cc) and `MessagePumpEpoll`
//! (base/message_loop/message_pump_epoll.cc).
//!
//! Every descriptor is watched one-shot: a delivered readiness disarms it
//! until [`Poller::rearm`] (`EV_DISPATCH` / `EPOLLONESHOT`), so one source
//! never has two runs in flight. [`Poller::wake`] interrupts a [`Poller::wait`]
//! that has no timeout (`EVFILT_USER` / an eventfd): the poller has no timer
//! and an idle loop never wakes.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

/// The token [`Poller::wait`] reports for a [`Poller::wake`].
pub(super) const WAKE_TOKEN: u64 = u64::MAX;

/// Readiness events one [`Poller::wait`] returns at most.
const EVENTS_PER_WAIT: usize = 64;

fn retry_interrupted(mut call: impl FnMut() -> libc::c_int) -> io::Result<libc::c_int> {
    loop {
        let result = call();
        if result >= 0 {
            return Ok(result);
        }
        let error = io::Error::last_os_error();
        if error.kind() != io::ErrorKind::Interrupted {
            return Err(error);
        }
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub(super) struct Poller {
    queue: OwnedFd,
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
impl Poller {
    pub(super) fn new() -> io::Result<Self> {
        // SAFETY: kqueue takes no arguments and returns a fresh descriptor.
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a successful kqueue returned a descriptor this poller owns.
        let poller = Self { queue: unsafe { OwnedFd::from_raw_fd(queue) } };
        // SAFETY: fcntl on the descriptor this poller owns.
        if unsafe { libc::fcntl(poller.queue.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
            return Err(io::Error::last_os_error());
        }
        poller.change(0, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0, WAKE_TOKEN)?;
        Ok(poller)
    }

    fn change(
        &self,
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        token: u64,
    ) -> io::Result<()> {
        let change = libc::kevent {
            ident,
            filter,
            flags,
            fflags,
            data: 0,
            udata: token as usize as *mut libc::c_void,
        };
        // SAFETY: one valid change, no event output, and the queue is owned.
        retry_interrupted(|| unsafe {
            libc::kevent(
                self.queue.as_raw_fd(),
                &change,
                1,
                std::ptr::null_mut(),
                0,
                std::ptr::null(),
            )
        })
        .map(drop)
    }

    /// Watches `fd` for input (or its end) under `token`, armed.
    pub(super) fn add(&self, fd: RawFd, token: u64) -> io::Result<()> {
        self.change(fd as usize, libc::EVFILT_READ, libc::EV_ADD | libc::EV_DISPATCH, 0, token)
    }

    /// Arms `fd` again after a delivered readiness.
    pub(super) fn rearm(&self, fd: RawFd, token: u64) -> io::Result<()> {
        self.change(fd as usize, libc::EVFILT_READ, libc::EV_ENABLE | libc::EV_DISPATCH, 0, token)
    }

    /// Stops watching `fd`; call it before `fd` closes.
    pub(super) fn delete(&self, fd: RawFd) -> io::Result<()> {
        self.change(fd as usize, libc::EVFILT_READ, libc::EV_DELETE, 0, 0)
    }

    /// Ends the [`Poller::wait`] in progress, or the next one.
    pub(super) fn wake(&self) -> io::Result<()> {
        self.change(0, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER, WAKE_TOKEN)
    }

    /// Blocks until at least one watched descriptor is ready or a wake, and
    /// replaces `tokens` with what is ready.
    pub(super) fn wait(&self, tokens: &mut Vec<u64>) -> io::Result<()> {
        // SAFETY: an all-zero kevent is a valid output slot.
        let mut events: [libc::kevent; EVENTS_PER_WAIT] = unsafe { std::mem::zeroed() };
        // SAFETY: the queue is owned and `events` is writable for its length;
        // a null timeout waits without a timer.
        let count = retry_interrupted(|| unsafe {
            libc::kevent(
                self.queue.as_raw_fd(),
                std::ptr::null(),
                0,
                events.as_mut_ptr(),
                EVENTS_PER_WAIT as libc::c_int,
                std::ptr::null(),
            )
        })?;
        tokens.clear();
        tokens.extend(events.iter().take(count as usize).map(|event| event.udata as usize as u64));
        Ok(())
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(super) struct Poller {
    epoll: OwnedFd,
    wake: OwnedFd,
}

#[cfg(any(target_os = "linux", target_os = "android"))]
impl Poller {
    pub(super) fn new() -> io::Result<Self> {
        // SAFETY: epoll_create1 takes a flag and returns a fresh descriptor.
        let epoll = unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) };
        if epoll < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a successful epoll_create1 returned a descriptor we own.
        let epoll = unsafe { OwnedFd::from_raw_fd(epoll) };
        // SAFETY: eventfd takes an initial value and flags.
        let wake = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) };
        if wake < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a successful eventfd returned a descriptor we own.
        let poller = Self { epoll, wake: unsafe { OwnedFd::from_raw_fd(wake) } };
        // Level-triggered: the loop drains the counter when it sees the wake.
        poller.control(libc::EPOLL_CTL_ADD, poller.wake.as_raw_fd(), libc::EPOLLIN, WAKE_TOKEN)?;
        Ok(poller)
    }

    fn control(
        &self,
        op: libc::c_int,
        fd: RawFd,
        events: libc::c_int,
        token: u64,
    ) -> io::Result<()> {
        let mut event = libc::epoll_event { events: events as u32, u64: token };
        // SAFETY: `event` is valid for the call and the epoll set is owned.
        retry_interrupted(|| unsafe { libc::epoll_ctl(self.epoll.as_raw_fd(), op, fd, &mut event) })
            .map(drop)
    }

    /// Watches `fd` for input (or its end) under `token`, armed.
    pub(super) fn add(&self, fd: RawFd, token: u64) -> io::Result<()> {
        self.control(libc::EPOLL_CTL_ADD, fd, libc::EPOLLIN | libc::EPOLLONESHOT, token)
    }

    /// Arms `fd` again after a delivered readiness.
    pub(super) fn rearm(&self, fd: RawFd, token: u64) -> io::Result<()> {
        self.control(libc::EPOLL_CTL_MOD, fd, libc::EPOLLIN | libc::EPOLLONESHOT, token)
    }

    /// Stops watching `fd`; call it before `fd` closes.
    pub(super) fn delete(&self, fd: RawFd) -> io::Result<()> {
        self.control(libc::EPOLL_CTL_DEL, fd, 0, 0)
    }

    /// Ends the [`Poller::wait`] in progress, or the next one.
    pub(super) fn wake(&self) -> io::Result<()> {
        let one: u64 = 1;
        // SAFETY: an 8-byte write of a valid integer to the owned eventfd.
        let written = unsafe {
            libc::write(self.wake.as_raw_fd(), (&raw const one).cast(), size_of::<u64>())
        };
        if written < 0 {
            let error = io::Error::last_os_error();
            // A full counter already wakes the loop.
            if error.kind() != io::ErrorKind::WouldBlock {
                return Err(error);
            }
        }
        Ok(())
    }

    /// Blocks until at least one watched descriptor is ready or a wake, and
    /// replaces `tokens` with what is ready.
    pub(super) fn wait(&self, tokens: &mut Vec<u64>) -> io::Result<()> {
        let mut events = [libc::epoll_event { events: 0, u64: 0 }; EVENTS_PER_WAIT];
        // SAFETY: the epoll set is owned and `events` is writable for its
        // length; -1 waits without a timer.
        let count = retry_interrupted(|| unsafe {
            libc::epoll_wait(
                self.epoll.as_raw_fd(),
                events.as_mut_ptr(),
                EVENTS_PER_WAIT as libc::c_int,
                -1,
            )
        })?;
        tokens.clear();
        for event in events.iter().take(count as usize) {
            let token = event.u64;
            if token == WAKE_TOKEN {
                let mut counter = 0u64;
                // SAFETY: an 8-byte read into a valid integer from the owned
                // nonblocking eventfd; an empty counter only returns EAGAIN.
                let _ = unsafe {
                    libc::read(self.wake.as_raw_fd(), (&raw mut counter).cast(), size_of::<u64>())
                };
            }
            tokens.push(token);
        }
        Ok(())
    }
}
