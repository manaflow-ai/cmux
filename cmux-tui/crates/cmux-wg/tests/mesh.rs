//! Several WireGuard peers on one UDP socket: routing, accept keys, echo.

mod mesh_support;

use std::net::SocketAddr;

use cmux_wg::WgError;
use mesh_support::*;

const MIB: usize = 1024 * 1024;

#[tokio::test]
async fn one_socket_serves_two_peers_in_both_directions() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    let c = node(&[overlay(3)]).await;
    // A knows neither endpoint: it learns each from the peer's first
    // authenticated datagram.
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(a.mesh.add_peer(peer_of(&c, &[overlay(3)], false))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    within(c.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();

    let (_echo_a, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let a_link = SocketAddr::new(overlay(1), LINK_PORT);

    let mut from_b = within(b.mesh.connect(a_link)).await.unwrap();
    let (key, remote) = within(accepted.recv()).await.unwrap();
    assert_eq!(key, b.public, "A accepts B's connection with B's key");
    assert_eq!(remote.ip(), overlay(2));
    assert_eq!(from_b.peer_addr(), a_link);

    let mut from_c = within(c.mesh.connect(a_link)).await.unwrap();
    let (key, remote) = within(accepted.recv()).await.unwrap();
    assert_eq!(key, c.public, "A accepts C's connection with C's key");
    assert_eq!(remote.ip(), overlay(3));

    echo_round_trip(&mut from_b, MIB).await;
    echo_round_trip(&mut from_c, MIB).await;

    // A now dials both peers at the endpoints it learned.
    let (_echo_b, mut accepted_b) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let (_echo_c, mut accepted_c) = spawn_echo(within(c.mesh.listen(LINK_PORT)).await.unwrap());
    let mut to_b = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    let mut to_c = within(a.mesh.connect(SocketAddr::new(overlay(3), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted_b.recv()).await.unwrap().0, a.public);
    assert_eq!(within(accepted_c.recv()).await.unwrap().0, a.public);
    echo_round_trip(&mut to_b, MIB).await;
    echo_round_trip(&mut to_c, MIB).await;

    // The first connections are still intact after the others ran.
    echo_round_trip(&mut from_b, 64 * 1024).await;
    echo_round_trip(&mut from_c, 64 * 1024).await;

    a.mesh.shutdown().await;
}

#[tokio::test]
async fn an_address_no_peer_routes_is_no_route() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], true))).await.unwrap();

    let error = within(a.mesh.connect(SocketAddr::new(overlay(9), LINK_PORT))).await.unwrap_err();
    assert!(matches!(error, WgError::NoRoute(address) if address == overlay(9)), "{error:?}");

    // The routed peer is reachable, so the refusal is about the route.
    let (_echo, _accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut stream, 1024).await;
}

#[tokio::test]
async fn a_peer_that_restarts_on_a_new_port_is_learned_again() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let a_link = SocketAddr::new(overlay(1), LINK_PORT);

    let mut first = within(b.mesh.connect(a_link)).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, b.public);
    echo_round_trip(&mut first, 1024).await;

    // B comes back with the same key on a new UDP port; A moves its
    // endpoint on B's first authenticated datagram and can dial B there.
    let (private, public) = (b.private, b.public);
    drop(first);
    b.mesh.shutdown().await;
    let b2 = node_with_key(&[overlay(2)], private, public).await;
    within(b2.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let mut second = within(b2.mesh.connect(a_link)).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, public);
    echo_round_trip(&mut second, 1024).await;

    let (_echo_b2, _accepted_b2) = spawn_echo(within(b2.mesh.listen(LINK_PORT)).await.unwrap());
    let mut back = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut back, 1024).await;
}
