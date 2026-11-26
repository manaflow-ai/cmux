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

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::pin::Pin;
use std::task::{Context, Poll};
use std::time::Duration;

use cmux_transport::PathId;

use crate::pacing::Priority;
use crate::underlay_batch::STAGE_LIMIT;
pub use crate::underlay_batch::{Mark, ReceiveBatch, SendBatch};
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
/// Refusals in a row (about 3 s of retries) after which the interface is
/// taken as gone: the oldest datagram is dropped so newer ones (a handshake,
/// a keepalive) are not stuck behind it forever. TCP retransmits.
const INTERFACE_RETRY_LIMIT: u32 = 64;
/// How long a path sends one datagram at a time after its socket refused
/// one. A batch is handed over at the end of a pass, so the driver learns of
/// a full socket only after the pass gave it everything; one at a time it
/// learns at the first refusal and stops feeding, which keeps a saturated
/// uplink's backlog in the driver's priority queues (`tests/kernel_queue.rs`).
const UNBATCHED_AFTER_REFUSAL: Duration = Duration::from_secs(1);

/// Receive buffer requested for a tunnel's UDP socket (wireguard-go's
/// `socketBufferSize`). smoltcp sends a whole window at once, and the peer
/// handles each datagram (decrypt, then the stack) more slowly than the
/// kernel delivers them on a fast path, so the kernel's default (208 KiB on
/// Linux, under one 256 KiB window) overflows. smoltcp's fast retransmit
/// recovers few of the lost segments; the rest wait out its 1 s minimum
/// retransmission timeout (HQ 5080: half of the 8 MiB loopback echoes took
/// 1.1 s instead of 0.09 s). The kernel caps the request at
/// `net.core.rmem_max` on Linux and `kern.ipc.maxsockbuf` on macOS.
pub const RECEIVE_BUFFER: usize = 7 << 20;

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
/// next wants anything (shared with every path set, `cmux-braid-path`).
pub use cmux_braid_path::DueProbes;

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

    /// Send one data datagram the pacer let leave in class `priority`. A
    /// carrier that queues by class (a relay over a shared socket) uses
    /// it; the default sends as [`send`](Underlay::send).
    fn send_classified(&mut self, datagram: &[u8], _priority: Priority) {
        self.send(datagram);
    }

    /// Send one liveness datagram (`WgDatagramSocket::send_liveness`): a
    /// single datagram, in the interactive class, never repaired or
    /// replayed (its sender resends it). `answer`: it answers the peer's
    /// liveness ping, so no reply follows it and a carrier that watches
    /// its paths for silence after a send does not start watching. The
    /// default sends it as interactive data.
    fn send_liveness(&mut self, datagram: &[u8], _answer: bool) {
        self.send_classified(datagram, Priority::Interactive);
    }

    /// Send one datagram on `path` only (a probe or its answer). A
    /// single-path carrier has one path.
    fn send_on(&mut self, _path: PathId, datagram: &[u8]) {
        self.send(datagram);
    }

    /// Probes due at `now`. The driver calls this only while the session
    /// carries traffic; a carrier with one path never probes.
    /// Hold routine path probes until `floor`, or lift the hold
    /// (`PathWatch::hold_routine`). An underlay without probes ignores it.
    fn hold_routine_probes(&mut self, _floor: Option<Instant>) {}

    fn poll_probes(&mut self, _now: Instant) -> DueProbes {
        DueProbes::default()
    }

    /// The pong for probe `id`, sent on `path`, arrived at `now`.
    fn on_pong(&mut self, _path: PathId, _id: u64, _now: Instant) {}

    /// The session's `max_datagram`, reported in path events.
    fn set_max_datagram(&mut self, _bytes: usize) {}

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

    /// Whether the carrier moved the session to another route since the last
    /// call (a switch, datagrams going on every path after the current one
    /// went quiet, or the peer roaming to a new address). The driver then has
    /// the tunnel's TCP resend what was in flight at once, instead of waiting
    /// out a timer that backed off while the old route lost it.
    fn take_path_change(&mut self) -> bool {
        false
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

    /// Ask the kernel for a [`RECEIVE_BUFFER`]-byte receive buffer, as far
    /// as it allows. Best effort: a refusal keeps the default. A socket
    /// with no kernel buffer (a simulated one) has nothing to grow.
    fn grow_receive_buffer(&self) {}

    /// Send `batch[from..]` in order, as many as one call takes. Returns how
    /// many left (at least one), or the first one's refusal. The default
    /// sends one; a kernel socket on Linux sends up to 64 messages with one
    /// `sendmmsg`, a run to one address as one GSO message.
    fn try_send_batch(&mut self, batch: &SendBatch, from: usize) -> io::Result<usize> {
        let Some((datagram, target)) = batch.get(from) else { return Ok(0) };
        self.try_send_to(datagram, target).map(|_| 1)
    }

    /// Read what waits into `batch` (empty on entry), at least one
    /// datagram, registering for readiness when none does. The default reads
    /// one; a kernel socket on Linux reads many with one `recvmmsg`.
    fn poll_recv_batch(
        &mut self,
        cx: &mut Context<'_>,
        batch: &mut ReceiveBatch,
    ) -> Poll<io::Result<()>> {
        let mut buffer = vec![0u8; 1 << 16];
        self.poll_recv_from(cx, &mut buffer).map_ok(|(len, from)| {
            batch.push(buffer.get(..len).unwrap_or_default(), from);
        })
    }

    /// As [`poll_recv_batch`](DatagramSocket::poll_recv_batch), without
    /// registering: `WouldBlock` when nothing waits, and always for a
    /// socket that can only be polled.
    fn try_recv_batch(&mut self, _batch: &mut ReceiveBatch) -> io::Result<()> {
        Err(io::ErrorKind::WouldBlock.into())
    }
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

    #[cfg(unix)]
    fn grow_receive_buffer(&self) {
        use std::os::fd::AsRawFd;
        let size = libc::c_int::try_from(RECEIVE_BUFFER).unwrap_or(libc::c_int::MAX);
        let set = |option| {
            // SAFETY: the descriptor is open for the borrow of `self`, and
            // the option value points at a live `c_int` of the length passed.
            unsafe {
                libc::setsockopt(
                    self.as_raw_fd(),
                    libc::SOL_SOCKET,
                    option,
                    (&raw const size).cast(),
                    size_of_val(&size) as libc::socklen_t,
                )
            }
        };
        // Past `net.core.rmem_max` only with CAP_NET_ADMIN (wireguard-go
        // does the same); without it the capped request below still holds.
        #[cfg(any(target_os = "linux", target_os = "android"))]
        if set(libc::SO_RCVBUFFORCE) == 0 {
            return;
        }
        let _ = set(libc::SO_RCVBUF);
        // Every read goes through `recv_batch`, which splits what GRO joins.
        #[cfg(target_os = "linux")]
        crate::underlay_batch::linux::enable_gro(self.as_raw_fd());
    }

    #[cfg(target_os = "linux")]
    fn try_send_batch(&mut self, batch: &SendBatch, from: usize) -> io::Result<usize> {
        use std::os::fd::AsRawFd;
        let fd = self.as_raw_fd();
        self.try_io(tokio::io::Interest::WRITABLE, || {
            crate::underlay_batch::linux::send(fd, batch, from)
        })
    }

    #[cfg(any(target_os = "macos", target_os = "ios"))]
    fn try_send_batch(&mut self, batch: &SendBatch, from: usize) -> io::Result<usize> {
        use std::os::fd::AsRawFd;
        let Some((datagram, target)) = batch.get(from) else { return Ok(0) };
        if batch.mark(from) == Mark::Voice && crate::underlay_batch::marking() {
            let fd = self.as_raw_fd();
            match self.try_io(tokio::io::Interest::WRITABLE, || {
                crate::underlay_batch::apple::send_voice(fd, datagram, target)
            }) {
                Err(error) if crate::underlay_batch::marks_refused(&error, true) => {}
                result => return result.map(|_| 1),
            }
        }
        UdpSocket::try_send_to(self, datagram, target).map(|_| 1)
    }

    #[cfg(target_os = "linux")]
    fn poll_recv_batch(
        &mut self,
        cx: &mut Context<'_>,
        batch: &mut ReceiveBatch,
    ) -> Poll<io::Result<()>> {
        loop {
            std::task::ready!(self.poll_recv_ready(cx))?;
            match self.try_recv_batch(batch) {
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
                result => return Poll::Ready(result),
            }
        }
    }

    #[cfg(target_os = "linux")]
    fn try_recv_batch(&mut self, batch: &mut ReceiveBatch) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        let fd = self.as_raw_fd();
        self.try_io(tokio::io::Interest::READABLE, || crate::underlay_batch::linux::recv(fd, batch))
    }

    #[cfg(not(target_os = "linux"))]
    fn try_recv_batch(&mut self, batch: &mut ReceiveBatch) -> io::Result<()> {
        let mut buffer = vec![0u8; 1 << 16];
        let (len, from) = UdpSocket::try_recv_from(self, &mut buffer)?;
        batch.push(buffer.get(..len).unwrap_or_default(), from);
        Ok(())
    }
}

