//! The readiness loop: kqueue on macOS, epoll on Linux, behind one API.
//!
//! Registrations are level-triggered. Every event carries the token it was
//! registered with. Process exits come from EVFILT_PROC on macOS and from a
//! pidfd on Linux; cross-thread wakes from EVFILT_USER on macOS and from an
//! eventfd plus a queue of terminal ids on Linux.

#[cfg(target_os = "linux")]
use std::collections::HashMap;
use std::io;
use std::os::fd::RawFd;
#[cfg(target_os = "linux")]
use std::sync::{Arc, Mutex};

pub(super) enum Interest {
    Read,
    Write,
}

pub(super) enum Event {
    Read(u64),
    Write(u64),
    /// A watched process exited; `token` is what `watch_exit` was given.
    Exit {
        token: u64,
        pid: libc::pid_t,
    },
    /// `Waker::wake(id)` was called.
    Wake(u32),
}

fn cvt(r: libc::c_int) -> io::Result<libc::c_int> {
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(r) }
}

/// Wakes the loop from another thread with a terminal id.
#[derive(Clone)]
pub(super) struct Waker {
    fd: RawFd,
    #[cfg(target_os = "linux")]
    queue: Arc<Mutex<Vec<u32>>>,
}

// ---------------------------------------------------------------- macOS ----

#[cfg(target_os = "macos")]
pub(super) struct Poller {
    kq: RawFd,
    buf: Vec<libc::kevent>,
}

#[cfg(target_os = "macos")]
impl Poller {
    pub(super) fn new() -> io::Result<Self> {
        // SAFETY: kqueue has no preconditions; the descriptor is ours.
        let kq = cvt(unsafe { libc::kqueue() })?;
        // SAFETY: close-on-exec on our own descriptor, so an upgrade starts clean.
        unsafe { libc::fcntl(kq, libc::F_SETFD, libc::FD_CLOEXEC) };
        // SAFETY: zeroed kevents are valid out-buffers.
        Ok(Poller { kq, buf: vec![unsafe { std::mem::zeroed() }; 256] })
    }

    fn change(
        &self,
        ident: usize,
        filter: i16,
        flags: u16,
        fflags: u32,
        token: u64,
    ) -> io::Result<()> {
        // SAFETY: a zeroed kevent is valid; one changelist entry, no event list.
        unsafe {
            let mut ev: libc::kevent = std::mem::zeroed();
            ev.ident = ident;
            ev.filter = filter;
            ev.flags = flags;
            ev.fflags = fflags;
            ev.udata = token as usize as *mut libc::c_void;
            cvt(libc::kevent(self.kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()))?;
        }
        Ok(())
    }

    fn filter(interest: &Interest) -> i16 {
        match interest {
            Interest::Read => libc::EVFILT_READ,
            Interest::Write => libc::EVFILT_WRITE,
        }
    }

    pub(super) fn add(&mut self, fd: RawFd, interest: Interest, token: u64) -> io::Result<()> {
        self.change(fd as usize, Self::filter(&interest), libc::EV_ADD, 0, token)
    }

    pub(super) fn delete(&mut self, fd: RawFd, interest: Interest) {
        let _ = self.change(fd as usize, Self::filter(&interest), libc::EV_DELETE, 0, 0);
    }

    /// Stops or resumes read events for `fd` without dropping the registration.
    pub(super) fn set_read_enabled(&mut self, fd: RawFd, token: u64, enabled: bool) {
        let flags = if enabled { libc::EV_ENABLE } else { libc::EV_DISABLE };
        let _ = self.change(fd as usize, libc::EVFILT_READ, flags, 0, token);
    }

    /// Reports `Event::Exit` once when `pid` exits. Errors with ESRCH when
    /// the process is already gone (the caller reaps it at once).
    pub(super) fn watch_exit(&mut self, pid: libc::pid_t, token: u64) -> io::Result<()> {
        self.change(
            pid as usize,
            libc::EVFILT_PROC,
            libc::EV_ADD | libc::EV_ONESHOT,
            libc::NOTE_EXIT,
            token,
        )
    }

    /// Prepares `id` for `Waker::wake`.
    pub(super) fn add_wake(&mut self, id: u32) -> io::Result<()> {
        self.change(id as usize, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0, u64::from(id))
    }

    pub(super) fn delete_wake(&mut self, id: u32) {
        let _ = self.change(id as usize, libc::EVFILT_USER, libc::EV_DELETE, 0, 0);
    }

