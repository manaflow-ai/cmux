//! Thin wrappers over the Linux descriptors the agent waits on: epoll,
//! timerfd, signalfd, inotify, rtnetlink and pidfd. Each wrapper owns its
//! descriptor (`OwnedFd`, close-on-exec, non-blocking).

use std::ffi::{CString, OsString};
use std::io;
use std::mem::{MaybeUninit, size_of};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::Path;

pub use cmux_server::deadline::fd::{Clock, TimerFd};

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

pub struct Epoll(OwnedFd);

impl Epoll {
    pub fn new() -> io::Result<Self> {
        // SAFETY: plain syscall.
        owned(unsafe { libc::epoll_create1(libc::EPOLL_CLOEXEC) }).map(Self)
    }

    pub fn add(&self, fd: RawFd, token: u64) -> io::Result<()> {
        let mut event = libc::epoll_event { events: libc::EPOLLIN as u32, u64: token };
        // SAFETY: `event` outlives the call.
        cvt(unsafe { libc::epoll_ctl(self.0.as_raw_fd(), libc::EPOLL_CTL_ADD, fd, &mut event) })
            .map(drop)
    }

    pub fn remove(&self, fd: RawFd) {
        // SAFETY: a null event is allowed for EPOLL_CTL_DEL.
        unsafe {
            libc::epoll_ctl(self.0.as_raw_fd(), libc::EPOLL_CTL_DEL, fd, std::ptr::null_mut())
        };
    }

    /// Blocks until at least one descriptor is ready; returns the tokens.
    pub fn wait(&self) -> io::Result<Vec<u64>> {
        let mut events = [libc::epoll_event { events: 0, u64: 0 }; 16];
        loop {
            // SAFETY: `events` holds 16 entries.
            let n = unsafe { libc::epoll_wait(self.0.as_raw_fd(), events.as_mut_ptr(), 16, -1) };
            if n >= 0 {
                // The kernel reports at most the 16 entries it was given.
                let ready = usize::try_from(n).ok().and_then(|n| events.get(..n));
                let ready =
                    ready.ok_or_else(|| io::Error::other("epoll_wait count out of range"))?;
                return Ok(ready.iter().map(|e| e.u64).collect());
            }
            let err = io::Error::last_os_error();
            if err.raw_os_error() != Some(libc::EINTR) {
                return Err(err);
            }
        }
    }
}

pub struct SignalFd(OwnedFd);

impl SignalFd {
    /// Blocks `signals` for this thread (inherited by later threads) and
    /// receives them through a descriptor.
    pub fn new(signals: &[libc::c_int]) -> io::Result<Self> {
        let mut set = MaybeUninit::<libc::sigset_t>::uninit();
        // SAFETY: sigemptyset initializes `set`; sigaddset and the mask
        // calls read it.
        unsafe {
            libc::sigemptyset(set.as_mut_ptr());
            for signal in signals {
                libc::sigaddset(set.as_mut_ptr(), *signal);
            }
            cvt(libc::pthread_sigmask(libc::SIG_BLOCK, set.as_ptr(), std::ptr::null_mut()))?;
            owned(libc::signalfd(-1, set.as_ptr(), libc::SFD_NONBLOCK | libc::SFD_CLOEXEC))
                .map(Self)
        }
    }

    pub fn raw(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    /// Every pending signal number.
    pub fn read_all(&self) -> io::Result<Vec<u32>> {
        let mut out = Vec::new();
        let mut buf = [0u8; size_of::<libc::signalfd_siginfo>()];
        while let Some(n) = read_fd(self.raw(), &mut buf)? {
            if n < buf.len() {
                break;
            }
            // ssi_signo is the first u32 of signalfd_siginfo.
            out.push(u32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]));
        }
        Ok(out)
    }
}

/// An inotify event: watch descriptor, mask and name.
pub struct InotifyEvent {
    pub wd: i32,
    pub mask: u32,
    pub name: OsString,
}

pub struct Inotify(OwnedFd);