/// One socket and the peer's address on it. The address follows the source
/// of the latest authenticated datagram, and starts unknown on a side that
/// only answers.
pub struct SocketPath<S> {
    socket: S,
    peer: Option<SocketAddr>,
    /// Datagrams not yet sent, oldest first: this pass's, sent together at
    /// its flush (or once [`STAGE_LIMIT`] wait), and any the socket refused.
    queue: SendBatch,
    /// The socket refused the queue's front: the driver feeds no more data
    /// until [`Underlay::poll_flush`] drains it.
    waiting: bool,
    /// Datagrams the last batched read took and the driver has not had.
    received: ReceiveBatch,
    /// Until when sends go one at a time ([`UNBATCHED_AFTER_REFUSAL`]).
    unbatched_until: Option<Instant>,
    /// Armed after the interface refused a datagram.
    retry: Option<Pin<Box<Sleep>>>,
    retry_after: Duration,
    refusals: u32,
    /// The peer roamed to a new address after a silence, since the last
    /// `take_path_change`.
    roamed: bool,
    /// When the peer last sent an authenticated datagram, from any address.
    heard: Option<Instant>,
}

/// How long the peer must have been silent before a datagram from a new
/// address counts as the peer moving off a lost path: the multipath
/// selector's shortest silence window, so a path cut under a stream counts and
/// paths that alternate while both answer do not.
const ROAM_QUIET: Duration = Duration::from_millis(100);

