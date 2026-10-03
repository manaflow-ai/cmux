//! Errors of the tunnel and its connections.

use std::fmt;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

#[derive(Debug)]
pub enum WgError {
    Io(io::Error),
    /// The configured endpoint did not resolve.
    EndpointUnresolved(String),
    /// The endpoint resolved only to addresses of a family the UDP socket
    /// cannot reach.
    EndpointFamilyMismatch,
    /// This side has no tunnel address in the remote's address family.
    NoTunnelAddress(IpAddr),
    /// The remote answered the SYN with a reset, or never answered.
    ConnectionRefused(SocketAddr),
    /// A listener already owns the port.
    ListenerBusy(u16),
    /// The tunnel has been shut down.
    Shutdown,
    /// No WireGuard handshake completed before the startup deadline.
    HandshakeTimeout(Duration),
    /// smoltcp refused the operation.
    Stack(String),
    /// A datagram larger than the session's `max_datagram`.
    DatagramTooLarge { len: usize, max: usize },
}

impl fmt::Display for WgError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "socket error: {error}"),
            Self::EndpointUnresolved(host) => write!(formatter, "endpoint {host} did not resolve"),
            Self::EndpointFamilyMismatch => {
                formatter.write_str("endpoint address family does not match the UDP socket")
            }
            Self::NoTunnelAddress(remote) => {
                write!(formatter, "no tunnel address in the same family as {remote}")
            }
            Self::ConnectionRefused(remote) => write!(formatter, "{remote} refused the connection"),
            Self::ListenerBusy(port) => write!(formatter, "port {port} already has a listener"),
            Self::Shutdown => formatter.write_str("the tunnel is shut down"),
            Self::HandshakeTimeout(timeout) => {
                write!(formatter, "no WireGuard handshake completed within {timeout:?}")
            }
            Self::Stack(detail) => write!(formatter, "tcp stack: {detail}"),
            Self::DatagramTooLarge { len, max } => {
                write!(formatter, "a {len}-byte datagram exceeds the {max}-byte maximum")
            }
        }
    }
}

impl std::error::Error for WgError {}

impl From<io::Error> for WgError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}
