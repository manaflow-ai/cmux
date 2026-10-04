//! In-process WireGuard for cmux clients.
//!
//! A cmux Cloud machine sits on its owner's private network and opens no
//! public port. Reaching its daemon therefore needs a WireGuard peer, and the
//! usual way to get one is a system interface: root on macOS, the
//! NetworkExtension entitlement plus a VPN prompt on iOS. This crate is the
//! alternative: the WireGuard peer and a small TCP/IP stack run inside the
//! client process, over one plain UDP socket. Only the client's own
//! connections travel through it, nothing else on the machine changes, and no
//! privilege is needed.
//!
//! Two sans-IO engines are wired together by one driver task:
//!
//! - [`boringtun::noise::Tunn`] holds the WireGuard session (handshake,
//!   encryption, timers, keepalive) and speaks in datagrams.
//! - `smoltcp` holds the IP interface and its TCP sockets and speaks in IP
//!   packets.
//!
//! The driver moves bytes between the underlay (one UDP socket, or several
//! paths to the same peer), the tunnel, and a virtual
//! device that smoltcp polls. Each TCP connection is bridged to a
//! [`WgStream`], which implements Tokio's `AsyncRead` and `AsyncWrite` so the
//! rest of the client cannot tell it apart from a kernel socket.
//!
//! Crypto-key routing is enforced on receive: a decrypted packet whose source
//! address lies outside the peer's `AllowedIPs` is dropped.
//!
//! [`WgNet`] is one client reaching one network through one peer. [`WgMesh`]
//! is the same engine for a `cmux link` agent: one key, one UDP socket, and
//! a session with each of several paired peers, routed by their allowed IPs.

mod config;
mod device;
mod error;
mod mesh;
mod mesh_driver;
mod mesh_peers;
mod mesh_route;
mod multipath;
mod net;
mod pacing;
mod probe_schedule;
mod probing;
mod single_path;
mod stream;
mod tcp_stack;
/// Two-peer loopback harness. Test support for this crate and its dependents;
/// it links no code into a binary that does not call it.
pub mod testing;
mod timers;
mod udp;
mod underlay;
mod watchdog;
mod wire;

pub use cmux_transport::{PathId, PathKind};
pub use config::{ConfigError, DEFAULT_MTU, Endpoint, InterfaceAddress, WgConfig};
pub use ip_network::IpNetwork;
pub use mesh::{WgMesh, WgMeshConfig, WgMeshListener, WgPeer};
pub use mesh_route::{GatewayId, PeerRoute};
pub use multipath::{Multipath, MultipathControl, PathEvent, PathStats};
pub use net::{Datagram, DatagramDrops, WgDatagramSocket, WgError, WgListener, WgNet};
pub use pacing::Priority;
pub use probe_schedule::ProbeConfig;
pub use single_path::MIN_SEND_BUFFER;
pub use stream::WgStream;
pub use underlay::{
    DatagramSocket, DueProbes, Origin, Received, SocketPath, UdpUnderlay, Underlay,
};
