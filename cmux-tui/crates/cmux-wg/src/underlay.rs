//! The carrier under a WireGuard session.
//!
//! The driver only encrypts and decrypts. Where its datagrams go, and where
//! received ones came from, is the job of an [`Underlay`]. One plain UDP
//! socket aimed at one peer address is the simplest underlay
//! ([`UdpUnderlay`]); [`crate::Multipath`] holds several paths to the same
//! peer and sends each datagram on the path its selector chose. Because
//! WireGuard authenticates every datagram, the session does not care which
//! path carried it, so swapping or adding paths never resets the session or
//! its TCP streams.

use std::collections::VecDeque;
use std::io;
use std::net::SocketAddr;
use std::task::{Context, Poll};

use cmux_transport::PathId;
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;

/// Datagrams kept while a socket is unwritable. The driver stops feeding
/// data the moment anything is queued and waits for writability, so the
/// queue holds at most one TCP segment plus the odd handshake or keepalive;
/// the bound only guards memory against a socket that never drains.
const SEND_QUEUE_DEPTH: usize = 1024;

/// Where a received datagram came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Origin {
    /// The path it arrived on. Single-path underlays report `PathId(0)`.
    pub path: PathId,
    /// The sender's address on that path, when the carrier has one.
    pub addr: Option<SocketAddr>,
}

/// One received datagram: `len` bytes at the start of the caller's buffer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Received {
    pub len: usize,
    pub origin: Origin,
}

/// A carrier of one peer's encrypted datagrams.
///
/// Every method is non-blocking. `send` hands the datagram to the carrier or
/// queues it; while anything is queued the carrier is [`backlogged`] and the
/// driver sends no more data until [`poll_flush`] drains it. A carrier must
/// not drop what it queued: a lost datagram costs TCP a retransmission
/// timeout.
///
/// [`backlogged`]: Underlay::backlogged
/// [`poll_flush`]: Underlay::poll_flush
pub trait Underlay: Send + 'static {
    /// Send one datagram toward the peer.
    fn send(&mut self, datagram: &[u8]);

    /// Retry datagrams queued while the carrier was unwritable.
    fn flush(&mut self) {}

    /// Whether datagrams wait for the carrier to become writable.
    fn backlogged(&self) -> bool {
        false
    }

    /// Send queued datagrams as the carrier becomes writable; ready once
    /// nothing is queued.
    fn poll_flush(&mut self, _cx: &mut Context<'_>) -> Poll<()> {
        Poll::Ready(())
    }

    /// Receive the next datagram into `buffer`.
    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>>;

    /// WireGuard authenticated the datagram from `origin`. A carrier that
    /// addresses its peer follows it there (WireGuard roaming).
    fn authenticated(&mut self, _origin: Origin) {}

    /// Whether a send could reach the peer at all. The driver sends its
    /// first handshake initiation only when it can.
    fn has_peer(&self) -> bool;

    /// The peer address of the path currently in use, so a rebind to a new
    /// socket can keep sending to the same place.
    fn peer_hint(&self) -> Option<SocketAddr> {
        None
    }
}

/// A datagram socket: Tokio's UDP socket, or a simulated one in tests.
pub trait DatagramSocket: Send + 'static {
    fn poll_recv_from(
        &mut self,
        cx: &mut Context<'_>,
        buffer: &mut [u8],
    ) -> Poll<io::Result<(usize, SocketAddr)>>;

    /// Ready when a send would not answer `WouldBlock`.
    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>>;

    fn try_send_to(&mut self, datagram: &[u8], target: SocketAddr) -> io::Result<usize>;

    fn local_addr(&self) -> io::Result<SocketAddr>;
}

