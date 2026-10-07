//! End to end on one machine: a dial on link B crosses two real WireGuard
//! meshes on loopback UDP and reaches link A's daemon remote entry, stamped
//! with B's paired identity; bytes flow both ways.

use std::net::{IpAddr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_link::overlay_addr::overlay_address;
use cmux_link::pairing::{PairingRecord, Pairings};
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UdpSocket;
use zeroize::Zeroizing;

use super::control::{Peers, serve_overlay};
use super::dial::{Overlay, serve_dial};
use super::mesh::MeshOverlay;

struct Node {
    install: &'static str,
    private: [u8; 32],
    public: [u8; 32],
    socket: UdpSocket,
}

async fn node(install: &'static str) -> Node {
    let (private, public) = cmux_wg::testing::random_keypair();
    let socket = UdpSocket::bind(SocketAddr::from((Ipv6Addr::LOCALHOST, 0))).await.unwrap();
    Node { install, private, public, socket }
}

fn record(node: &Node, endpoint: SocketAddr) -> PairingRecord {
    PairingRecord {
        install: node.install.into(),
        user: "42".into(),
        team: "team_a".into(),
        public_key: STANDARD.encode(node.public),
        endpoint: Some(endpoint),
    }
}

fn mesh(node: Node) -> MeshOverlay {
    let config = WgMeshConfig {
        private_key: Zeroizing::new(node.private),
        addresses: vec![InterfaceAddress {
            address: IpAddr::V6(overlay_address(node.install)),
            prefix: 128,
        }],
        mtu: super::state::LINK_MTU,
    };
    MeshOverlay::new(WgMesh::start(config, node.socket).unwrap(), Zeroizing::new(node.private))
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(10), future).await.expect("within 10 s")
}

#[tokio::test]
async fn a_dial_crosses_two_meshes_and_reaches_the_peer_daemon_entry_stamped() {
    let a = node("inst_a").await;
    let b = node("inst_b").await;
    let (a_udp, b_udp) = (a.socket.local_addr().unwrap(), b.socket.local_addr().unwrap());
    let directory = cmux_unix_socket::short_test_dir("linke2e");

    let mut pairings_a = Pairings::default();
    pairings_a.upsert(record(&b, b_udp)).unwrap();
    let peers_path = directory.path().join("peers.json");
    pairings_a.save(&peers_path).unwrap();
    let mut pairings_b = Pairings::default();
    pairings_b.upsert(record(&a, a_udp)).unwrap();

    let overlay_a = mesh(a);
    let overlay_b = mesh(b);
    overlay_a.sync_peers(&pairings_a).await.unwrap();
    overlay_b.sync_peers(&pairings_b).await.unwrap();

    let session = directory.path().join("s.sock");
    let entry_path = cmux_link::entry_path::remote_entry_socket_path(&session);
    std::fs::create_dir_all(entry_path.parent().unwrap()).unwrap();
    let entry = tokio::net::UnixListener::bind(&entry_path).unwrap();
    let listener = overlay_a.listen(cmux_link::LINK_PORT).await.unwrap();
    let peers = Arc::new(Peers::load(peers_path).unwrap());
    let server = tokio::spawn(serve_overlay(listener, peers, Some(session)));

    let (mut caller, link_side) = tokio::io::duplex(64 * 1024);
    let dial = tokio::spawn(async move { serve_dial(link_side, &overlay_b, &pairings_b).await });
    caller
        .write_all(b"{\"op\":\"link.dial\",\"host\":\"inst_a\",\"service\":\"daemon\"}\nping\n")
        .await
        .unwrap();
    let mut caller = BufReader::new(caller);
    let mut reply = String::new();
    within(caller.read_line(&mut reply)).await.unwrap();
    assert_eq!(reply, "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n");

    let (mut daemon_side, _) = within(entry.accept()).await.unwrap();
    daemon_side.write_all(b"{\"remote_entry\":1}\n").await.unwrap();
    let mut daemon = BufReader::new(daemon_side);
    let mut stamp = String::new();
    within(daemon.read_line(&mut stamp)).await.unwrap();
    assert_eq!(
        stamp,
        "{\"link_peer\":{\"install\":\"inst_b\",\"user\":\"42\",\"team\":\"team_a\"}}\n"
    );
    let mut ping = String::new();
    within(daemon.read_line(&mut ping)).await.unwrap();
    assert_eq!(ping, "ping\n");
    daemon.get_mut().write_all(b"pong\n").await.unwrap();
    let mut pong = String::new();
    within(caller.read_line(&mut pong)).await.unwrap();
    assert_eq!(pong, "pong\n");

    drop(caller);
    drop(daemon);
    within(dial).await.unwrap();
    server.abort();
}

/// A paired install that rotates its key keeps its overlay `/128`; the sync
/// removes the old key before it adds the new one, so the reload succeeds
/// (review P2-2), and syncing the same file again changes nothing.
#[tokio::test]
async fn a_rotated_peer_key_syncs_cleanly() {
    let a = node("inst_a").await;
    let b_old = node("inst_b").await;
    let b_new = node("inst_b").await;
    let endpoint = b_old.socket.local_addr().unwrap();
    let overlay_a = mesh(a);
    let mut pairings = Pairings::default();
    pairings.upsert(record(&b_old, endpoint)).unwrap();
    within(overlay_a.sync_peers(&pairings)).await.unwrap();
    within(overlay_a.sync_peers(&pairings)).await.unwrap();
    pairings.upsert(record(&b_new, endpoint)).unwrap();
    assert_eq!(pairings.peers.len(), 1);
    within(overlay_a.sync_peers(&pairings)).await.expect("a rotated key must sync");
    within(overlay_a.sync_peers(&Pairings::default())).await.unwrap();
}
