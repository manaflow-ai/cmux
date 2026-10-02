//! An in-memory datagram network with per-link latency and cuts.
//!
//! [`SimNet`] behaves like UDP between addresses that exist only in the test:
//! [`SimNet::bind`] gives a [`SimSocket`] (a [`DatagramSocket`], so it plugs
//! into [`crate::SocketPath`] exactly as a UDP socket does), and every
//! datagram is delivered to the socket bound at its destination address, with
//! the source address it was sent from. A link (an unordered pair of
//! addresses) can add one-way latency or drop everything. Latency is applied
//! by one FIFO delay line per direction, so a link never reorders; a path
//! change between two links with different latencies does, as a real one
//! would. Delivery to an address with no socket is a drop.

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
}

#[derive(Default)]
struct Inner {
    /// Bound sockets by address, each with the generation it was bound at.
    endpoints: HashMap<SocketAddr, (u64, mpsc::UnboundedSender<Delivery>)>,
    generation: u64,
    links: HashMap<(SocketAddr, SocketAddr), LinkProfile>,
    /// One delay line per direction of a link with latency.
    lines: HashMap<(SocketAddr, SocketAddr), mpsc::UnboundedSender<(Instant, Delivery)>>,
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
        let mut inner = self.lock();
        if inner.endpoints.contains_key(&addr) {
            return Err(io::Error::new(io::ErrorKind::AddrInUse, format!("{addr} is bound")));
        }
        let (sender, receiver) = mpsc::unbounded_channel();
        inner.generation += 1;
        let generation = inner.generation;
        inner.endpoints.insert(addr, (generation, sender));
        Ok(SimSocket { net: self.clone(), addr, generation, inbound: receiver })
    }

    /// Set the behavior of the link between `a` and `b`, both directions.
    pub fn set_link(&self, a: SocketAddr, b: SocketAddr, profile: LinkProfile) {
        self.lock().links.insert(link_key(a, b), profile);
    }

    /// Datagrams dropped so far (cut links and unbound destinations).
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

    fn send(&self, from: SocketAddr, to: SocketAddr, datagram: &[u8]) {
        let mut inner = self.lock();
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
        let delivery = (datagram.to_vec(), from);
        if profile.latency.is_zero() {
            let _ = endpoint.send(delivery);
            return;
        }
        let at = Instant::now() + profile.latency;
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

    fn try_send_to(&mut self, datagram: &[u8], target: SocketAddr) -> io::Result<usize> {
        self.net.send(self.addr, target, datagram);
        Ok(datagram.len())
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.addr)
    }
}
