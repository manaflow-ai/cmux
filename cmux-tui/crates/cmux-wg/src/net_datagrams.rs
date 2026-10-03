//! The datagram service (transport.md 12a): unreliable overlay UDP on a
//! registered port. The TCP stack has no UDP sockets, so the driver builds
//! and parses the UDP packets itself. Outgoing datagrams enter the send
//! scheduler in their [`Priority`] class; incoming ones go to the socket
//! bound to their destination port, and datagrams to a port nobody bound
//! are dropped.

use super::*;
use crate::pacing::Priority;
use crate::udp;

/// Datagrams a bound port holds before new ones are dropped (unreliable by
/// design: a reader that falls behind loses the newest, never blocks the
/// session).
const DATAGRAM_INBOX: usize = 256;
/// IPv6 and UDP headers: `max_datagram` is the inner MTU minus these.
pub(crate) const DATAGRAM_OVERHEAD: usize = udp::IPV6_HEADER + udp::UDP_HEADER;

/// A parsed UDP datagram: source, destination, payload.
pub(super) type UdpDatagram = (SocketAddr, SocketAddr, Vec<u8>);

/// One received datagram: payload and the peer's overlay address and port.
pub type Datagram = (Vec<u8>, SocketAddr);

/// A bound overlay UDP port. Dropping it unbinds the port.
pub struct WgDatagramSocket {
    port: u16,
    max_datagram: usize,
    inbound: mpsc::Receiver<Datagram>,
    commands: mpsc::Sender<Command>,
}

impl fmt::Debug for WgDatagramSocket {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("WgDatagramSocket").field("port", &self.port).finish_non_exhaustive()
    }
}

impl WgDatagramSocket {
    pub fn local_port(&self) -> u16 {
        self.port
    }

    /// The largest payload [`WgDatagramSocket::send_to`] accepts.
    pub fn max_datagram(&self) -> usize {
        self.max_datagram
    }

    /// Queue one datagram to `peer` (an overlay address and port) in its
    /// class. Delivery is not guaranteed; media older than 50 ms in the
    /// queue is dropped.
    pub async fn send_to(
        &self,
        payload: &[u8],
        peer: SocketAddr,
        priority: Priority,
    ) -> Result<(), WgError> {
        if payload.len() > self.max_datagram {
            return Err(WgError::DatagramTooLarge { len: payload.len(), max: self.max_datagram });
        }
        let command = Command::SendDatagram {
            from_port: self.port,
            to: peer,
            payload: payload.to_vec(),
            priority,
        };
        self.commands.send(command).await.map_err(|_| WgError::Shutdown)
    }

    /// The next datagram, or `None` once the tunnel is gone.
    pub async fn recv_from(&mut self) -> Option<Datagram> {
        self.inbound.recv().await
    }
}

impl Drop for WgDatagramSocket {
    fn drop(&mut self) {
        let _ = self.commands.try_send(Command::UnbindDatagram { port: self.port });
    }
}

impl WgNet {
    /// The largest datagram payload of this session: the inner MTU minus
    /// the IPv6 and UDP headers, fixed for the session's life.
    pub fn max_datagram(&self) -> usize {
        self.max_datagram
    }

    /// Bind overlay UDP `port` for the datagram service.
    pub async fn bind_datagram(&self, port: u16) -> Result<WgDatagramSocket, WgError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.commands
            .send(Command::BindDatagram { port, reply: reply_tx })
            .await
            .map_err(|_| WgError::Shutdown)?;
        let inbound = reply_rx.await.map_err(|_| WgError::Shutdown)??;
        Ok(WgDatagramSocket {
            port,
            max_datagram: self.max_datagram,
            inbound,
            commands: self.commands.clone(),
        })
    }
}

impl Driver {
    pub(super) fn bind_datagram(&mut self, port: u16) -> Result<mpsc::Receiver<Datagram>, WgError> {
        if port == cmux_transport::probe::PROBE_PORT
            || self.datagram_ports.get(&port).is_some_and(|sender| !sender.is_closed())
        {
            return Err(WgError::ListenerBusy(port));
        }
        let (sender, receiver) = mpsc::channel(DATAGRAM_INBOX);
        self.datagram_ports.insert(port, sender);
        Ok(receiver)
    }

    pub(super) fn send_datagram(
        &mut self,
        from_port: u16,
        to: SocketAddr,
        payload: &[u8],
        priority: Priority,
    ) {
        let Some(local) = self.config.local_address_for(to.ip()) else { return };
        let packet = udp::packet(SocketAddr::new(local, from_port), to, payload);
        let now = Instant::now();
        self.pacer.push_datagram(packet, priority, now);
        self.schedule.on_activity(now);
    }

    /// Hand a received datagram (source, destination, payload) to the
    /// socket bound to its destination port; a datagram to a port nobody
    /// bound is dropped.
    pub(super) fn deliver_datagram(&mut self, (source, destination, payload): UdpDatagram) {
        if let Some(sender) = self.datagram_ports.get(&destination.port()) {
            // A full inbox drops the datagram: unreliable by design.
            let _ = sender.try_send((payload, source));
            self.schedule.on_activity(Instant::now());
        }
    }
}
