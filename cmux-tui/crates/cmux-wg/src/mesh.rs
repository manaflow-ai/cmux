//! Many WireGuard peers on one UDP socket.
//!
//! [`WgNet`](crate::WgNet) is one client that reaches one network. A
//! `cmux link` agent instead holds one WireGuard key and talks to several
//! paired peers at once, each with its own session, over one UDP socket and
//! with no relay. [`WgMesh`] is that engine: one userspace TCP/IP interface
//! for this side's overlay addresses, one boringtun session per peer, and
//! WireGuard's crypto-key routing between them:
//!
//! - Outbound, a packet goes to the peer whose `allowed_ips` hold its
//!   destination. The `allowed_ips` of two peers never overlap, so exactly
//!   one peer matches.
//! - Inbound, a datagram reaches a peer's session by its receiver index, or,
//!   for a handshake initiation, by the initiator's static key. An unknown key
//!   gets no answer and leaves no state.
//! - A decrypted packet whose source address is outside the sending peer's
//!   `allowed_ips` is dropped, so an accepted connection always comes from an
//!   address of the peer whose key [`WgMeshListener::accept`] reports. That
//!   key is the key of the session that delivered the SYN, never one looked
//!   up from the source address.

use std::fmt;
use std::io;
use std::net::SocketAddr;

use ip_network::IpNetwork;
use tokio::net::UdpSocket;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

use crate::config::InterfaceAddress;
use crate::error::WgError;
use crate::stream::WgStream;

/// Commands in flight before callers wait.
const COMMAND_DEPTH: usize = 64;

/// This side of a mesh: its key and its overlay addresses.
#[derive(Clone)]
pub struct WgMeshConfig {
    /// This side's Curve25519 private key.
    pub private_key: Zeroizing<[u8; 32]>,
    /// This side's overlay addresses, for example one IPv6 `/128`. At most
    /// one per family is used as a source address.
    pub addresses: Vec<InterfaceAddress>,
    /// Largest IP packet a session carries.
    pub mtu: u16,
}

impl fmt::Debug for WgMeshConfig {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("WgMeshConfig")
            .field("addresses", &self.addresses)
            .field("mtu", &self.mtu)
            .finish_non_exhaustive()
    }
}

/// One peer of a mesh.
#[derive(Clone)]
pub struct WgPeer {
    /// The peer's Curve25519 public key; also its identity in the mesh.
    pub public_key: [u8; 32],
    /// Optional symmetric pre-shared key mixed into the handshake.
    pub preshared_key: Option<Zeroizing<[u8; 32]>>,
    /// Networks routed to this peer, usually its overlay `/128`. Also the
    /// filter for the source address of every packet it sends.
    pub allowed_ips: Vec<IpNetwork>,
    /// Where the peer listens. `None` learns it from the peer's first
    /// authenticated datagram; every later one moves it (roaming).
    pub endpoint: Option<SocketAddr>,
    /// Seconds between keepalives that hold NAT mappings open.
    pub persistent_keepalive: Option<u16>,
}

impl fmt::Debug for WgPeer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        use base64::Engine;
        formatter
            .debug_struct("WgPeer")
            .field("public_key", &base64::engine::general_purpose::STANDARD.encode(self.public_key))
            .field("preshared_key", &self.preshared_key.as_ref().map(|_| "<set>"))
            .field("allowed_ips", &self.allowed_ips)
            .field("endpoint", &self.endpoint)
            .field("persistent_keepalive", &self.persistent_keepalive)
            .finish()
    }
}

/// An accepted connection and the key of the session that delivered its SYN.
pub(crate) type MeshAccepted = (WgStream, Option<[u8; 32]>);

pub(crate) enum MeshCommand {
    AddPeer { peer: WgPeer, reply: oneshot::Sender<Result<(), WgError>> },
    RemovePeer { public_key: [u8; 32], reply: oneshot::Sender<bool> },
    Connect { remote: SocketAddr, reply: oneshot::Sender<Result<WgStream, WgError>> },
    Listen { port: u16, reply: oneshot::Sender<Result<mpsc::Receiver<MeshAccepted>, WgError>> },
    Shutdown,
}

/// A running mesh. Dropping it stops the driver; every stream then reads EOF
/// and fails writes.
pub struct WgMesh {
    commands: mpsc::Sender<MeshCommand>,
    local: SocketAddr,
    driver: Option<JoinHandle<()>>,
}

