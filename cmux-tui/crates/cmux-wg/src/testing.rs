//! A two-peer tunnel over loopback UDP, for tests in this crate and others.
//!
//! Neither side needs root or a network interface: both WireGuard peers live in
//! the test process and exchange datagrams over `127.0.0.1`. The "server" side
//! has no configured endpoint and learns the client's address from the first
//! authenticated datagram, exactly as a listening WireGuard peer does.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use ip_network::IpNetwork;
use tokio::net::UdpSocket;
use zeroize::Zeroizing;

use crate::config::{Endpoint, InterfaceAddress, WgConfig};

pub mod sim;
pub mod tcp_oracle;

/// A fresh Curve25519 keypair as `(private, public)`.
#[allow(
    clippy::expect_used,
    reason = "test support: without operating system randomness no key, and so no test, can exist"
)]
pub fn random_keypair() -> ([u8; 32], [u8; 32]) {
    let mut private = [0u8; 32];
    getrandom::fill(&mut private).expect("operating system randomness");
    let secret = x25519_dalek::StaticSecret::from(private);
    let public = x25519_dalek::PublicKey::from(&secret);
    (secret.to_bytes(), public.to_bytes())
}

pub struct LoopbackPair {
    pub client: WgConfig,
    pub server: WgConfig,
    pub client_socket: UdpSocket,
    pub server_socket: UdpSocket,
    pub client_v4: IpAddr,
    pub server_v4: IpAddr,
    pub client_v6: IpAddr,
    pub server_v6: IpAddr,
}

/// Matching configs for both sides of a tunnel, without sockets.
pub struct ConfigPair {
    pub client: WgConfig,
    pub server: WgConfig,
    pub client_v4: IpAddr,
    pub server_v4: IpAddr,
    pub client_v6: IpAddr,
    pub server_v6: IpAddr,
}

/// Freestyle-shaped configs for both sides over loopback UDP.
pub async fn loopback_pair() -> io::Result<LoopbackPair> {
    let client_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let server_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let ConfigPair { client, server, client_v4, server_v4, client_v6, server_v6 } =
        config_pair(server_socket.local_addr()?);
    Ok(LoopbackPair {
        client,
        server,
        client_socket,
        server_socket,
        client_v4,
        server_v4,
        client_v6,
        server_v6,
    })
}

/// Freestyle-shaped configs for both sides: MTU 1200, one IPv4 and one IPv6
/// address each, dual-family allowed networks, and a client keepalive. The
/// client's endpoint is `server_addr`; the server has none and answers.
#[allow(
    clippy::expect_used,
    reason = "10.200.0.0/24 and fdcc::/64 are valid prefixes with no host bits set"
)]
pub fn config_pair(server_addr: SocketAddr) -> ConfigPair {
    let (client_private, client_public) = random_keypair();
    let (server_private, server_public) = random_keypair();

    let client_v4 = IpAddr::V4(Ipv4Addr::new(10, 200, 0, 1));
    let server_v4 = IpAddr::V4(Ipv4Addr::new(10, 200, 0, 2));
    let client_v6 = IpAddr::V6(Ipv6Addr::new(0xfdcc, 0, 0, 0, 0, 0, 0, 1));
    let server_v6 = IpAddr::V6(Ipv6Addr::new(0xfdcc, 0, 0, 0, 0, 0, 0, 2));
    let allowed = vec![
        IpNetwork::new(Ipv4Addr::new(10, 200, 0, 0), 24).expect("10.200.0.0/24 has no host bits"),
        IpNetwork::new(Ipv6Addr::new(0xfdcc, 0, 0, 0, 0, 0, 0, 0), 64)
            .expect("fdcc::/64 has no host bits"),
    ];

    let client = WgConfig {
        private_key: Zeroizing::new(client_private),
        addresses: vec![
            InterfaceAddress { address: client_v4, prefix: 32 },
            InterfaceAddress { address: client_v6, prefix: 128 },
        ],
        mtu: 1200,
        peer_public_key: server_public,
        preshared_key: None,
        allowed_ips: allowed.clone(),
        endpoint: Some(Endpoint { host: server_addr.ip().to_string(), port: server_addr.port() }),
        persistent_keepalive: Some(5),
        peer_addresses: vec![server_v4, server_v6],
        ultra: crate::UltraChoice::Off,
    };
    let server = WgConfig {
        private_key: Zeroizing::new(server_private),
        addresses: vec![
            InterfaceAddress { address: server_v4, prefix: 32 },
            InterfaceAddress { address: server_v6, prefix: 128 },
        ],
        mtu: 1200,
        peer_public_key: client_public,
        preshared_key: None,
        allowed_ips: allowed,
        endpoint: None,
        persistent_keepalive: None,
        peer_addresses: vec![client_v4, client_v6],
        ultra: crate::UltraChoice::Off,
    };
    ConfigPair { client, server, client_v4, server_v4, client_v6, server_v6 }
}

/// What one datagram a tunnel received carried, for [`set_receive_tap`].
#[derive(Debug, Clone, Copy)]
pub enum Received<'a> {
    /// A handshake initiation or response.
    Handshake,
    /// A cookie reply (the rate limiter's answer).
    Cookie,
    /// A data message that decrypted to nothing: a WireGuard keepalive.
    Keepalive,
    /// A message boringtun refused (a replayed counter: a copy sent on a
    /// second route, a replay after a roam).
    Refused,
    /// The tunnel's own control packets: an ultra hello, an off-path note
    /// or a path probe.
    TunnelControl(&'static str),
    /// An ultra-mode parity datagram, consumed by the repair layer before
    /// WireGuard sees it.
    Parity,
    /// An IP packet for the overlay (TCP, UDP), as decrypted.
    Packet(&'a [u8]),
}

/// Called with the receiving tunnel's first interface address, what the
/// datagram carried and its size on the wire.
pub type ReceiveTap = fn(local: IpAddr, received: Received<'_>, wire_bytes: usize);

static RECEIVE_TAP: std::sync::OnceLock<ReceiveTap> = std::sync::OnceLock::new();

/// Measurement only: every datagram any tunnel in this process receives is
/// reported to `tap`, by what it carried, so a test can attribute each
/// datagram the peer sent to the sender that made it. Set once per process
/// (a test binary of its own); `false` if a tap was already set. Unset, the
/// receive path pays one atomic load.
pub fn set_receive_tap(tap: ReceiveTap) -> bool {
    RECEIVE_TAP.set(tap).is_ok()
}

pub(crate) fn tapping() -> bool {
    RECEIVE_TAP.get().is_some()
}

pub(crate) fn tap_received(local: Option<IpAddr>, received: Received<'_>, wire_bytes: usize) {
    if let (Some(tap), Some(local)) = (RECEIVE_TAP.get(), local) {
        tap(local, received, wire_bytes);
    }
}
