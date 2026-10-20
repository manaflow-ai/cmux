//! TCP transport for development and network measurements.
//!
//! The listener is unauthenticated: whoever reaches the port runs programs
//! as the server's user. `mux2d` therefore binds only the explicit address
//! in `MUX2_LISTEN` (never a wildcard), and it is meant for a loopback or a
//! private tailnet address on a machine you own, never for production. It
//! also drops every connection whose peer is not allowed: by default
//! loopback and Tailscale addresses (100.64.0.0/10, fd7a:115c:a1e0::/48);
//! `MUX2_LISTEN_ALLOW=IP[,IP...]` replaces that with an explicit list, for
//! example one LAN machine. Loopback is not the Unix socket's 0600: on a
//! machine with other users, any of them can reach a loopback port, so set
//! `MUX2_LISTEN_ALLOW` there or use the Unix socket. The server removes
//! both variables from its environment, so its programs (and a nested
//! mux2d) do not inherit them; an upgrade hands them to the new binary.
//!
//! Every interactive TCP socket gets the same options:
//! - `TCP_NODELAY`: a keystroke or its echo is one small segment; with Nagle
//!   it waits for the previous segment's ACK, and with the peer's delayed
//!   ACK that is 40-200 ms per keystroke.
//! - `TCP_NOTSENT_LOWAT` (server side): the kernel keeps at most this much
//!   unsent output, so a backlog stays in the server's own queue, where it
//!   can be replaced by a snapshot, instead of in a send buffer that grows
//!   to megabytes and that nothing can take back. A keystroke echo then
//!   waits behind at most one bandwidth-delay product plus this mark.
//! - keepalive (30 s idle, 10 s interval, 4 probes): a peer that vanished
//!   behind a NAT is noticed in about a minute, and a NAT that drops idle
//!   mappings after a few minutes keeps an idle viewer's mapping alive.

use std::io::{self, Read, Write};
use std::net::{IpAddr, Shutdown, SocketAddr, TcpStream};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixStream;

#[cfg(target_os = "macos")]
const TCP_NOTSENT_LOWAT: libc::c_int = 0x201;
#[cfg(target_os = "linux")]
const TCP_NOTSENT_LOWAT: libc::c_int = libc::TCP_NOTSENT_LOWAT;
#[cfg(target_os = "macos")]
const TCP_KEEPIDLE: libc::c_int = libc::TCP_KEEPALIVE;
#[cfg(target_os = "linux")]
const TCP_KEEPIDLE: libc::c_int = libc::TCP_KEEPIDLE;

/// Unsent bytes the kernel may hold per TCP connection (`MUX2_NOTSENT_LOWAT`).
pub const NOTSENT_LOWAT: u32 = 32 << 10;

fn setopt(fd: RawFd, level: libc::c_int, name: libc::c_int, value: libc::c_int) -> io::Result<()> {
    // SAFETY: setsockopt with a valid c_int option value.
    let r = unsafe {
        libc::setsockopt(fd, level, name, (&raw const value).cast(), size_of::<libc::c_int>() as _)
    };
    if r < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

/// Applies the interactive options above to a connected TCP socket.
/// `notsent_lowat` is for the side that sends bulk output (the server).
/// `MUX2_TCP_NODELAY=0` leaves Nagle on, only to measure what it costs.
pub fn tune(fd: RawFd, notsent_lowat: Option<u32>) -> io::Result<()> {
    if std::env::var_os("MUX2_TCP_NODELAY").is_none_or(|v| v != "0") {
        setopt(fd, libc::IPPROTO_TCP, libc::TCP_NODELAY, 1)?;
    }
    setopt(fd, libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1)?;
    setopt(fd, libc::IPPROTO_TCP, TCP_KEEPIDLE, 30)?;
    setopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 10)?;
    setopt(fd, libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 4)?;
    // 0 leaves the kernel default (no mark), only to measure what it costs.
    if let Some(mark) = notsent_lowat.filter(|m| *m > 0) {
        setopt(fd, libc::IPPROTO_TCP, TCP_NOTSENT_LOWAT, mark.min(i32::MAX as u32) as libc::c_int)?;
    }
    Ok(())
}

/// The address of `MUX2_CONNECT`, when clients should use TCP.
pub fn connect_addr() -> Option<String> {
    std::env::var("MUX2_CONNECT").ok().filter(|v| !v.is_empty())
}

/// Parses a listen address and refuses wildcards: the listener has no
/// authentication, so it must name the one interface it serves.
pub fn parse_listen_addr(value: &str) -> io::Result<SocketAddr> {
    let addr: SocketAddr = value
        .parse()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "MUX2_LISTEN is ADDR:PORT"))?;
    if addr.ip().is_unspecified() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "MUX2_LISTEN must name one address (it is unauthenticated), not a wildcard",
        ));
    }
    Ok(addr)
}

/// Peers the TCP listener admits (see the module documentation).
#[derive(Default)]
pub struct PeerPolicy(Option<Vec<IpAddr>>);

/// An IPv4-mapped IPv6 address as the IPv4 address it carries.
fn unmap(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(ip, IpAddr::V4),
        v4 => v4,
    }
}

