//! The Unix side of the driver (net.rs): a pipe as the wake-up, `poll(2)`, `getifaddrs`
//! and `setsockopt` for the socket buffers.

use super::UDP_BUFFER_SIZE;
use std::io;
use std::mem::size_of_val;
use std::net::{IpAddr, Ipv4Addr, UdpSocket};
use std::os::fd::{AsRawFd, RawFd};

/// What the driver and its caller wait on.
pub(super) type Raw = RawFd;

pub(super) fn raw(socket: &UdpSocket) -> Raw {
    socket.as_raw_fd()
}

/// A non-blocking pipe used as a wake-up: a byte means "look at the queue".
pub(super) struct Wake {
    read: RawFd,
    write: RawFd,
}

impl Wake {
    pub(super) fn new() -> io::Result<Self> {
        let mut fds = [0; 2];
        // SAFETY: pipe(2) fills the two-element array we own.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            return Err(io::Error::last_os_error());
        }
        for fd in fds {
            // SAFETY: fcntl on descriptors we just created.
            unsafe {
                libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
                libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC);
            }
        }
        Ok(Self { read: fds[0], write: fds[1] })
    }

    /// Readable while a wake-up is pending.
    pub(super) fn raw(&self) -> Raw {
        self.read
    }

    pub(super) fn wake(&self) {
        // SAFETY: one byte from a local to our write end; a full pipe already holds a wake-up.
        unsafe { libc::write(self.write, [1u8].as_ptr().cast(), 1) };
    }

    pub(super) fn drain(&self) {
        let mut scratch = [0u8; 64];
        // SAFETY: reads into a local buffer from our non-blocking read end.
        while unsafe { libc::read(self.read, scratch.as_mut_ptr().cast(), scratch.len()) } > 0 {}
    }
}

impl Drop for Wake {
    fn drop(&mut self) {
        // SAFETY: closing the two descriptors this value owns, once.
        unsafe {
            libc::close(self.read);
            libc::close(self.write);
        }
    }
}

/// Blocks until one of `fds` is readable or `timeout_ms` passes (-1: no timeout).
pub(super) fn wait_readable(fds: &[Raw], timeout_ms: i32) {
    let mut pfds: Vec<libc::pollfd> =
        fds.iter().map(|&fd| libc::pollfd { fd, events: libc::POLLIN, revents: 0 }).collect();
    // SAFETY: pfds is a valid array of pollfd for its length.
    unsafe { libc::poll(pfds.as_mut_ptr(), pfds.len() as libc::nfds_t, timeout_ms) };
}

/// Every non-loopback address of this machine's up interfaces.
pub(super) fn interface_addresses() -> Vec<IpAddr> {
    let mut out = Vec::new();
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    // SAFETY: getifaddrs allocates a list we walk read-only and free once.
    unsafe {
        if libc::getifaddrs(&mut head) != 0 {
            return out;
        }
        let mut cursor = head;
        while !cursor.is_null() {
            let entry = &*cursor;
            cursor = entry.ifa_next;
            if entry.ifa_addr.is_null() || entry.ifa_flags & (libc::IFF_UP as u32) == 0 {
                continue;
            }
            let ip = match i32::from((*entry.ifa_addr).sa_family) {
                libc::AF_INET => {
                    let sin = &*(entry.ifa_addr as *const libc::sockaddr_in);
                    IpAddr::V4(Ipv4Addr::from(u32::from_be(sin.sin_addr.s_addr)))
                }
                _ => continue,
            };
            if !ip.is_loopback() && !ip.is_unspecified() {
                out.push(ip);
            }
        }
        libc::freeifaddrs(head);
    }
    out.sort();
    out.dedup();
    out
}

/// Grow both queues so a keyframe burst is not dropped before the driver can
/// read it. The kernel may cap the request; the default is still useful on
/// platforms that accept the larger value.
pub(super) fn grow_udp_buffers(socket: &UdpSocket) {
    for option in [libc::SO_SNDBUF, libc::SO_RCVBUF] {
        // SAFETY: the descriptor is open for the borrow of `socket`, and the
        // option value points at a live integer of the length passed.
        unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                option,
                (&UDP_BUFFER_SIZE as *const i32).cast(),
                size_of_val(&UDP_BUFFER_SIZE) as libc::socklen_t,
            );
        }
    }
}

/// Apple platforms: the socket's traffic is interactive video
/// (`SO_NET_SERVICE_TYPE` = `NET_SERVICE_TYPE_VI`, the class video calls use),
/// so Wi-Fi sends it in the video access category and the system treats the
/// flow as latency sensitive. Best effort: a refusal changes nothing else.
pub(super) fn mark_interactive_video(socket: &UdpSocket) {
    #[cfg(target_vendor = "apple")]
    {
        // <sys/socket.h>; the libc crate does not export them.
        const SO_NET_SERVICE_TYPE: libc::c_int = 0x1116;
        const NET_SERVICE_TYPE_VI: libc::c_int = 3;
        // SAFETY: the descriptor is open for the borrow of `socket`, and the
        // option value points at a live integer of the length passed.
        unsafe {
            libc::setsockopt(
                socket.as_raw_fd(),
                libc::SOL_SOCKET,
                SO_NET_SERVICE_TYPE,
                (&NET_SERVICE_TYPE_VI as *const libc::c_int).cast(),
                size_of_val(&NET_SERVICE_TYPE_VI) as libc::socklen_t,
            );
        }
    }
    #[cfg(not(target_vendor = "apple"))]
    let _ = socket;
}
