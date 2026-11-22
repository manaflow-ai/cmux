//! The mesh's outbound side: its UDP socket and its gateways.
//!
//! A gateway is a [`WgDatagramSocket`] inside a gateway tunnel (a
//! [`crate::WgNet`] session). The socket's methods are async, and the mesh
//! driver never awaits on its send path, so each gateway gets a small task
//! that owns the socket:
//!
//! - outbound, the driver queues `(datagram, address)` on a bounded channel
//!   and never waits: a full queue drops the datagram, as a full socket
//!   buffer would, and WireGuard and TCP recover;
//! - inbound, the task forwards every datagram, tagged with the gateway's
//!   id, to one channel the driver selects on next to its UDP socket.
//!
//! Removing a gateway closes its outbound channel and aborts the task, which
//! drops the socket and unbinds its port. A datagram from a gateway that is
//! gone when the driver reads it is ignored, so it cannot route a peer to a
//! dead gateway.

use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};

use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::error::WgError;
use crate::mesh_route::{GatewayId, PeerRoute};
use crate::net::WgDatagramSocket;
use crate::pacing::Priority;
use crate::underlay::SocketPath;

/// A WireGuard data message's overhead over the packet it carries: type,
/// receiver index and counter (16 bytes) plus the AEAD tag (16 bytes).
pub(crate) const WIREGUARD_DATA_OVERHEAD: usize = 32;
/// Datagrams queued toward one gateway before new ones are dropped.
const GATEWAY_OUTBOX: usize = 512;
/// Datagrams from all gateways waiting for the driver.
pub(crate) const GATEWAY_INBOX: usize = 512;

/// A datagram that arrived through a gateway: which one, payload, source.
pub(crate) type GatewayDatagram = (GatewayId, Vec<u8>, SocketAddr);

struct GatewayLink {
    outbox: mpsc::Sender<(Vec<u8>, SocketAddr)>,
    /// The tunnel socket's `max_datagram`.
    max_datagram: usize,
    task: JoinHandle<()>,
}

/// Where the mesh's datagrams leave: the UDP socket, or a gateway.
pub(crate) struct Outbound {
    pub(crate) udp: SocketPath<UdpSocket>,
    /// The socket's own address, to map endpoints to its family.
    local: SocketAddr,
    gateways: HashMap<GatewayId, GatewayLink>,
    next_gateway: u64,
    inbox: mpsc::Sender<GatewayDatagram>,
}

impl Outbound {
    pub(crate) fn new(
        udp: SocketPath<UdpSocket>,
        local: SocketAddr,
        inbox: mpsc::Sender<GatewayDatagram>,
    ) -> Self {
        Self { udp, local, gateways: HashMap::new(), next_gateway: 1, inbox }
    }

    /// Send `datagram` on `route`. A UDP endpoint is mapped to the socket's
    /// address family (a dual-stack IPv6 socket reaches IPv4 peers through
    /// mapped addresses). A gateway route drops a datagram larger than its
    /// tunnel carries (never one of this mesh: [`Outbound::attach`] checks
    /// the MTU), a datagram to a removed gateway, and one its full queue
    /// refuses.
    pub(crate) fn send(&mut self, route: Option<PeerRoute>, datagram: &[u8]) {
        match route {
            None => {}
            Some(PeerRoute::Udp(target)) => {
                let target = match (self.local, target) {
                    (SocketAddr::V6(_), SocketAddr::V4(v4)) => {
                        SocketAddr::new(IpAddr::V6(v4.ip().to_ipv6_mapped()), v4.port())
                    }
                    (SocketAddr::V4(_), SocketAddr::V6(v6)) => match v6.ip().to_ipv4_mapped() {
                        Some(v4) => SocketAddr::new(IpAddr::V4(v4), v6.port()),
                        None => return,
                    },
                    _ => target,
                };
                self.udp.send_to(datagram, target);
            }
            Some(PeerRoute::Gateway { gateway, address }) => {
                let Some(link) = self.gateways.get(&gateway) else { return };
                if datagram.len() <= link.max_datagram {
                    let _ = link.outbox.try_send((datagram.to_vec(), address));
                }
            }
        }
    }

    /// Attach `socket` as a gateway for a mesh whose inner MTU is `mtu`.
    /// The tunnel must carry a full-size WireGuard data message of the mesh:
    /// `mtu + 32` bytes. Must run inside a Tokio runtime.
    pub(crate) fn attach(
        &mut self,
        socket: WgDatagramSocket,
        mtu: u16,
    ) -> Result<GatewayId, WgError> {
        let needed = usize::from(mtu) + WIREGUARD_DATA_OVERHEAD;
        let max_datagram = socket.max_datagram();
        if max_datagram < needed {
            return Err(WgError::DatagramTooLarge { len: needed, max: max_datagram });
        }
        let id = GatewayId(self.next_gateway);
        self.next_gateway += 1;
        let (outbox, queued) = mpsc::channel(GATEWAY_OUTBOX);
        let task = tokio::spawn(run_gateway(id, socket, queued, self.inbox.clone()));
        self.gateways.insert(id, GatewayLink { outbox, max_datagram, task });
        Ok(id)
    }

    /// Detach a gateway; returns whether it existed.
    pub(crate) fn detach(&mut self, gateway: GatewayId) -> bool {
        let Some(link) = self.gateways.remove(&gateway) else { return false };
        link.task.abort();
        true
    }

    pub(crate) fn has_gateway(&self, gateway: GatewayId) -> bool {
        self.gateways.contains_key(&gateway)
    }

    /// Detach every gateway (the mesh is stopping). Unlike
    /// [`Outbound::detach`] the tasks are not aborted: each sends what is
    /// already queued (the resets of a shutdown), then sees its closed outbox
    /// and ends.
    pub(crate) fn detach_all(&mut self) {
        self.gateways.clear();
    }
}

enum Event {
    Received(Option<(Vec<u8>, SocketAddr)>),
    Queued(Option<(Vec<u8>, SocketAddr)>),
}

/// Own one gateway socket: forward what arrives to the driver and send what
/// the driver queues. Ends when the tunnel, the driver or the outbox is gone.
async fn run_gateway(
    id: GatewayId,
    mut socket: WgDatagramSocket,
    mut queued: mpsc::Receiver<(Vec<u8>, SocketAddr)>,
    inbox: mpsc::Sender<GatewayDatagram>,
) {
    loop {
        let event = tokio::select! {
            received = socket.recv_from() => Event::Received(received),
            next = queued.recv() => Event::Queued(next),
        };
        match event {
            Event::Received(Some((payload, source))) => {
                if inbox.send((id, payload, source)).await.is_err() {
                    return;
                }
            }
            // Nested WireGuard carries the link's interactive traffic, and
            // the mesh paces its own connections, so its datagrams go first
            // in the tunnel's scheduler.
            Event::Queued(Some((datagram, address))) => {
                let sent = socket.send_to(&datagram, address, Priority::Interactive).await;
                if matches!(sent, Err(WgError::Shutdown)) {
                    return;
                }
            }
            Event::Received(None) | Event::Queued(None) => return,
        }
    }
}
