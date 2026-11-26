//! The Windows side of the driver (net.rs). Windows has no pipe a socket wait can watch, so a
//! wake-up is a pair of loopback UDP sockets connected to each other (only the pair's own
//! datagrams reach the reading end), the driver waits with `WSAPoll`, the socket buffers grow
//! through Winsock's `setsockopt`, and the host candidates are the source addresses the routing
//! table picks (no packet is sent).

use super::UDP_BUFFER_SIZE;
use std::io;
use std::mem::size_of_val;
use std::net::{IpAddr, UdpSocket};
use std::os::windows::io::{AsRawSocket, RawSocket};
use windows_sys::Win32::Networking::WinSock::{
    POLLRDNORM, SO_RCVBUF, SO_SNDBUF, SOCKET, SOL_SOCKET, WSAPOLLFD, WSAPoll, setsockopt,
};

/// What the driver and its caller wait on.
pub(super) type Raw = RawSocket;

pub(super) fn raw(socket: &UdpSocket) -> Raw {
    socket.as_raw_socket()
}

/// A wake-up: a byte sent from `write` to `read` means "look at the queue".
pub(super) struct Wake {
    read: UdpSocket,
    write: UdpSocket,
}

impl Wake {
    pub(super) fn new() -> io::Result<Self> {
        let read = UdpSocket::bind("127.0.0.1:0")?;
        let write = UdpSocket::bind("127.0.0.1:0")?;
        // Each end accepts datagrams from the other only: another local process cannot fill it.
        read.connect(write.local_addr()?)?;
        write.connect(read.local_addr()?)?;
        read.set_nonblocking(true)?;
        write.set_nonblocking(true)?;
        Ok(Self { read, write })
    }

    /// Readable while a wake-up is pending.
    pub(super) fn raw(&self) -> Raw {
        self.read.as_raw_socket()
    }

    pub(super) fn wake(&self) {
        // A full receive buffer already holds a wake-up.
        let _ = self.write.send(&[1]);
    }

    pub(super) fn drain(&self) {
        let mut scratch = [0u8; 16];
        // WouldBlock ends it; so does any other error (nothing to drain then).
        while self.read.recv(&mut scratch).is_ok() {}
    }
}

/// Blocks until one of `sockets` is readable or `timeout_ms` passes (-1: no timeout).
pub(super) fn wait_readable(sockets: &[Raw], timeout_ms: i32) {
    let mut fds: Vec<WSAPOLLFD> = sockets
        .iter()
        .map(|&s| WSAPOLLFD { fd: s as SOCKET, events: POLLRDNORM, revents: 0 })
        .collect();
    let count = u32::try_from(fds.len()).unwrap_or(u32::MAX);
    // SAFETY: fds is a valid array of WSAPOLLFD for its length; the sockets are open for the
    // borrow of their owners (std started Winsock when it created them).
    unsafe { WSAPoll(fds.as_mut_ptr(), count, timeout_ms) };
}

/// The addresses this machine sends from: for each probe destination, the source address the
/// routing table picks (a UDP `connect` sends nothing). The default route's interface, the
/// tailnet's (100.100.100.100 is Tailscale's own address) and any private LAN route.
pub(super) fn interface_addresses() -> Vec<IpAddr> {
    const PROBES: [&str; 5] = [
        "8.8.8.8:53",
        "100.100.100.100:53",
        "10.255.255.254:9",
        "172.31.255.254:9",
        "192.168.255.254:9",
    ];
    let mut out = Vec::new();
    for probe in PROBES {
        let Ok(socket) = UdpSocket::bind("0.0.0.0:0") else { continue };
        if socket.connect(probe).is_err() {
            continue;
        }
        let Ok(local) = socket.local_addr() else { continue };
        let ip = local.ip();
        if !ip.is_loopback() && !ip.is_unspecified() {
            out.push(ip);
        }
    }
    out.sort();
    out.dedup();
    out
}

/// Grow both queues so a keyframe burst is not dropped before the driver can read it.
pub(super) fn grow_udp_buffers(socket: &UdpSocket) {
    for option in [SO_SNDBUF, SO_RCVBUF] {
        // SAFETY: the socket is open for the borrow of `socket`, and the option value points
        // at a live integer of the length passed.
        unsafe {
            setsockopt(
                socket.as_raw_socket() as SOCKET,
                SOL_SOCKET,
                option,
                (&UDP_BUFFER_SIZE as *const i32).cast(),
                size_of_val(&UDP_BUFFER_SIZE) as i32,
            );
        }
    }
}

/// Apple platforms only (net_unix.rs): Windows leaves the socket's service class alone.
pub(super) fn mark_interactive_video(_socket: &UdpSocket) {}
