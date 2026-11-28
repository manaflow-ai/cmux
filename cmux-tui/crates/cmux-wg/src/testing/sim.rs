//! An in-memory datagram network with per-link latency and cuts.
//!
//! [`SimNet`] behaves like UDP between addresses that exist only in the test:
//! [`SimNet::bind`] gives a [`SimSocket`] (a [`DatagramSocket`], so it plugs
//! into [`crate::SocketPath`] exactly as a UDP socket does), and every
//! datagram is delivered to the socket bound at its destination address, with
//! the source address it was sent from. A link (an unordered pair of
//! addresses) can add one-way latency, drop everything, or be a bottleneck:
//! a rate in datagrams per second with a drop-tail queue, like a router
//! interface. A socket can have a send buffer drained at a rate, which
//! answers `WouldBlock` when full and signals readiness when a slot frees,
//! like a kernel UDP socket. Latency is applied by one FIFO delay line per
//! direction, so a link never reorders; a path change between two links with
//! different latencies does, as a real one would. Delivery to an address
//! with no socket is a drop.

use std::collections::HashMap;
use std::io;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::sync::{mpsc, watch};
use tokio::time::Instant;

use crate::underlay::DatagramSocket;

type Delivery = (Vec<u8>, SocketAddr);

/// How one link treats datagrams in both directions.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LinkProfile {
    pub latency: Duration,
    /// Drop every datagram.
    pub cut: bool,
    /// Bottleneck rate in datagrams per second per direction; 0 is unlimited.
    pub rate_pps: u32,
    /// Datagrams the bottleneck queues before it drops (drop-tail).
    pub queue: u32,
}

/// A socket's send buffer, drained toward the network at a rate.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SocketProfile {
    /// Datagrams the socket holds before a send answers `WouldBlock`.
    pub send_buffer: u32,
    /// Datagrams per second the socket hands to the network.
    pub rate_pps: u32,
}

/// A FIFO server with a fixed service time and a bounded queue.
#[derive(Debug, Clone, Copy)]
struct Pacer {
    interval: Duration,
    capacity: u32,
    next_free: Option<Instant>,
}

impl Pacer {
    fn new(rate_pps: u32, capacity: u32) -> Option<Self> {
        (rate_pps > 0).then(|| Self {
            interval: Duration::from_secs(1) / rate_pps,
            capacity: capacity.max(1),
            next_free: None,
        })
    }

    /// When a datagram arriving at `at` would start service, if the queue
    /// has room for it.
    fn start(&self, at: Instant) -> Option<Instant> {
        let start = self.next_free.map_or(at, |free| free.max(at));
        let backlog = (start - at).as_nanos() / self.interval.as_nanos();
        (backlog < u128::from(self.capacity)).then_some(start)
    }

    /// Queue one datagram arriving at `at`; returns when it has left, or
    /// `None` if the queue is full.
    fn admit(&mut self, at: Instant) -> Option<Instant> {
        let done = self.start(at)? + self.interval;
        self.next_free = Some(done);
        Some(done)
    }

    /// The earliest time a datagram would be admitted.
    fn free_at(&self) -> Instant {
        let full = self.interval * self.capacity;
        self.next_free.map_or_else(Instant::now, |free| free - full + Duration::from_nanos(1))
    }
}

#[derive(Default)]
struct Inner {
    /// Bound sockets by address, each with the generation it was bound at.
    endpoints: HashMap<SocketAddr, (u64, mpsc::UnboundedSender<Delivery>)>,
    generation: u64,
    links: HashMap<(SocketAddr, SocketAddr), LinkProfile>,
    /// One delay line per direction of a link with latency.
    lines: HashMap<(SocketAddr, SocketAddr), mpsc::UnboundedSender<(Instant, Delivery)>>,
    /// The bottleneck of each direction of a rate-limited link.
    pipes: HashMap<(SocketAddr, SocketAddr), (u32, u32, Pacer)>,
    /// Datagrams each address handed to the network.
    sent: HashMap<SocketAddr, u64>,
}

/// The network. Cheap to clone; every clone is the same network.
#[derive(Clone)]
pub struct SimNet {
    inner: Arc<Mutex<Inner>>,
    dropped: Arc<watch::Sender<u64>>,
}

impl Default for SimNet {
    fn default() -> Self {
        Self::new()
    }
}

fn link_key(a: SocketAddr, b: SocketAddr) -> (SocketAddr, SocketAddr) {
    if a <= b { (a, b) } else { (b, a) }
}

impl SimNet {
    pub fn new() -> Self {
        Self { inner: Arc::default(), dropped: Arc::new(watch::channel(0).0) }
    }

    fn lock(&self) -> MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Bind a socket at `addr`. Fails if another socket holds it.
    pub fn bind(&self, addr: SocketAddr) -> io::Result<SimSocket> {
        self.bind_socket(addr, None)
    }

    /// Bind a socket with a bounded, rate-drained send buffer.
    pub fn bind_with(&self, addr: SocketAddr, profile: SocketProfile) -> io::Result<SimSocket> {
        self.bind_socket(addr, Pacer::new(profile.rate_pps, profile.send_buffer))
    }

    fn bind_socket(&self, addr: SocketAddr, egress: Option<Pacer>) -> io::Result<SimSocket> {
        let mut inner = self.lock();
        if inner.endpoints.contains_key(&addr) {
            return Err(io::Error::new(io::ErrorKind::AddrInUse, format!("{addr} is bound")));
        }
        let (sender, receiver) = mpsc::unbounded_channel();
        inner.generation += 1;
        let generation = inner.generation;
        inner.endpoints.insert(addr, (generation, sender));
        Ok(SimSocket { net: self.clone(), addr, generation, inbound: receiver, egress })
    }