/// The default underlay: one UDP socket, one peer address.
pub type UdpUnderlay = SocketPath<UdpSocket>;

impl<S: DatagramSocket> SocketPath<S> {
    pub fn new(socket: S, peer: Option<SocketAddr>) -> Self {
        socket.grow_receive_buffer();
        Self {
            socket,
            peer,
            queue: SendBatch::default(),
            waiting: false,
            received: ReceiveBatch::default(),
            unbatched_until: None,
            retry: None,
            retry_after: INTERFACE_RETRY_MIN,
            refusals: 0,
            roamed: false,
            heard: None,
        }
    }

    pub fn socket(&self) -> &S {
        &self.socket
    }

    pub fn peer(&self) -> Option<SocketAddr> {
        self.peer
    }

    /// Send one datagram to `peer`, or queue it behind earlier ones while
    /// the socket is unwritable. The mesh addresses each peer this way on
    /// one shared socket.
    pub(crate) fn send_to(&mut self, datagram: &[u8], peer: SocketAddr) {
        self.send_marked(datagram, peer, Mark::Plain);
    }

    /// As [`send_to`](Self::send_to), asking the networks on the way to
    /// queue it as `mark` says.
    pub(crate) fn send_marked(&mut self, datagram: &[u8], peer: SocketAddr, mark: Mark) {
        if self.waiting {
            self.flush();
        }
        if self.waiting {
            if self.queue.len() < SEND_QUEUE_DEPTH {
                self.queue.push_marked(datagram, peer, mark);
            } else {
                eprintln!("wireguard UDP send to {peer} dropped: the socket never drained");
            }
            return;
        }
        self.queue.push_marked(datagram, peer, mark);
        let unbatched = self.unbatched_until.is_some_and(|until| Instant::now() < until);
        if unbatched || self.queue.len() >= STAGE_LIMIT {
            self.send_queued();
        }
    }

    fn refused(&mut self) {
        self.waiting = true;
        self.unbatched_until = Some(Instant::now() + UNBATCHED_AFTER_REFUSAL);
    }

    /// Send what is queued, in as few calls as the socket allows, until it
    /// refuses; what it refused waits, in order, for writability.
    fn send_queued(&mut self) {
        while !self.queue.is_empty() {
            match self.socket.try_send_batch(&self.queue, 0) {
                Ok(sent) => self.queue.consume(sent.max(1)),
                Err(error) if refusal(&error).is_some() => {
                    self.refused();
                    return;
                }
                Err(error) => {
                    if let Some((_, peer)) = self.queue.get(0) {
                        eprintln!("wireguard UDP send to {peer} failed: {error}");
                    }
                    self.queue.consume(1);
                }
            }
        }
        self.waiting = false;
    }

