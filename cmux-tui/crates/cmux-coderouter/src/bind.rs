//! Loopback-only binding. The router has no constructor that takes a plain
//! `SocketAddr`: [`LoopbackListener::bind`] takes a [`LoopbackAddr`], and a
//! `LoopbackAddr` can only hold `127.0.0.0/8` or `::1`. So `0.0.0.0`, `::`,
//! a LAN address and an IPv4-mapped IPv6 address are refused before any
//! socket exists.

use std::{
    fmt, io,
    net::{IpAddr, Ipv4Addr, SocketAddr},
};
use tokio::net::TcpListener;

/// A socket address that is loopback (`127.0.0.0/8` or `::1`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LoopbackAddr(SocketAddr);

/// The error for an address that is not loopback.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NotLoopback(pub SocketAddr);

impl fmt::Display for NotLoopback {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{} is not a loopback address", self.0)
    }
}

impl std::error::Error for NotLoopback {}

impl From<NotLoopback> for io::Error {
    fn from(error: NotLoopback) -> Self {
        io::Error::new(io::ErrorKind::InvalidInput, error)
    }
}

impl LoopbackAddr {
    /// `127.0.0.1` on a port the kernel picks.
    pub const EPHEMERAL_V4: Self = Self(SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), 0));

    /// Accept `address` only when it is loopback.
    pub fn new(address: SocketAddr) -> Result<Self, NotLoopback> {
        if is_loopback(address.ip()) { Ok(Self(address)) } else { Err(NotLoopback(address)) }
    }

    /// The address.
    pub fn get(self) -> SocketAddr {
        self.0
    }
}

impl TryFrom<SocketAddr> for LoopbackAddr {
    type Error = NotLoopback;

    fn try_from(address: SocketAddr) -> Result<Self, Self::Error> {
        Self::new(address)
    }
}

fn is_loopback(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_loopback(),
        // `Ipv6Addr::is_loopback` is true only for `::1`; an IPv4-mapped
        // address (`::ffff:127.0.0.1`) is refused on purpose, because a
        // dual-stack socket bound through it is harder to reason about.
        IpAddr::V6(v6) => v6.is_loopback(),
    }
}

/// A TCP listener that is bound to a loopback address.
#[derive(Debug)]
pub struct LoopbackListener {
    listener: TcpListener,
    address: LoopbackAddr,
}

impl LoopbackListener {
    /// Bind `address`. The bound address is checked again, so a platform
    /// that rewrites the address cannot produce a non-loopback listener.
    pub async fn bind(address: LoopbackAddr) -> io::Result<Self> {
        let listener = TcpListener::bind(address.get()).await?;
        let address = LoopbackAddr::new(listener.local_addr()?)?;
        Ok(Self { listener, address })
    }

    /// The bound address (with the real port when the request used port 0).
    pub fn local_addr(&self) -> LoopbackAddr {
        self.address
    }

    pub(crate) fn into_inner(self) -> TcpListener {
        self.listener
    }
}
