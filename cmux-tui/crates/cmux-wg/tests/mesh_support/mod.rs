//! Shared helpers for the mesh tests: nodes on loopback UDP, peers, echo.

#![allow(dead_code)]

use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use cmux_wg::testing::random_keypair;
use cmux_wg::{
    InterfaceAddress, IpNetwork, WgMesh, WgMeshConfig, WgMeshListener, WgPeer, WgStream,
};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use zeroize::Zeroizing;

pub const TIMEOUT: Duration = Duration::from_secs(15);
/// The overlay port of `cmux link` connections.
pub const LINK_PORT: u16 = 4100;
/// How long a test waits for something that must not happen.
pub const QUIET: Duration = Duration::from_secs(3);

pub async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(TIMEOUT, future).await.expect("timed out")
}

/// An overlay IPv6 address in the cmux prefix.
pub fn overlay(last: u16) -> IpAddr {
    IpAddr::V6(Ipv6Addr::new(0xfd7c, 0x6d78, 0, 0, 0, 0, 0, last))
}

/// The single-address network of `address`.
pub fn host(address: IpAddr) -> IpNetwork {
    let prefix = if address.is_ipv4() { 32 } else { 128 };
    IpNetwork::new(address, prefix).expect("host network")
}

pub struct Node {
    pub mesh: WgMesh,
    pub public: [u8; 32],
    pub udp: SocketAddr,
    pub addresses: Vec<IpAddr>,
    pub private: [u8; 32],
}

/// A mesh on a fresh loopback UDP socket with these overlay addresses.
pub async fn node(addresses: &[IpAddr]) -> Node {
    let (private, public) = random_keypair();
    node_with_key(addresses, private, public).await
}

/// A mesh with a given key, for a peer that restarts on a new socket.
pub async fn node_with_key(addresses: &[IpAddr], private: [u8; 32], public: [u8; 32]) -> Node {
    node_with_mtu(addresses, private, public, 1380).await
}

/// A mesh with a given key and inner MTU.
pub async fn node_with_mtu(
    addresses: &[IpAddr],
    private: [u8; 32],
    public: [u8; 32],
    mtu: u16,
) -> Node {
    node_bound(addresses, private, public, mtu, "127.0.0.1:0").await
}

/// A mesh on a socket bound to `bind` (`0.0.0.0:0`: every interface, so it
/// advertises its interface addresses to its peers).
pub async fn node_bound(
    addresses: &[IpAddr],
    private: [u8; 32],
    public: [u8; 32],
    mtu: u16,
    bind: &str,
) -> Node {
    let socket = UdpSocket::bind(bind).await.expect("bind");
    let config = WgMeshConfig {
        private_key: Zeroizing::new(private),
        addresses: addresses
            .iter()
            .map(|address| InterfaceAddress {
                address: *address,
                prefix: if address.is_ipv4() { 32 } else { 128 },
            })
            .collect(),
        mtu,
    };
    let mesh = WgMesh::start(config, socket).expect("start mesh");
    let udp = mesh.local_addr().expect("local addr");
    Node { mesh, public, udp, addresses: addresses.to_vec(), private }
}

/// `node` as a peer routed to `allowed`, at its UDP address or learned.
pub fn peer_of(node: &Node, allowed: &[IpAddr], endpoint: bool) -> WgPeer {
    WgPeer {
        public_key: node.public,
        preshared_key: None,
        allowed_ips: allowed.iter().copied().map(host).collect(),
        route: endpoint.then_some(node.udp.into()),
        candidates: Vec::new(),
        persistent_keepalive: None,
    }
}

/// Accept forever, echo every byte back, and report each accepted
/// connection's key and remote address.
pub fn spawn_echo(
    mut listener: WgMeshListener,
) -> (JoinHandle<()>, mpsc::UnboundedReceiver<([u8; 32], SocketAddr)>) {
    let (accepted_tx, accepted_rx) = mpsc::unbounded_channel();
    let task = tokio::spawn(async move {
        while let Some((mut stream, key)) = listener.accept().await {
            let _ = accepted_tx.send((key, stream.peer_addr()));
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 16 * 1024];
                loop {
                    match stream.read(&mut buffer).await {
                        Ok(0) | Err(_) => break,
                        Ok(count) => {
                            if stream.write_all(&buffer[..count]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = stream.shutdown().await;
            });
        }
    });
    (task, accepted_rx)
}

pub fn payload(len: usize) -> Vec<u8> {
    (0..len).map(|index| (index % 251) as u8).collect()
}

/// Write `len` bytes and read the same bytes back.
pub async fn echo_round_trip(stream: &mut WgStream, len: usize) {
    let data = payload(len);
    let (mut reader, mut writer) = tokio::io::split(stream);
    let write = async {
        writer.write_all(&data).await.expect("write");
    };
    let read = async {
        let mut received = vec![0u8; data.len()];
        reader.read_exact(&mut received).await.expect("read");
        assert!(received == data, "echoed bytes differ");
    };
    within(async { tokio::join!(write, read) }).await;
}

/// A UDP link to `server` with `delay` each way that drops everything, both
/// ways, while the returned switch is set (a pulled cable). Clients dial the
/// returned address; the link answers the latest client.
pub async fn cuttable_link(server: SocketAddr, delay: Duration) -> (SocketAddr, Arc<AtomicBool>) {
    let front = Arc::new(UdpSocket::bind("127.0.0.1:0").await.expect("bind front"));
    let back = Arc::new(UdpSocket::bind("127.0.0.1:0").await.expect("bind back"));
    let address = front.local_addr().expect("front addr");
    let cut = Arc::new(AtomicBool::new(false));
    let client: Arc<Mutex<Option<SocketAddr>>> = Arc::default();
    let forward = |from: Arc<UdpSocket>, to: Arc<UdpSocket>, toward: Option<SocketAddr>| {
        let (cut, client, delay) = (cut.clone(), client.clone(), delay);
        tokio::spawn(async move {
            let mut buffer = vec![0u8; 65_536];
            while let Ok((count, source)) = from.recv_from(&mut buffer).await {
                let target = match toward {
                    Some(server) => {
                        *client.lock().unwrap_or_else(PoisonError::into_inner) = Some(source);
                        server
                    }
                    None => match *client.lock().unwrap_or_else(PoisonError::into_inner) {
                        Some(client) => client,
                        None => continue,
                    },
                };
                if cut.load(Ordering::Relaxed) {
                    continue;
                }
                let (to, datagram) = (to.clone(), buffer[..count].to_vec());
                tokio::spawn(async move {
                    tokio::time::sleep(delay).await;
                    let _ = to.send_to(&datagram, target).await;
                });
            }
        });
    };
    forward(front.clone(), back.clone(), Some(server));
    forward(back, front, None);
    (address, cut)
}