    pub(super) fn waker(&self) -> Waker {
        Waker { fd: self.kq }
    }

    pub(super) fn wait(&mut self, out: &mut Vec<Event>) -> io::Result<()> {
        out.clear();
        // SAFETY: buf has the capacity passed.
        let n = unsafe {
            libc::kevent(
                self.kq,
                std::ptr::null(),
                0,
                self.buf.as_mut_ptr(),
                self.buf.len() as i32,
                std::ptr::null(),
            )
        };
        if n < 0 {
            let err = io::Error::last_os_error();
            return if err.kind() == io::ErrorKind::Interrupted { Ok(()) } else { Err(err) };
        }
        for ev in &self.buf[..n as usize] {
            let token = ev.udata as usize as u64;
            out.push(match ev.filter {
                libc::EVFILT_WRITE => Event::Write(token),
                libc::EVFILT_PROC => Event::Exit { token, pid: ev.ident as libc::pid_t },
                // Routed by ident: a trigger may replace the stored udata.
                libc::EVFILT_USER => Event::Wake(ev.ident as u32),
                _ => Event::Read(token),
            });
        }
        Ok(())
    }
}

#[cfg(target_os = "macos")]
impl Waker {
    pub(super) fn wake(&self, id: u32) {
        // SAFETY: a zeroed kevent is valid; one changelist entry, no event list.
        unsafe {
            let mut ev: libc::kevent = std::mem::zeroed();
            ev.ident = id as usize;
            ev.filter = libc::EVFILT_USER;
            ev.fflags = libc::NOTE_TRIGGER;
            // A trigger also replaces the stored udata: pass the id again.
            ev.udata = id as usize as *mut libc::c_void;
            libc::kevent(self.fd, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null());
        }
    }
}

// ---------------------------------------------------------------- Linux ----

#[cfg(target_os = "linux")]
const TOKEN_EVENTFD: u64 = u64::MAX;
#[cfg(target_os = "linux")]
const PIDFD_BIT: u64 = 1 << 63;

#[cfg(target_os = "linux")]
#[derive(Default)]
struct Registration {
    token: u64,
    read: bool,
    read_enabled: bool,
    write: bool,
}

#[cfg(target_os = "linux")]
pub(super) struct Poller {
    ep: RawFd,
    buf: Vec<libc::epoll_event>,
    regs: HashMap<RawFd, Registration>,
    /// pidfd -> (token, pid) for watched processes.
    pidfds: HashMap<RawFd, (u64, libc::pid_t)>,
    waker: Waker,
}

