//! A mesh that moved to a new key and still answers its retired key, only
//! for the peers it put on it (`WgMesh::start_retiring`).

mod mesh_support;

use std::net::{IpAddr, SocketAddr};

use cmux_wg::testing::random_keypair;
use cmux_wg::{InterfaceAddress, WgMesh, WgMeshConfig, WgPeer};
use mesh_support::*;
use tokio::net::UdpSocket;
use tokio::time::timeout;
use zeroize::Zeroizing;

/// A node that moved from `retired` to a fresh key.
async fn retiring(address: IpAddr, retired: [u8; 32]) -> Node {
    let (private, public) = random_keypair();
    let socket = UdpSocket::bind("127.0.0.1:0").await.expect("bind");
    let config = WgMeshConfig {
        private_key: Zeroizing::new(private),
        addresses: vec![InterfaceAddress { address, prefix: 128 }],
        mtu: 1380,
    };
    let mesh = WgMesh::start_retiring(config, Zeroizing::new(retired), socket).expect("start");
    let udp = mesh.local_addr().expect("local addr");
    Node { mesh, public, udp, addresses: vec![address], private }
}

/// `node` known by another key (`public`), as a peer that has not heard of its new one.
fn known_as(node: &Node, public: [u8; 32], endpoint: bool) -> WgPeer {
    WgPeer { public_key: public, ..peer_of(node, &node.addresses, endpoint) }
}

#[tokio::test]
async fn a_peer_on_the_retired_key_reaches_the_mesh_and_no_other_peer_does() {
    let (old_private, old_public) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = node(&[overlay(2)]).await;
    let c = node(&[overlay(3)]).await;
    // B and C still know A by its retired key; A keeps only B on it.
    within(a.mesh.add_peer_on_retired_key(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(a.mesh.add_peer(peer_of(&c, &[overlay(3)], false))).await.unwrap();
    within(b.mesh.add_peer(known_as(&a, old_public, true))).await.unwrap();
    within(c.mesh.add_peer(known_as(&a, old_public, true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());

    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, b.public);
    echo_round_trip(&mut stream, 4096).await;

    let refused = timeout(QUIET, c.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await;
    assert!(!matches!(refused, Ok(Ok(_))), "a peer on the current key reached the retired one");
    assert!(accepted.try_recv().is_err());
}

#[tokio::test]
async fn a_peer_moved_to_the_current_key_no_longer_reaches_the_retired_one() {
    let (old_private, old_public) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer_on_retired_key(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(known_as(&a, old_public, true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut stream, 512).await;
    within(accepted.recv()).await.unwrap();

    // A moves B to its current key; B, still on the retired one, is shut out.
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.remove_peer(old_public)).await.unwrap();
    within(b.mesh.add_peer(known_as(&a, old_public, true))).await.unwrap();
    let refused = timeout(QUIET, b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await;
    assert!(!matches!(refused, Ok(Ok(_))), "the retired key answered a peer moved off it");

    // Told the current key, B reaches A again.
    within(b.mesh.remove_peer(old_public)).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut stream, 512).await;
}

/// Both sides moved at once: each keeps the other on its retired key, and
/// they still meet on the keys they both know.
#[tokio::test]
async fn two_meshes_that_both_moved_meet_on_their_retired_keys() {
    let (a_old, a_old_public) = random_keypair();
    let (b_old, b_old_public) = random_keypair();
    let a = retiring(overlay(1), a_old).await;
    let b = retiring(overlay(2), b_old).await;
    within(a.mesh.add_peer_on_retired_key(known_as(&b, b_old_public, true))).await.unwrap();
    within(b.mesh.add_peer_on_retired_key(known_as(&a, a_old_public, true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, b_old_public);
    echo_round_trip(&mut stream, 4096).await;
}

#[tokio::test]
async fn a_mesh_without_a_retired_key_refuses_a_peer_on_one() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    let refused = within(a.mesh.add_peer_on_retired_key(peer_of(&b, &[overlay(2)], false))).await;
    assert!(refused.is_err());
}

#[tokio::test]
async fn a_mesh_refuses_its_own_retired_key_as_a_peer() {
    let (old_private, old_public) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = node(&[overlay(2)]).await;
    let refused = within(a.mesh.add_peer(known_as(&b, old_public, false))).await;
    assert!(refused.is_err());
}
