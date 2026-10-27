//! The readiness poller under [`super::MuxIo`]: kqueue on macOS and the
//! BSDs, epoll on Linux, as Chromium's `MessagePumpKqueue`
//! (base/message_loop/message_pump_kqueue.cc) and `MessagePumpEpoll`
//! (base/message_loop/message_pump_epoll.cc) watch an IO thread's
//! descriptors for both directions.
//!
//! Level-triggered. A descriptor is watched only for what its connection
//! wants now ([`Interest`]): reading while its inbox has room, writing while
//! a write met a full socket. A descriptor that wants neither is not in the
//! set at all, so a hung-up peer whose reads are paused never spins the loop.
//! [`Poller::wake`] ends a [`Poller::wait`] (`EVFILT_USER` / an eventfd); the
//! loop has no timer unless a blocked write has a deadline.

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::Duration;

/// The token [`Poller::wait`] reports for a [`Poller::wake`].
pub(super) const WAKE_TOKEN: u64 = u64::MAX;

/// Readiness events one [`Poller::wait`] returns at most.
const EVENTS_PER_WAIT: usize = 256;

/// What a descriptor is watched for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct Interest {
    pub(super) read: bool,
    pub(super) write: bool,
}

impl Interest {
    pub(super) const NONE: Interest = Interest { read: false, write: false };

    fn is_none(self) -> bool {
        !self.read && !self.write
    }
}

