//! A two-peer tunnel over loopback UDP, for tests in this crate and others.
//!
//! Neither side needs root or a network interface: both WireGuard peers live in
//! the test process and exchange datagrams over `127.0.0.1`. The "server" side
//! has no configured endpoint and learns the client's address from the first
//! authenticated datagram, exactly as a listening WireGuard peer does.

use std::io;
use std::net::IpAddr;

use ip_network::IpNetwork;
use tokio::net::UdpSocket;
use zeroize::Zeroizing;

use crate::config::{Endpoint, InterfaceAddress, WgConfig};

/// A fresh Curve25519 keypair as `(private, public)`.
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

/// Freestyle-shaped configs for both sides: MTU 1200, one IPv4 and one IPv6
/// address each, dual-family allowed networks, and a client keepalive.
pub async fn loopback_pair() -> io::Result<LoopbackPair> {
    let (client_private, client_public) = random_keypair();
    let (server_private, server_public) = random_keypair();
    let client_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let server_socket = UdpSocket::bind("127.0.0.1:0").await?;
    let server_addr = server_socket.local_addr()?;

    let client_v4: IpAddr = "10.200.0.1".parse().expect("literal");
    let server_v4: IpAddr = "10.200.0.2".parse().expect("literal");
    let client_v6: IpAddr = "fdcc::1".parse().expect("literal");
    let server_v6: IpAddr = "fdcc::2".parse().expect("literal");
    let allowed = vec![
        IpNetwork::new("10.200.0.0".parse::<IpAddr>().expect("literal"), 24).expect("prefix"),
        IpNetwork::new("fdcc::".parse::<IpAddr>().expect("literal"), 64).expect("prefix"),
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
    };
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