impl Inotify {
    pub fn new() -> io::Result<Self> {
        // SAFETY: plain syscall.
        owned(unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) }).map(Self)
    }

    pub fn raw(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    /// Watches `dir` for completed writes and renames into it.
    pub fn watch_dir(&self, dir: &Path) -> io::Result<i32> {
        let path = CString::new(dir.as_os_str().as_bytes()).map_err(io::Error::other)?;
        let mask = libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO | libc::IN_ONLYDIR;
        // SAFETY: `path` is NUL-terminated and outlives the call.
        cvt(unsafe { libc::inotify_add_watch(self.raw(), path.as_ptr(), mask) })
    }

    pub fn read_events(&self) -> io::Result<Vec<InotifyEvent>> {
        let mut out = Vec::new();
        let mut buf = [0u8; 4096];
        let header = size_of::<libc::inotify_event>();
        while let Some(n) = read_fd(self.raw(), &mut buf)? {
            if n == 0 {
                break;
            }
            let Some(filled) = buf.get(..n) else {
                return Err(io::Error::other("inotify read longer than its buffer"));
            };
            let mut at: usize = 0;
            while let Some(head) = filled.get(at..at.saturating_add(header)) {
                // SAFETY: `head` is a whole event header the kernel wrote;
                // read_unaligned copes with the byte buffer's alignment.
                let event: libc::inotify_event =
                    unsafe { std::ptr::read_unaligned(head.as_ptr().cast()) };
                let name_start = at.saturating_add(header);
                let name_end = name_start.saturating_add(event.len as usize).min(n);
                let raw = filled.get(name_start..name_end).unwrap_or_default();
                let name = raw.split(|b| *b == 0).next().unwrap_or_default().to_vec();
                out.push(InotifyEvent {
                    wd: event.wd,
                    mask: event.mask,
                    name: OsString::from_vec(name),
                });
                at = name_end;
            }
        }
        Ok(out)
    }
}

pub struct Netlink(OwnedFd);

impl Netlink {
    /// rtnetlink socket joined to the link, IPv4 address and IPv6 address
    /// groups.
    pub fn new() -> io::Result<Self> {
        // SAFETY: plain syscalls; `addr` is fully initialized before bind.
        unsafe {
            let fd = owned(libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
                libc::NETLINK_ROUTE,
            ))?;
            let mut addr: libc::sockaddr_nl = std::mem::zeroed();
            addr.nl_family = libc::AF_NETLINK as libc::sa_family_t;
            addr.nl_groups =
                (libc::RTMGRP_LINK | libc::RTMGRP_IPV4_IFADDR | libc::RTMGRP_IPV6_IFADDR) as u32;
            cvt(libc::bind(
                fd.as_raw_fd(),
                (&raw const addr).cast(),
                size_of::<libc::sockaddr_nl>() as libc::socklen_t,
            ))?;
            Ok(Self(fd))
        }
    }

    pub fn raw(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    /// Discards every queued message (`ENOBUFS` on overflow counts as one).
    pub fn drain(&self) {
        let mut buf = [0u8; 8192];
        loop {
            match read_fd(self.raw(), &mut buf) {
                Ok(Some(n)) if n > 0 => continue,
                Err(err) if err.raw_os_error() == Some(libc::ENOBUFS) => continue,
                _ => return,
            }
        }
    }
}

/// A process descriptor: race-free signals and an exit wake.
pub struct PidFd(OwnedFd);

impl PidFd {
    pub fn open(pid: u32) -> io::Result<Self> {
        // SAFETY: pidfd_open(pid, 0) returns a new descriptor or -1.
        let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid as libc::pid_t, 0) };
        owned(fd as libc::c_int).map(Self)
    }

    pub fn raw(&self) -> RawFd {
        self.0.as_raw_fd()
    }

    pub fn signal(&self, signal: libc::c_int) -> io::Result<()> {
        // SAFETY: pidfd_send_signal with no siginfo.
        let ret = unsafe {
            libc::syscall(
                libc::SYS_pidfd_send_signal,
                self.raw(),
                signal,
                std::ptr::null::<libc::siginfo_t>(),
                0,
            )
        };
        cvt(ret as libc::c_int).map(drop)
    }

    /// The process has exited (the descriptor is readable).
    pub fn exited(&self) -> bool {
        let mut poll = libc::pollfd { fd: self.raw(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd; zero timeout never blocks.
        unsafe { libc::poll(&mut poll, 1, 0) > 0 }
    }
}
