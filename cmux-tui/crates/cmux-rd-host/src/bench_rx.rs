//! The bench viewer's UDP receive thread and the kernel's receive time of each datagram.
//!
//! The viewer used to read its socket in the loop that decodes: a datagram that arrived during
//! a frame's (software) decode waited in the socket buffer, and its arrival was stamped when user
//! space read it, so that wait was booked as the ledger's Network stage and as transport delay in
//! the media feedback the host's rate control reads. Here a thread of its own reads the socket as
//! datagrams land, and each one carries the time the kernel received it (SO_TIMESTAMPNS on Linux,
//! SO_TIMESTAMP on macOS) moved onto the protocol clock (CLOCK_MONOTONIC, `clock::now_ns`).

use crate::clock::now_ns;
use std::io;
use std::net::UdpSocket;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::Arc;
use std::thread::JoinHandle;

/// How long the thread's wait lasts before it checks whether the viewer is gone.
const STOP_POLL_MS: i32 = 100;
/// A kernel stamp older than this is not believed (a wall clock step): read time instead.
const MAX_AGE_NS: u64 = 1_000_000_000;

enum Rx {
    Datagram(Vec<u8>, u64),
    Failed(io::Error),
}

/// Reads one UDP socket on its own thread; [`Self::drain`] hands over what arrived.
pub struct RxThread {
    rx: Receiver<Rx>,
    /// Readable while datagrams wait in `rx`: the viewer's poll(2) wakes on it.
    wake_read: OwnedFd,
    /// Set by the thread when it wrote a wake byte the viewer has not taken yet.
    pending: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl RxThread {
    /// Starts reading `sock` (a clone of it: the viewer keeps sending on its own handle).
    pub fn start(sock: &UdpSocket) -> io::Result<Self> {
        let sock = sock.try_clone()?;
        // Both handles share one open file, which stays non-blocking: the thread polls.
        sock.set_nonblocking(true)?;
        enable_kernel_stamps(sock.as_raw_fd());
        let (wake_read, wake_write) = pipe()?;
        let (tx, rx) = mpsc::channel();
        let pending = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let (pending, stop) = (pending.clone(), stop.clone());
            std::thread::Builder::new()
                .name("bench-udp-rx".into())
                .spawn(move || run(sock, tx, wake_write, pending, stop))?
        };
        Ok(Self { rx, wake_read, pending, stop, thread: Some(thread) })
    }

    pub fn wake_fd(&self) -> RawFd {
        self.wake_read.as_raw_fd()
    }

    /// Every datagram received so far, oldest first, with its arrival (protocol clock, ns).
    pub fn drain(&self, mut each: impl FnMut(Vec<u8>, u64)) -> io::Result<()> {
        let mut sink = [0u8; 64];
        // SAFETY: reads into a live local buffer from a pipe this struct owns (non-blocking).
        while unsafe { libc::read(self.wake_fd(), sink.as_mut_ptr().cast(), sink.len()) } > 0 {}
        // Cleared before the queue is read: a datagram queued after this sets it and wakes again.
        self.pending.store(false, Ordering::SeqCst);
        loop {
            match self.rx.try_recv() {
                Ok(Rx::Datagram(d, at)) => each(d, at),
                Ok(Rx::Failed(e)) => return Err(e),
                Err(TryRecvError::Empty) => return Ok(()),
                Err(TryRecvError::Disconnected) => {
                    return Err(io::Error::other("the UDP receive thread ended"))
                }
            }
        }
    }
}