    /// Set the behavior of the link between `a` and `b`, both directions.
    pub fn set_link(&self, a: SocketAddr, b: SocketAddr, profile: LinkProfile) {
        self.lock().links.insert(link_key(a, b), profile);
    }

    /// Datagrams the socket at `addr` handed to the network so far.
    pub fn sent_from(&self, addr: SocketAddr) -> u64 {
        self.lock().sent.get(&addr).copied().unwrap_or(0)
    }

    /// Datagrams dropped so far (cut links, full bottleneck queues and
    /// unbound destinations).
    pub fn dropped(&self) -> u64 {
        *self.dropped.borrow()
    }

    /// Wait until at least `count` datagrams were dropped.
    pub async fn wait_dropped(&self, count: u64) {
        let mut receiver = self.dropped.subscribe();
        let _ = receiver.wait_for(|dropped| *dropped >= count).await;
    }

    fn drop_one(&self) {
        self.dropped.send_modify(|dropped| *dropped += 1);
    }

    /// Carry one datagram that leaves its socket at `release`.
    fn send(&self, from: SocketAddr, to: SocketAddr, datagram: &[u8], release: Instant) {
        let mut inner = self.lock();
        *inner.sent.entry(from).or_default() += 1;
        let profile = inner.links.get(&link_key(from, to)).copied().unwrap_or_default();
        let Some((_, endpoint)) = inner.endpoints.get(&to).cloned() else {
            drop(inner);
            self.drop_one();
            return;
        };
        if profile.cut {
            drop(inner);
            self.drop_one();
            return;
        }
        let mut at = release;
        if profile.rate_pps > 0 {
            let (rate, queue) = (profile.rate_pps, profile.queue);
            let pipe = inner.pipes.entry((from, to)).or_insert_with(|| {
                (rate, queue, Pacer::new(rate, queue).expect("rate is positive"))
            });
            if (pipe.0, pipe.1) != (rate, queue) {
                *pipe = (rate, queue, Pacer::new(rate, queue).expect("rate is positive"));
            }
            match pipe.2.admit(release) {
                Some(done) => at = done,
                None => {
                    drop(inner);
                    self.drop_one();
                    return;
                }
            }
        }
        at += profile.latency;
        let delivery = (datagram.to_vec(), from);
        if at <= Instant::now() && !inner.lines.contains_key(&(from, to)) {
            let _ = endpoint.send(delivery);
            return;
        }
        let line =
            inner.lines.entry((from, to)).or_insert_with(|| spawn_delay_line(self.clone(), to));
        let _ = line.send((at, delivery));
    }

    fn unbind(&self, addr: SocketAddr, generation: u64) {
        let mut inner = self.lock();
        if inner.endpoints.get(&addr).is_some_and(|(bound, _)| *bound == generation) {
            inner.endpoints.remove(&addr);
        }
    }
}

/// Deliver datagrams for one direction of one link in order, each at its
/// due time. The destination is looked up at delivery, so a datagram in
/// flight to a socket that has gone is dropped, as UDP would.
fn spawn_delay_line(net: SimNet, to: SocketAddr) -> mpsc::UnboundedSender<(Instant, Delivery)> {
    let (sender, mut receiver) = mpsc::unbounded_channel::<(Instant, Delivery)>();
    tokio::spawn(async move {
        while let Some((at, delivery)) = receiver.recv().await {
            tokio::time::sleep_until(at).await;
            let endpoint = net.lock().endpoints.get(&to).map(|(_, sender)| sender.clone());
            match endpoint {
                Some(endpoint) if endpoint.send(delivery).is_ok() => {}
                _ => net.drop_one(),
            }
        }
    });
    sender
}

/// A socket on a [`SimNet`]. Dropping it unbinds the address.
pub struct SimSocket {
    net: SimNet,
    addr: SocketAddr,
    generation: u64,
    inbound: mpsc::UnboundedReceiver<Delivery>,
    egress: Option<Pacer>,
}

impl Drop for SimSocket {
    fn drop(&mut self) {
        self.net.unbind(self.addr, self.generation);
    }
}

impl DatagramSocket for SimSocket {
    fn poll_recv_from(
        &mut self,
        cx: &mut Context<'_>,
        buffer: &mut [u8],
    ) -> Poll<io::Result<(usize, SocketAddr)>> {
        match self.inbound.poll_recv(cx) {
            Poll::Ready(Some((datagram, from))) => {
                let len = datagram.len().min(buffer.len());
                buffer[..len].copy_from_slice(&datagram[..len]);
                Poll::Ready(Ok((len, from)))
            }
            // The network keeps a sender while the socket is bound.
            Poll::Ready(None) | Poll::Pending => Poll::Pending,
        }
    }

    fn poll_send_ready(&mut self, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        let Some(egress) = &self.egress else { return Poll::Ready(Ok(())) };
        if egress.start(Instant::now()).is_some() {
            return Poll::Ready(Ok(()));
        }
        let (free_at, waker) = (egress.free_at(), cx.waker().clone());
        tokio::spawn(async move {
            tokio::time::sleep_until(free_at).await;
            waker.wake();
        });
        Poll::Pending
    }

    fn try_send_to(&mut self, datagram: &[u8], target: SocketAddr) -> io::Result<usize> {
        let now = Instant::now();
        let release = match &mut self.egress {
            Some(egress) => egress.admit(now).ok_or(io::ErrorKind::WouldBlock)?,
            None => now,
        };
        self.net.send(self.addr, target, datagram, release);
        Ok(datagram.len())
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.addr)
    }
}