impl DatagramSocket for UdpSocket {
    fn poll_recv_from(
        &mut self,
        cx: &mut Context<'_>,
        buffer: &mut [u8],
    ) -> Poll<io::Result<(usize, SocketAddr)>> {
        let mut read = ReadBuf::new(buffer);
        match UdpSocket::poll_recv_from(self, cx, &mut read) {
            Poll::Ready(Ok(source)) => Poll::Ready(Ok((read.filled().len(), source))),
            Poll::Ready(Err(error)) => Poll::Ready(Err(error)),
            Poll::Pending => Poll::Pending,
        }
    }

    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        UdpSocket::poll_send_ready(self, cx)
    }

    fn try_send_to(&mut self, datagram: &[u8], target: SocketAddr) -> io::Result<usize> {
        UdpSocket::try_send_to(self, datagram, target)
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        UdpSocket::local_addr(self)
    }
}

/// One socket and the peer's address on it. The address follows the source
/// of the latest authenticated datagram, and starts unknown on a side that
/// only answers.
pub struct SocketPath<S> {
    socket: S,
    peer: Option<SocketAddr>,
    pending: VecDeque<(Vec<u8>, SocketAddr)>,
}

/// The default underlay: one UDP socket, one peer address.
pub type UdpUnderlay = SocketPath<UdpSocket>;

impl<S: DatagramSocket> SocketPath<S> {
    pub fn new(socket: S, peer: Option<SocketAddr>) -> Self {
        Self { socket, peer, pending: VecDeque::new() }
    }

    pub fn socket(&self) -> &S {
        &self.socket
    }

    pub fn peer(&self) -> Option<SocketAddr> {
        self.peer
    }
}

impl<S: DatagramSocket> Underlay for SocketPath<S> {
    fn send(&mut self, datagram: &[u8]) {
        let Some(peer) = self.peer else { return };
        if !self.pending.is_empty() {
            self.flush();
        }
        if !self.pending.is_empty() {
            if self.pending.len() < SEND_QUEUE_DEPTH {
                self.pending.push_back((datagram.to_vec(), peer));
            } else {
                eprintln!("wireguard UDP send to {peer} dropped: the socket never drained");
            }
            return;
        }
        match self.socket.try_send_to(datagram, peer) {
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                self.pending.push_back((datagram.to_vec(), peer));
            }
            Err(error) => eprintln!("wireguard UDP send to {peer} failed: {error}"),
        }
    }

    fn flush(&mut self) {
        while let Some((datagram, peer)) = self.pending.front() {
            match self.socket.try_send_to(datagram, *peer) {
                Ok(_) => {
                    self.pending.pop_front();
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => break,
                Err(error) => {
                    eprintln!("wireguard UDP send to {peer} failed: {error}");
                    self.pending.pop_front();
                }
            }
        }
    }

    fn backlogged(&self) -> bool {
        !self.pending.is_empty()
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        while let Some((datagram, peer)) = self.pending.front() {
            match self.socket.poll_send_ready(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(error)) => {
                    eprintln!("wireguard UDP socket failed: {error}");
                    self.pending.clear();
                    break;
                }
                Poll::Ready(Ok(())) => {}
            }
            match self.socket.try_send_to(datagram, *peer) {
                Ok(_) => {
                    self.pending.pop_front();
                }
                // Readiness was stale; the next poll registers interest.
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                Err(error) => {
                    eprintln!("wireguard UDP send to {peer} failed: {error}");
                    self.pending.pop_front();
                }
            }
        }
        Poll::Ready(())
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        self.socket.poll_recv_from(cx, buffer).map_ok(|(len, source)| Received {
            len,
            origin: Origin { path: PathId(0), addr: Some(source) },
        })
    }

    fn authenticated(&mut self, origin: Origin) {
        if let Some(addr) = origin.addr {
            self.peer = Some(addr);
        }
    }

    fn has_peer(&self) -> bool {
        self.peer.is_some()
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.peer
    }
}

/// Receive errors a datagram carrier survives: ICMP port unreachable surfaces
/// as ECONNREFUSED or ECONNRESET on some platforms, and EINTR is a retry.
pub(crate) fn is_transient(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::Interrupted
            | io::ErrorKind::ConnectionRefused
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::WouldBlock
    )
}