/// One readiness: the descriptor's token, and which ways it is ready. An
/// error or a hang-up reads as ready both ways: the read or the write that
/// follows reports it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Ready {
    pub(super) token: u64,
    pub(super) readable: bool,
    pub(super) writable: bool,
}

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

    /// Watches `fd` for `next` where it was watched for `previous`.
    pub(super) fn update(
        &self,
        fd: RawFd,
        token: u64,
        previous: Interest,
        next: Interest,
    ) -> io::Result<()> {
        for (filter, was, wants) in [
            (libc::EVFILT_READ, previous.read, next.read),
            (libc::EVFILT_WRITE, previous.write, next.write),
        ] {
            match (was, wants) {
                (false, true) => self.change(fd as usize, filter, libc::EV_ADD, 0, token)?,
                (true, false) => self.change(fd as usize, filter, libc::EV_DELETE, 0, token)?,
                _ => {}
            }
        }
        Ok(())
    }

    /// Ends the [`Poller::wait`] in progress, or the next one.
    pub(super) fn wake(&self) -> io::Result<()> {
        self.change(0, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER, WAKE_TOKEN)
    }

    /// Blocks until a watched descriptor is ready, a wake, or `timeout`, and
    /// replaces `ready` with what is ready (empty after a timeout).
    pub(super) fn wait(&self, ready: &mut Vec<Ready>, timeout: Option<Duration>) -> io::Result<()> {
        // SAFETY: an all-zero kevent is a valid output slot.
        let mut events: [libc::kevent; EVENTS_PER_WAIT] = unsafe { std::mem::zeroed() };
        let spec = timeout.map(|timeout| libc::timespec {
            tv_sec: libc::time_t::try_from(timeout.as_secs()).unwrap_or(libc::time_t::MAX),
            tv_nsec: libc::c_long::from(timeout.subsec_nanos() as i32),
        });
        let spec_ptr = spec.as_ref().map_or(std::ptr::null(), |spec| spec as *const _);
        // SAFETY: the queue is owned, `events` is writable for its length and
        // `spec_ptr` is null or points at `spec`, which outlives the call.
        let count = retry_interrupted(|| unsafe {
            libc::kevent(
                self.queue.as_raw_fd(),
                std::ptr::null(),
                0,
                events.as_mut_ptr(),
                EVENTS_PER_WAIT as libc::c_int,
                spec_ptr,
            )
        })?;
        ready.clear();
        for event in events.iter().take(count as usize) {
            let token = event.udata as usize as u64;
            let failed = event.flags & libc::EV_ERROR != 0;
            ready.push(Ready {
                token,
                readable: failed || event.filter == libc::EVFILT_READ,
                writable: failed || event.filter == libc::EVFILT_WRITE,
            });
        }
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

    /// Watches `fd` for `next` where it was watched for `previous`.
    pub(super) fn update(
        &self,
        fd: RawFd,
        token: u64,
        previous: Interest,
        next: Interest,
    ) -> io::Result<()> {
        let events = (if next.read { libc::EPOLLIN } else { 0 })
            | (if next.write { libc::EPOLLOUT } else { 0 });
        match (previous.is_none(), next.is_none()) {
            (true, true) => Ok(()),
            (true, false) => self.control(libc::EPOLL_CTL_ADD, fd, events, token),
            (false, true) => self.control(libc::EPOLL_CTL_DEL, fd, 0, token),
            (false, false) if previous == next => Ok(()),
            (false, false) => self.control(libc::EPOLL_CTL_MOD, fd, events, token),
        }
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

    /// Blocks until a watched descriptor is ready, a wake, or `timeout`, and
    /// replaces `ready` with what is ready (empty after a timeout).
    pub(super) fn wait(&self, ready: &mut Vec<Ready>, timeout: Option<Duration>) -> io::Result<()> {
        let mut events = [libc::epoll_event { events: 0, u64: 0 }; EVENTS_PER_WAIT];
        // Rounded up, so a deadline is never woken for early and re-armed.
        let millis = timeout.map_or(-1, |timeout| {
            let millis = timeout.as_nanos().div_ceil(1_000_000);
            libc::c_int::try_from(millis).unwrap_or(libc::c_int::MAX)
        });
        // SAFETY: the epoll set is owned and `events` is writable for its
        // length.
        let count = retry_interrupted(|| unsafe {
            libc::epoll_wait(
                self.epoll.as_raw_fd(),
                events.as_mut_ptr(),
                EVENTS_PER_WAIT as libc::c_int,
                millis,
            )
        })?;
        ready.clear();
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
            let flags = event.events as libc::c_int;
            let failed = flags & (libc::EPOLLERR | libc::EPOLLHUP) != 0;
            ready.push(Ready {
                token,
                readable: failed || flags & libc::EPOLLIN != 0,
                writable: failed || flags & libc::EPOLLOUT != 0,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;
    use std::os::fd::AsRawFd as _;
    use std::os::unix::net::UnixStream;
    use std::time::{Duration, Instant};

    use super::{Interest, Poller, Ready, WAKE_TOKEN};

    const READ: Interest = Interest { read: true, write: false };
    const BOTH: Interest = Interest { read: true, write: true };

    fn wait(poller: &Poller, timeout: Duration) -> Vec<Ready> {
        let mut ready = Vec::new();
        poller.wait(&mut ready, Some(timeout)).unwrap();
        ready
    }

    #[test]
    fn a_watched_socket_reports_input_and_room() {
        let poller = Poller::new().unwrap();
        let (mut peer, ours) = UnixStream::pair().unwrap();
        poller.update(ours.as_raw_fd(), 7, Interest::NONE, READ).unwrap();
        assert!(wait(&poller, Duration::from_millis(20)).is_empty(), "nothing to read yet");
        peer.write_all(b"x").unwrap();
        let ready = wait(&poller, Duration::from_secs(5));
        assert!(ready.iter().any(|ready| ready.token == 7 && ready.readable), "{ready:?}");
        poller.update(ours.as_raw_fd(), 7, READ, BOTH).unwrap();
        let ready = wait(&poller, Duration::from_secs(5));
        assert!(ready.iter().any(|ready| ready.token == 7 && ready.writable), "{ready:?}");
    }

    #[test]
    fn a_socket_that_wants_nothing_is_not_reported_after_a_hang_up() {
        let poller = Poller::new().unwrap();
        let (peer, ours) = UnixStream::pair().unwrap();
        poller.update(ours.as_raw_fd(), 3, Interest::NONE, READ).unwrap();
        poller.update(ours.as_raw_fd(), 3, READ, Interest::NONE).unwrap();
        drop(peer);
        assert!(wait(&poller, Duration::from_millis(20)).is_empty());
    }

    #[test]
    fn a_wake_ends_a_wait_with_no_timeout() {
        let poller = std::sync::Arc::new(Poller::new().unwrap());
        let waker = poller.clone();
        let started = Instant::now();
        let thread = std::thread::spawn(move || {
            let mut ready = Vec::new();
            waker.wait(&mut ready, None).unwrap();
            ready
        });
        std::thread::sleep(Duration::from_millis(20));
        poller.wake().unwrap();
        let ready = thread.join().unwrap();
        assert!(ready.iter().any(|ready| ready.token == WAKE_TOKEN), "{ready:?}");
        assert!(started.elapsed() < Duration::from_secs(5));
    }
}