impl fmt::Debug for WgMesh {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("WgMesh").field("local", &self.local).finish_non_exhaustive()
    }
}

impl WgMesh {
    /// Start the mesh on a UDP socket the caller bound (any family; a
    /// dual-stack IPv6 socket reaches IPv4 endpoints too). It has no peers
    /// until [`WgMesh::add_peer`]. Must run inside a Tokio runtime.
    pub fn start(config: WgMeshConfig, socket: UdpSocket) -> Result<Self, WgError> {
        let local = socket.local_addr()?;
        let (commands, receiver) = mpsc::channel(COMMAND_DEPTH);
        let driver = crate::mesh_driver::spawn(config, socket, receiver)?;
        Ok(Self { commands, local, driver: Some(driver) })
    }

    /// The address of the UDP socket.
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        Ok(self.local)
    }

    /// Add a peer, or replace the peer with the same key. A replaced peer
    /// starts a new session; its connections whose remote address it still
    /// routes stay open, the others fail. Refused with
    /// [`WgError::AllowedIpsOverlap`] when a network overlaps another
    /// peer's.
    pub async fn add_peer(&self, peer: WgPeer) -> Result<(), WgError> {
        let (reply, answer) = oneshot::channel();
        self.send(MeshCommand::AddPeer { peer, reply }).await?;
        answer.await.map_err(|_| WgError::Shutdown)?
    }

    /// Remove a peer and drop its session. Its open connections fail with an
    /// error. Returns whether the peer existed.
    pub async fn remove_peer(&self, public_key: [u8; 32]) -> Result<bool, WgError> {
        let (reply, answer) = oneshot::channel();
        self.send(MeshCommand::RemovePeer { public_key, reply }).await?;
        answer.await.map_err(|_| WgError::Shutdown)
    }

    /// Open a TCP connection to `remote` through the peer whose
    /// `allowed_ips` contain it ([`WgError::NoRoute`] when none does).
    /// Resolves once the three-way handshake completes; callers bound the
    /// wait with their own timeout.
    pub async fn connect(&self, remote: SocketAddr) -> Result<WgStream, WgError> {
        let (reply, answer) = oneshot::channel();
        self.send(MeshCommand::Connect { remote, reply }).await?;
        answer.await.map_err(|_| WgError::Shutdown)?
    }

    /// Accept TCP connections on `port` at every overlay address, from any
    /// peer.
    pub async fn listen(&self, port: u16) -> Result<WgMeshListener, WgError> {
        let (reply, answer) = oneshot::channel();
        self.send(MeshCommand::Listen { port, reply }).await?;
        let incoming = answer.await.map_err(|_| WgError::Shutdown)??;
        Ok(WgMeshListener { port, incoming })
    }

    /// Stop the driver and wait for it to exit. Open connections are reset.
    pub async fn shutdown(mut self) {
        let _ = self.commands.send(MeshCommand::Shutdown).await;
        if let Some(driver) = self.driver.take() {
            let _ = driver.await;
        }
    }

    async fn send(&self, command: MeshCommand) -> Result<(), WgError> {
        self.commands.send(command).await.map_err(|_| WgError::Shutdown)
    }
}

impl Drop for WgMesh {
    fn drop(&mut self) {
        // A full command queue means the driver is alive and busy; it sees the
        // closed channel on its next receive. Only a stuck driver needs the
        // abort.
        if self.commands.try_send(MeshCommand::Shutdown).is_err()
            && let Some(driver) = self.driver.take()
        {
            driver.abort();
        }
    }
}

/// Connections accepted by [`WgMesh::listen`].
pub struct WgMeshListener {
    port: u16,
    incoming: mpsc::Receiver<MeshAccepted>,
}

impl fmt::Debug for WgMeshListener {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("WgMeshListener").field("port", &self.port).finish_non_exhaustive()
    }
}

impl WgMeshListener {
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The next established connection and the public key of the peer it
    /// came from, or `None` once the mesh is gone.
    pub async fn accept(&mut self) -> Option<(WgStream, [u8; 32])> {
        loop {
            // The mesh tags every accepted connection; an untagged one
            // cannot occur and is refused rather than guessed.
            if let (stream, Some(public_key)) = self.incoming.recv().await? {
                return Some((stream, public_key));
            }
        }
    }
}
