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
use std::future::Future;
use std::net::SocketAddr;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;
use tokio::io::ReadBuf;
use tokio::net::UdpSocket;
use tokio::time::{Instant, Sleep};

/// Datagrams kept while a socket is unwritable. The driver stops feeding
/// data the moment anything is queued and waits for writability, so the
/// queue holds at most one TCP segment plus the odd handshake or keepalive;
/// the bound only guards memory against a socket that never drains.
const SEND_QUEUE_DEPTH: usize = 1024;
/// First and longest wait before retrying after the interface refused a
/// datagram (ENOBUFS). The socket stays writable then, so readiness cannot
/// signal the retry; a short timer does, doubling while refusals repeat.
const INTERFACE_RETRY_MIN: Duration = Duration::from_millis(1);
const INTERFACE_RETRY_MAX: Duration = Duration::from_millis(50);

/// Why a send was refused without being an error to drop on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Refusal {
    /// The socket buffer is full: wait for writability.
    SocketFull,
    /// The interface queue is full (ENOBUFS, common for UDP on macOS):
    /// retry after a short wait.
    InterfaceFull,
}

fn refusal(error: &io::Error) -> Option<Refusal> {
    if error.kind() == io::ErrorKind::WouldBlock {
        return Some(Refusal::SocketFull);
    }
    #[cfg(unix)]
    if error.raw_os_error() == Some(libc::ENOBUFS) {
        return Some(Refusal::InterfaceFull);
    }
    None
}

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

/// Pings a probing underlay wants sent now (path, probe id), and when it
/// next wants anything: a ping, or the deadline of an unanswered one.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct DueProbes {
    pub pings: Vec<(PathId, u64)>,
    pub next: Option<Instant>,
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

    /// Send one datagram on `path` only (a probe or its answer). A
    /// single-path carrier has one path.
    fn send_on(&mut self, _path: PathId, datagram: &[u8]) {
        self.send(datagram);
    }

    /// Probes due at `now`. The driver calls this only while the session
    /// carries traffic; a carrier with one path never probes.
    fn poll_probes(&mut self, _now: Instant) -> DueProbes {
        DueProbes::default()
    }

    /// The pong for probe `id`, sent on `path`, arrived at `now`.
    fn on_pong(&mut self, _path: PathId, _id: u64, _now: Instant) {}

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
    /// Armed after the interface refused a datagram.
    retry: Option<Pin<Box<Sleep>>>,
    retry_after: Duration,
}

/// The default underlay: one UDP socket, one peer address.
pub type UdpUnderlay = SocketPath<UdpSocket>;

impl<S: DatagramSocket> SocketPath<S> {
    pub fn new(socket: S, peer: Option<SocketAddr>) -> Self {
        Self {
            socket,
            peer,
            pending: VecDeque::new(),
            retry: None,
            retry_after: INTERFACE_RETRY_MIN,
        }
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
            Err(error) if refusal(&error).is_some() => {
                self.pending.push_back((datagram.to_vec(), peer));
            }
            Err(error) => eprintln!("wireguard UDP send to {peer} failed: {error}"),
        }
    }

    fn flush(&mut self) {
        while self.retry.is_none()
            && let Some((datagram, peer)) = self.pending.front()
        {
            match self.socket.try_send_to(datagram, *peer) {
                Ok(_) => {
                    self.pending.pop_front();
                }
                Err(error) if refusal(&error).is_some() => break,
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
            if let Some(retry) = &mut self.retry {
                if retry.as_mut().poll(cx).is_pending() {
                    return Poll::Pending;
                }
                self.retry = None;
            }
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
                    self.retry_after = INTERFACE_RETRY_MIN;
                }
                Err(error) => match refusal(&error) {
                    // Readiness was stale; the next poll registers interest.
                    Some(Refusal::SocketFull) => {}
                    Some(Refusal::InterfaceFull) => {
                        self.retry = Some(Box::pin(tokio::time::sleep(self.retry_after)));
                        self.retry_after = (self.retry_after * 2).min(INTERFACE_RETRY_MAX);
                    }
                    None => {
                        eprintln!("wireguard UDP send to {peer} failed: {error}");
                        self.pending.pop_front();
                    }
                },
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

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use super::*;

    /// A socket that refuses the first sends with a chosen error.
    struct Refusing {
        refusals: VecDeque<io::Error>,
        sent: Arc<Mutex<Vec<Vec<u8>>>>,
    }

    impl DatagramSocket for Refusing {
        fn poll_recv_from(
            &mut self,
            _cx: &mut Context<'_>,
            _buffer: &mut [u8],
        ) -> Poll<io::Result<(usize, SocketAddr)>> {
            Poll::Pending
        }

        /// Like a real socket after ENOBUFS: its own buffer has room.
        fn poll_send_ready(&mut self, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn try_send_to(&mut self, datagram: &[u8], _target: SocketAddr) -> io::Result<usize> {
            if let Some(error) = self.refusals.pop_front() {
                return Err(error);
            }
            self.sent.lock().unwrap().push(datagram.to_vec());
            Ok(datagram.len())
        }

        fn local_addr(&self) -> io::Result<SocketAddr> {
            Ok("127.0.0.1:1".parse().unwrap())
        }
    }

    #[cfg(unix)]
    fn enobufs() -> io::Error {
        io::Error::from_raw_os_error(libc::ENOBUFS)
    }

    async fn refused_sends_are_kept_and_retried(refusals: Vec<io::Error>) {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let socket = Refusing { refusals: refusals.into(), sent: Arc::clone(&sent) };
        let mut path = SocketPath::new(socket, Some("127.0.0.1:2".parse().unwrap()));
        path.send(b"one");
        path.send(b"two");
        assert!(path.backlogged(), "a refused datagram is queued, not dropped");
        std::future::poll_fn(|cx| path.poll_flush(cx)).await;
        assert!(!path.backlogged());
        assert_eq!(*sent.lock().unwrap(), vec![b"one".to_vec(), b"two".to_vec()]);
    }

    #[cfg(unix)]
    #[tokio::test(start_paused = true)]
    async fn enobufs_is_backpressure_not_a_drop() {
        let started = Instant::now();
        refused_sends_are_kept_and_retried((0..5).map(|_| enobufs()).collect()).await;
        // The two sends meet two refusals; the flush meets three more and
        // retries after 1, 2 and 4 ms.
        assert_eq!(started.elapsed(), Duration::from_millis(7));
    }

    #[tokio::test(start_paused = true)]
    async fn would_block_is_backpressure_not_a_drop() {
        let refusals = (0..3).map(|_| io::Error::from(io::ErrorKind::WouldBlock)).collect();
        refused_sends_are_kept_and_retried(refusals).await;
    }
}