impl Drop for RxThread {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn run(
    sock: UdpSocket,
    tx: Sender<Rx>,
    wake_write: OwnedFd,
    pending: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) {
    let fd = sock.as_raw_fd();
    let mut buf = vec![0u8; 65536];
    while !stop.load(Ordering::SeqCst) {
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        // SAFETY: one valid pollfd.
        if unsafe { libc::poll(&mut pfd, 1, STOP_POLL_MS) } <= 0 {
            continue;
        }
        let mut queued = false;
        loop {
            match recv_stamped(fd, &mut buf) {
                Ok((n, at)) => {
                    if tx.send(Rx::Datagram(buf[..n].to_vec(), at)).is_err() {
                        return;
                    }
                    queued = true;
                }
                Err(e) if e.kind() == io::ErrorKind::WouldBlock => break,
                Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                // ICMP port unreachable surfaces as a read error on a connected-ish UDP socket;
                // the old loop failed the run on it too.
                Err(e) => {
                    let _ = tx.send(Rx::Failed(e));
                    queued = true;
                    break;
                }
            }
        }
        if queued && !pending.swap(true, Ordering::SeqCst) {
            // SAFETY: writes one byte from a live local to a pipe this thread owns.
            unsafe { libc::write(wake_write.as_raw_fd(), [1u8].as_ptr().cast(), 1) };
        }
    }
}

#[cfg(target_os = "linux")]
const STAMP_OPT: libc::c_int = libc::SO_TIMESTAMPNS;
#[cfg(target_os = "macos")]
const STAMP_OPT: libc::c_int = libc::SO_TIMESTAMP;

/// Asks the kernel for each datagram's receive time; without it the read time stands in.
fn enable_kernel_stamps(fd: RawFd) {
    let on: libc::c_int = 1;
    // SAFETY: setsockopt with a valid fd and a pointer to a local int.
    unsafe {
        libc::setsockopt(
            fd,
            libc::SOL_SOCKET,
            STAMP_OPT,
            (&on as *const libc::c_int).cast(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

/// One datagram into `buf` and its arrival on the protocol clock (ns).
fn recv_stamped(fd: RawFd, buf: &mut [u8]) -> io::Result<(usize, u64)> {
    let mut iov = libc::iovec { iov_base: buf.as_mut_ptr().cast(), iov_len: buf.len() };
    // Room for one timespec or timeval control message, aligned for cmsghdr.
    let mut control = [0u64; 8];
    // SAFETY: an all-zero msghdr is valid; the fields set below point at live locals.
    let mut msg: libc::msghdr = unsafe { std::mem::zeroed() };
    msg.msg_iov = &mut iov;
    msg.msg_iovlen = 1;
    msg.msg_control = control.as_mut_ptr().cast();
    msg.msg_controllen = std::mem::size_of_val(&control) as _;
    // SAFETY: msg describes buffers that outlive the call.
    let n = unsafe { libc::recvmsg(fd, &mut msg, libc::MSG_DONTWAIT) };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    let read_at = now_ns();
    let at = kernel_wall_ns(&msg)
        .map_or(read_at, |kernel| on_protocol_clock(kernel, wall_ns(), read_at));
    Ok((n as usize, at))
}

/// The wall-clock receive time the kernel attached to `msg`, if it did.
fn kernel_wall_ns(msg: &libc::msghdr) -> Option<u64> {
    // SAFETY: CMSG_* walk the control buffer recvmsg filled, within msg_controllen; each
    // payload is read unaligned.
    unsafe {
        let mut c = libc::CMSG_FIRSTHDR(msg);
        while !c.is_null() {
            let (level, ty) = ((*c).cmsg_level, (*c).cmsg_type);
            if level == libc::SOL_SOCKET {
                #[cfg(target_os = "linux")]
                if ty == libc::SCM_TIMESTAMPNS {
                    let ts = std::ptr::read_unaligned(libc::CMSG_DATA(c) as *const libc::timespec);
                    return Some(ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64);
                }
                #[cfg(target_os = "macos")]
                if ty == libc::SCM_TIMESTAMP {
                    let tv = std::ptr::read_unaligned(libc::CMSG_DATA(c) as *const libc::timeval);
                    return Some(tv.tv_sec as u64 * 1_000_000_000 + tv.tv_usec as u64 * 1000);
                }
            }
            c = libc::CMSG_NXTHDR(msg, c);
        }
    }
    None
}

fn wall_ns() -> u64 {
    let mut ts = libc::timespec { tv_sec: 0, tv_nsec: 0 };
    // SAFETY: clock_gettime writes into a valid timespec.
    unsafe { libc::clock_gettime(libc::CLOCK_REALTIME, &mut ts) };
    ts.tv_sec as u64 * 1_000_000_000 + ts.tv_nsec as u64
}

/// A kernel wall-clock stamp `kernel` on the protocol clock: as long before `read_at` (protocol
/// clock) as it is before `wall_now` (the wall clock read with it). Never after the read; a stamp
/// from the future or over a second old (a wall clock step) gives the read time.
pub(crate) fn on_protocol_clock(kernel: u64, wall_now: u64, read_at: u64) -> u64 {
    match wall_now.checked_sub(kernel) {
        Some(age) if age <= MAX_AGE_NS => read_at.saturating_sub(age),
        _ => read_at,
    }
}

fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0 as RawFd; 2];
    // SAFETY: pipe writes two descriptors into a live array.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both descriptors were just created and are owned only here.
    let (r, w) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    for fd in [&r, &w] {
        // SAFETY: fcntl on a descriptor this function owns.
        unsafe {
            let flags = libc::fcntl(fd.as_raw_fd(), libc::F_GETFL);
            libc::fcntl(fd.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
            libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC);
        }
    }
    Ok((r, w))
}

#[cfg(test)]
#[path = "bench_rx_tests.rs"]
mod tests;