impl PeerPolicy {
    /// From the value of `MUX2_LISTEN_ALLOW` (empty: the default policy);
    /// an unparsable entry is an error, never ignored.
    pub fn parse(list: &str) -> io::Result<Self> {
        if list.is_empty() {
            return Ok(PeerPolicy(None));
        }
        let ips = list
            .split(',')
            .map(|ip| {
                ip.trim().parse().map(unmap).map_err(|_| {
                    io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!("MUX2_LISTEN_ALLOW: bad IP {ip}"),
                    )
                })
            })
            .collect::<io::Result<Vec<IpAddr>>>()?;
        Ok(PeerPolicy(Some(ips)))
    }

    pub fn admits(&self, peer: IpAddr) -> bool {
        let peer = unmap(peer);
        match &self.0 {
            Some(list) => list.contains(&peer),
            None => match peer {
                IpAddr::V4(v4) => {
                    v4.is_loopback() || (v4.octets()[0] == 100 && v4.octets()[1] & 0xc0 == 64)
                }
                IpAddr::V6(v6) => {
                    let s = v6.segments();
                    v6.is_loopback() || (s[0] == 0xfd7a && s[1] == 0x115c && s[2] == 0xa1e0)
                }
            },
        }
    }
}

/// The peer address of a connected socket.
pub fn peer_ip(fd: RawFd) -> Option<IpAddr> {
    use std::os::fd::{FromRawFd, IntoRawFd};
    // SAFETY: borrowing the descriptor for one call; into_raw_fd gives it back.
    let s = unsafe { TcpStream::from_raw_fd(fd) };
    let peer = s.peer_addr().ok().map(|a| a.ip());
    let _ = s.into_raw_fd();
    peer
}

/// A client connection: the local Unix socket or, with `MUX2_CONNECT`, TCP.
pub enum Stream {
    Unix(UnixStream),
    Tcp(TcpStream),
}

impl Stream {
    /// Connects to `MUX2_CONNECT` over TCP, tuned for interactive use.
    pub fn connect_tcp(addr: &str) -> io::Result<Self> {
        let s = TcpStream::connect(addr)?;
        tune(s.as_raw_fd(), None)?;
        Ok(Stream::Tcp(s))
    }
    pub fn try_clone(&self) -> io::Result<Self> {
        Ok(match self {
            Stream::Unix(s) => Stream::Unix(s.try_clone()?),
            Stream::Tcp(s) => Stream::Tcp(s.try_clone()?),
        })
    }
    pub fn shutdown(&self, how: Shutdown) -> io::Result<()> {
        match self {
            Stream::Unix(s) => s.shutdown(how),
            Stream::Tcp(s) => s.shutdown(how),
        }
    }
    pub fn raw_fd(&self) -> RawFd {
        match self {
            Stream::Unix(s) => s.as_raw_fd(),
            Stream::Tcp(s) => s.as_raw_fd(),
        }
    }
}

impl Read for Stream {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Stream::Unix(s) => s.read(buf),
            Stream::Tcp(s) => s.read(buf),
        }
    }
}

impl Write for Stream {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            Stream::Unix(s) => s.write(buf),
            Stream::Tcp(s) => s.write(buf),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// Counters of one TCP connection, from the kernel.
#[derive(Clone, Copy, Debug, Default)]
pub struct TcpCounters {
    pub tx_packets: u64,
    pub rx_packets: u64,
    pub tx_bytes: u64,
    pub rx_bytes: u64,
    pub retransmit_packets: u64,
    /// Smoothed round-trip time in microseconds.
    pub srtt_us: u64,
    /// Bytes in the send buffer (macOS: including in flight; Linux: unsent only).
    pub send_queue: u64,
}

/// Reads [`TcpCounters`] for a TCP socket; `None` for other sockets.
pub fn counters(fd: RawFd) -> Option<TcpCounters> {
    let mut buf = [0u64; 64];
    let mut len = size_of_val(&buf) as libc::socklen_t;
    #[cfg(target_os = "macos")]
    let name = libc::TCP_CONNECTION_INFO;
    #[cfg(target_os = "linux")]
    let name = libc::TCP_INFO;
    // SAFETY: getsockopt into a zeroed buffer larger than either struct.
    let r =
        unsafe { libc::getsockopt(fd, libc::IPPROTO_TCP, name, buf.as_mut_ptr().cast(), &mut len) };
    if r < 0 {
        return None;
    }
    let bytes: &[u8] =
        // SAFETY: viewing the u64 buffer as bytes.
        unsafe { std::slice::from_raw_parts(buf.as_ptr().cast(), size_of_val(&buf)) };
    let u32_at = |o: usize| u64::from(u32::from_ne_bytes(bytes[o..o + 4].try_into().expect("4")));
    let u64_at = |o: usize| u64::from_ne_bytes(bytes[o..o + 8].try_into().expect("8"));
    // Offsets from <netinet/tcp.h> (struct tcp_connection_info) and
    // <linux/tcp.h> (struct tcp_info); the pinned libc misdeclares the
    // macOS bitfields, so the struct is read by offset.
    #[cfg(target_os = "macos")]
    let c = TcpCounters {
        tx_packets: u64_at(56),
        tx_bytes: u64_at(64),
        rx_packets: u64_at(80),
        rx_bytes: u64_at(88),
        retransmit_packets: if len as usize >= 112 { u64_at(104) } else { 0 },
        srtt_us: u32_at(44) * 1000,
        send_queue: u32_at(32),
    };
    #[cfg(target_os = "linux")]
    let c = TcpCounters {
        tx_packets: u32_at(136),
        rx_packets: u32_at(140),
        tx_bytes: if len as usize >= 208 { u64_at(200) } else { 0 },
        rx_bytes: u64_at(128),
        retransmit_packets: u32_at(100),
        srtt_us: u32_at(68),
        send_queue: u32_at(144),
    };
    Some(c)
}