#[cfg(target_os = "linux")]
impl Poller {
    pub(super) fn new() -> io::Result<Self> {
        // SAFETY: plain syscalls creating descriptors we own.
        let ep = cvt(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) })?;
        let efd = cvt(unsafe { libc::eventfd(0, libc::EFD_CLOEXEC | libc::EFD_NONBLOCK) })?;
        let mut ev = libc::epoll_event { events: libc::EPOLLIN as u32, u64: TOKEN_EVENTFD };
        // SAFETY: registering our eventfd with a valid event.
        cvt(unsafe { libc::epoll_ctl(ep, libc::EPOLL_CTL_ADD, efd, &mut ev) })?;
        Ok(Poller {
            ep,
            buf: vec![libc::epoll_event { events: 0, u64: 0 }; 256],
            regs: HashMap::new(),
            pidfds: HashMap::new(),
            waker: Waker { fd: efd, queue: Arc::default() },
        })
    }

    fn sync(&mut self, fd: RawFd) -> io::Result<()> {
        let Some(reg) = self.regs.get(&fd) else { return Ok(()) };
        let mut mask = 0u32;
        if reg.read && reg.read_enabled {
            mask |= (libc::EPOLLIN | libc::EPOLLRDHUP) as u32;
        }
        if reg.write {
            mask |= libc::EPOLLOUT as u32;
        }
        let mut ev = libc::epoll_event { events: mask, u64: reg.token };
        // SAFETY: modifying (or adding) our registration for a live fd.
        let r = unsafe { libc::epoll_ctl(self.ep, libc::EPOLL_CTL_MOD, fd, &mut ev) };
        if r < 0 && io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
            // SAFETY: as above, adding instead.
            cvt(unsafe { libc::epoll_ctl(self.ep, libc::EPOLL_CTL_ADD, fd, &mut ev) })?;
        } else if r < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }

    pub(super) fn add(&mut self, fd: RawFd, interest: Interest, token: u64) -> io::Result<()> {
        let reg = self.regs.entry(fd).or_default();
        reg.token = token;
        match interest {
            Interest::Read => {
                reg.read = true;
                reg.read_enabled = true;
            }
            Interest::Write => reg.write = true,
        }
        self.sync(fd)
    }

    pub(super) fn delete(&mut self, fd: RawFd, interest: Interest) {
        let Some(reg) = self.regs.get_mut(&fd) else { return };
        match interest {
            Interest::Read => reg.read = false,
            Interest::Write => reg.write = false,
        }
        if !reg.read && !reg.write {
            self.regs.remove(&fd);
            // SAFETY: removing our registration; a closed fd already left.
            unsafe { libc::epoll_ctl(self.ep, libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut()) };
        } else {
            let _ = self.sync(fd);
        }
    }

    pub(super) fn set_read_enabled(&mut self, fd: RawFd, token: u64, enabled: bool) {
        if let Some(reg) = self.regs.get_mut(&fd) {
            reg.token = token;
            reg.read_enabled = enabled;
            let _ = self.sync(fd);
        }
    }

    pub(super) fn watch_exit(&mut self, pid: libc::pid_t, token: u64) -> io::Result<()> {
        // SAFETY: pidfd_open(2) on our own child; a zombie still gets a pidfd
        // that is readable at once.
        let pidfd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) } as RawFd;
        if pidfd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: close-on-exec on our descriptor.
        unsafe { libc::fcntl(pidfd, libc::F_SETFD, libc::FD_CLOEXEC) };
        let mut ev =
            libc::epoll_event { events: libc::EPOLLIN as u32, u64: PIDFD_BIT | pidfd as u64 };
        // SAFETY: registering the pidfd with a valid event.
        cvt(unsafe { libc::epoll_ctl(self.ep, libc::EPOLL_CTL_ADD, pidfd, &mut ev) })?;
        self.pidfds.insert(pidfd, (token, pid));
        Ok(())
    }

    pub(super) fn add_wake(&mut self, _id: u32) -> io::Result<()> {
        Ok(())
    }

    pub(super) fn delete_wake(&mut self, _id: u32) {}

    pub(super) fn waker(&self) -> Waker {
        self.waker.clone()
    }

    pub(super) fn wait(&mut self, out: &mut Vec<Event>) -> io::Result<()> {
        out.clear();
        // SAFETY: buf has the capacity passed.
        let n =
            unsafe { libc::epoll_wait(self.ep, self.buf.as_mut_ptr(), self.buf.len() as i32, -1) };
        if n < 0 {
            let err = io::Error::last_os_error();
            return if err.kind() == io::ErrorKind::Interrupted { Ok(()) } else { Err(err) };
        }
        for i in 0..n as usize {
            let (mask, data) = (self.buf[i].events, self.buf[i].u64);
            if data == TOKEN_EVENTFD {
                let mut v = 0u64;
                // SAFETY: draining our eventfd counter into an 8-byte buffer.
                unsafe { libc::read(self.waker.fd, (&raw mut v).cast(), 8) };
                for id in std::mem::take(&mut *self.waker.queue.lock().expect("wake queue")) {
                    out.push(Event::Wake(id));
                }
                continue;
            }
            if data & PIDFD_BIT != 0 {
                let pidfd = (data & !PIDFD_BIT) as RawFd;
                if let Some((token, pid)) = self.pidfds.remove(&pidfd) {
                    // SAFETY: one-shot: drop the registration and close the pidfd.
                    unsafe {
                        libc::epoll_ctl(self.ep, libc::EPOLL_CTL_DEL, pidfd, std::ptr::null_mut());
                        libc::close(pidfd);
                    }
                    out.push(Event::Exit { token, pid });
                }
                continue;
            }
            // Hang-up and error read as readable: the read then sees EOF/EIO.
            let readable = libc::EPOLLIN | libc::EPOLLRDHUP | libc::EPOLLHUP | libc::EPOLLERR;
            if mask & readable as u32 != 0 {
                out.push(Event::Read(data));
            }
            if mask & libc::EPOLLOUT as u32 != 0 {
                out.push(Event::Write(data));
            }
        }
        Ok(())
    }
}

#[cfg(target_os = "linux")]
impl Waker {
    pub(super) fn wake(&self, id: u32) {
        self.queue.lock().expect("wake queue").push(id);
        let one = 1u64;
        // SAFETY: writing an 8-byte count to our eventfd.
        unsafe { libc::write(self.fd, (&raw const one).cast(), 8) };
    }
}