    /// The next datagram already read, or one read now without waiting:
    /// `WouldBlock` when none waits.
    pub(crate) fn try_recv(&mut self, buffer: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        if self.received.is_empty() {
            self.socket.try_recv_batch(&mut self.received)?;
        }
        self.received.pop_into(buffer).ok_or_else(|| io::ErrorKind::WouldBlock.into())
    }
}

impl<S: DatagramSocket> Underlay for SocketPath<S> {
    fn send(&mut self, datagram: &[u8]) {
        if let Some(peer) = self.peer {
            self.send_to(datagram, peer);
        }
    }

    fn send_classified(&mut self, datagram: &[u8], priority: Priority) {
        if let Some(peer) = self.peer {
            self.send_marked(datagram, peer, mark_for(priority));
        }
    }

    fn flush(&mut self) {
        // A carrier not in use is flushed only here: an expired retry must
        // not keep it waiting for a poll_flush that never comes.
        if self.retry.as_ref().is_some_and(|retry| retry.deadline() <= Instant::now()) {
            self.retry = None;
        }
        if self.retry.is_none() {
            self.send_queued();
        }
    }

    fn backlogged(&self) -> bool {
        self.waiting && !self.queue.is_empty()
    }

    fn poll_flush(&mut self, cx: &mut Context<'_>) -> Poll<()> {
        while !self.queue.is_empty() {
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
                    self.queue.clear();
                    break;
                }
                Poll::Ready(Ok(())) => {}
            }
            match self.socket.try_send_batch(&self.queue, 0) {
                Ok(sent) => {
                    self.queue.consume(sent.max(1));
                    self.retry_after = INTERFACE_RETRY_MIN;
                    self.refusals = 0;
                }
                Err(error) => {
                    let peer =
                        self.queue.get(0).map_or_else(String::new, |(_, peer)| peer.to_string());
                    match refusal(&error) {
                        // Readiness was stale; the next poll registers interest.
                        Some(Refusal::SocketFull) => self.refused(),
                        Some(Refusal::InterfaceFull) => {
                            self.refused();
                            self.refusals += 1;
                            if self.refusals >= INTERFACE_RETRY_LIMIT {
                                eprintln!("wireguard UDP send to {peer} dropped: {error} for 3 s");
                                self.queue.consume(1);
                                self.refusals = 0;
                            }
                            self.retry = Some(Box::pin(tokio::time::sleep(self.retry_after)));
                            self.retry_after = (self.retry_after * 2).min(INTERFACE_RETRY_MAX);
                        }
                        None => {
                            eprintln!("wireguard UDP send to {peer} failed: {error}");
                            self.queue.consume(1);
                        }
                    }
                }
            }
        }
        self.waiting = false;
        Poll::Ready(())
    }

    fn poll_recv(&mut self, cx: &mut Context<'_>, buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        loop {
            if let Some((len, source)) = self.received.pop_into(buffer) {
                let origin = Origin { path: PathId(0), addr: Some(source) };
                return Poll::Ready(Ok(Received { len, origin }));
            }
            if !self.received.is_empty() {
                continue; // one too long for `buffer`, dropped
            }
            std::task::ready!(self.socket.poll_recv_batch(cx, &mut self.received))?;
        }
    }

    fn authenticated(&mut self, origin: Origin) {
        if let Some(addr) = origin.addr {
            // Learning the first address is not a move, and neither is a peer
            // whose datagrams alternate between live paths (probes on one,
            // data on another). A new address after the peer went silent is:
            // whatever was sent to the old one in that silence is lost.
            let now = Instant::now();
            let quiet = self.heard.is_none_or(|heard| now - heard >= ROAM_QUIET);
            self.roamed |= quiet && self.peer.is_some_and(|peer| peer != addr);
            self.peer = Some(addr);
            self.heard = Some(now);
        }
    }

    fn has_peer(&self) -> bool {
        self.peer.is_some()
    }

    fn peer_hint(&self) -> Option<SocketAddr> {
        self.peer
    }

    fn take_path_change(&mut self) -> bool {
        std::mem::take(&mut self.roamed)
    }
}

/// The [`Mark`] a class asks for: input and screen state (classes 0 and 1)
/// go in the voice queue; media and bulk keep best effort, so a download
/// is not pushed into Wi-Fi's background queue behind other people's traffic.
pub(crate) fn mark_for(priority: Priority) -> Mark {
    match priority {
        Priority::Screen | Priority::Interactive => Mark::Voice,
        Priority::Media | Priority::Bulk => Mark::Plain,
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
