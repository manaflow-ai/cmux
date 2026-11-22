//! Mesh peers reached through a gateway tunnel: WireGuard inside the
//! datagram service of a real `WgNet` tunnel (transport.md 3.1 and 12a).

mod mesh_gateway_support;
mod mesh_support;

use std::net::{IpAddr, SocketAddr};

use boringtun::noise::{Tunn, TunnResult};
use cmux_wg::testing::random_keypair;
use cmux_wg::{PeerRoute, Priority, WgError, WgPeer};
use mesh_gateway_support::*;
use mesh_support::*;
use tokio::time::timeout;

const MIB: usize = 1024 * 1024;

async fn nested(addresses: &[IpAddr]) -> Node {
    let (private, public) = random_keypair();
    node_with_mtu(addresses, private, public, NESTED_MTU).await
}

fn v4(text: &str) -> IpAddr {
    text.parse().expect("literal")
}

/// `node` as a peer reached at `route`.
fn routed(node: &Node, allowed: &[IpAddr], route: Option<PeerRoute>) -> WgPeer {
    WgPeer { route, ..peer_of(node, allowed, false) }
}

#[tokio::test]
async fn a_peer_reached_only_through_a_gateway_echoes_a_mebibyte() {
    let tunnel = tunnel(TUNNEL_MTU).await;
    let a = nested(&[overlay(1)]).await;
    let b = nested(&[overlay(2)]).await;
    let forwarder =
        forwarder(tunnel.vpc_socket().await, tunnel.client_target(), a.udp, b.udp, Toward::Gateway)
            .await;
    let gateway = within(a.mesh.add_gateway(tunnel.gateway_socket().await)).await.unwrap();
    let route = PeerRoute::Gateway { gateway, address: tunnel.vpc() };
    within(a.mesh.add_peer(routed(&b, &[overlay(2)], Some(route)))).await.unwrap();
    // B learns A at the gateway's VPC side, as a VM does.
    within(b.mesh.add_peer(routed(&a, &[overlay(1)], None))).await.unwrap();

    let (_echo, mut accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    let (key, remote) = within(accepted.recv()).await.unwrap();
    assert_eq!(key, a.public, "B accepts the connection with A's key");
    assert_eq!(remote.ip(), overlay(1));
    echo_round_trip(&mut stream, MIB).await;

    assert_eq!(within(a.mesh.peer_route(b.public)).await.unwrap(), Some(route));
    assert_eq!(
        within(b.mesh.peer_route(a.public)).await.unwrap(),
        Some(PeerRoute::Udp(forwarder.relay)),
        "B reaches A at the gateway's VPC side"
    );
    assert_eq!(within(a.mesh.peer_route(random_keypair().1)).await.unwrap(), None);
}

#[tokio::test]
async fn a_peer_roams_between_udp_and_a_gateway_and_the_connection_survives() {
    let tunnel = tunnel(TUNNEL_MTU).await;
    let a = nested(&[overlay(1)]).await;
    let b = nested(&[overlay(2)]).await;
    let forwarder =
        forwarder(tunnel.vpc_socket().await, tunnel.client_target(), a.udp, b.udp, Toward::Direct)
            .await;
    let gateway = within(a.mesh.add_gateway(tunnel.gateway_socket().await)).await.unwrap();
    let direct = PeerRoute::Udp(forwarder.relay);
    let through = PeerRoute::Gateway { gateway, address: tunnel.vpc() };
    within(a.mesh.add_peer(routed(&b, &[overlay(2)], Some(direct)))).await.unwrap();
    within(b.mesh.add_peer(routed(&a, &[overlay(1)], None))).await.unwrap();

    let (_echo, mut accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, a.public);
    echo_round_trip(&mut stream, 64 * 1024).await;
    assert_eq!(within(a.mesh.peer_route(b.public)).await.unwrap(), Some(direct));

    // B's datagrams now arrive through the gateway: A's route follows them.
    forwarder.set(Toward::Gateway);
    echo_round_trip(&mut stream, 256 * 1024).await;
    assert_eq!(within(a.mesh.peer_route(b.public)).await.unwrap(), Some(through));
    echo_round_trip(&mut stream, 64 * 1024).await;

    // And back to UDP, on the same connection and session.
    forwarder.set(Toward::Direct);
    echo_round_trip(&mut stream, 256 * 1024).await;
    assert_eq!(within(a.mesh.peer_route(b.public)).await.unwrap(), Some(direct));
    echo_round_trip(&mut stream, 64 * 1024).await;
    assert!(accepted.try_recv().is_err(), "roaming opened no new connection");
}

/// A handshake initiation to `responder` from a fresh key, and that key.
fn unknown_initiation(responder: [u8; 32]) -> (Vec<u8>, [u8; 32]) {
    let (private, public) = random_keypair();
    let mut tunn = Tunn::new(
        x25519_dalek::StaticSecret::from(private),
        x25519_dalek::PublicKey::from(responder),
        None,
        None,
        0,
        None,
    );
    let mut buffer = [0u8; 256];
    match tunn.format_handshake_initiation(&mut buffer, false) {
        TunnResult::WriteToNetwork(packet) => (packet.to_vec(), public),
        other => panic!("no initiation: {other:?}"),
    }
}

#[tokio::test]
async fn an_unknown_key_through_a_gateway_gets_no_answer_and_no_state() {
    let tunnel = tunnel(TUNNEL_MTU).await;
    let a = nested(&[overlay(1)]).await;
    let b = nested(&[overlay(2)]).await;
    let gateway = within(a.mesh.add_gateway(tunnel.gateway_socket().await)).await.unwrap();
    within(a.mesh.add_peer(routed(&b, &[overlay(2)], None))).await.unwrap();

    let mut vpc = tunnel.vpc_socket().await;
    let mut strangers = Vec::new();
    for _ in 0..4 {
        let (initiation, stranger) = unknown_initiation(a.public);
        strangers.push(stranger);
        within(vpc.send_to(&initiation, tunnel.client_target(), Priority::Interactive))
            .await
            .unwrap();
    }
    let answer = timeout(QUIET, vpc.recv_from()).await;
    assert!(answer.is_err(), "an unknown key got an answer through the gateway: {answer:?}");
    for stranger in strangers {
        assert_eq!(within(a.mesh.peer_route(stranger)).await.unwrap(), None);
    }
    assert_eq!(within(a.mesh.peer_route(b.public)).await.unwrap(), None, "B did not move");

    // The configured peer still connects through the same gateway.
    let forwarder = forwarder(vpc, tunnel.client_target(), a.udp, b.udp, Toward::Gateway).await;
    let relay = forwarder.relay;
    within(b.mesh.add_peer(routed(&a, &[overlay(1)], Some(PeerRoute::Udp(relay))))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, b.public);
    echo_round_trip(&mut stream, 4096).await;
    assert_eq!(
        within(a.mesh.peer_route(b.public)).await.unwrap(),
        Some(PeerRoute::Gateway { gateway, address: tunnel.vpc() }),
        "A learned B's route from its first authenticated gateway datagram"
    );
}

#[tokio::test]
async fn a_packet_from_outside_allowed_ips_through_a_gateway_is_dropped() {
    let tunnel = tunnel(TUNNEL_MTU).await;
    // B owns two addresses, but A routes only B's IPv6 address to B's key.
    let a = nested(&[v4("10.77.0.1"), overlay(1)]).await;
    let b = nested(&[v4("10.77.0.2"), overlay(2)]).await;
    let forwarder =
        forwarder(tunnel.vpc_socket().await, tunnel.client_target(), a.udp, b.udp, Toward::Gateway)
            .await;
    within(a.mesh.add_gateway(tunnel.gateway_socket().await)).await.unwrap();
    within(a.mesh.add_peer(routed(&b, &[overlay(2)], None))).await.unwrap();
    let to_a = Some(PeerRoute::Udp(forwarder.relay));
    within(b.mesh.add_peer(routed(&a, &[v4("10.77.0.1"), overlay(1)], to_a))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());

    let spoofed = timeout(QUIET, b.mesh.connect(SocketAddr::new(v4("10.77.0.1"), LINK_PORT))).await;
    assert!(!matches!(spoofed, Ok(Ok(_))), "a connection from outside B's allowed IPs opened");
    assert!(accepted.try_recv().is_err(), "A accepted a connection from outside B's allowed IPs");

    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    let (key, remote) = within(accepted.recv()).await.unwrap();
    assert_eq!(key, b.public);
    assert_eq!(remote.ip(), overlay(2), "the accepted remote is inside the key's allowed IPs");
    echo_round_trip(&mut stream, 4096).await;
    assert!(
        matches!(
            within(a.mesh.peer_route(b.public)).await.unwrap(),
            Some(PeerRoute::Gateway { .. })
        ),
        "the session ran through the gateway"
    );
}

#[tokio::test]
async fn removing_a_gateway_leaves_its_peers_without_a_route() {
    let tunnel = tunnel(TUNNEL_MTU).await;
    let a = nested(&[overlay(1)]).await;
    let b = nested(&[overlay(2)]).await;
    let _forwarder =
        forwarder(tunnel.vpc_socket().await, tunnel.client_target(), a.udp, b.udp, Toward::Gateway)
            .await;
    let gateway = within(a.mesh.add_gateway(tunnel.gateway_socket().await)).await.unwrap();
    let route = PeerRoute::Gateway { gateway, address: tunnel.vpc() };
    within(a.mesh.add_peer(routed(&b, &[overlay(2)], Some(route)))).await.unwrap();
    within(b.mesh.add_peer(routed(&a, &[overlay(1)], None))).await.unwrap();
    let (_echo, _accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let link = SocketAddr::new(overlay(2), LINK_PORT);
    let mut stream = within(a.mesh.connect(link)).await.unwrap();
    echo_round_trip(&mut stream, 4096).await;

    assert!(within(a.mesh.remove_gateway(gateway)).await.unwrap());
    assert!(!within(a.mesh.remove_gateway(gateway)).await.unwrap(), "removed once");
    assert_eq!(within(a.mesh.peer_route(b.public)).await.unwrap(), None);
    // No route: a new connection cannot complete; the caller's deadline ends it.
    let attempt = timeout(QUIET, a.mesh.connect(link)).await;
    assert!(!matches!(attempt, Ok(Ok(_))), "a connection opened without a route: {attempt:?}");

    // A new gateway on the same tunnel gets a new id and carries the peer again.
    let again = within(a.mesh.add_gateway(tunnel.gateway_socket().await)).await.unwrap();
    assert_ne!(again, gateway);
    let route = PeerRoute::Gateway { gateway: again, address: tunnel.vpc() };
    within(a.mesh.add_peer(routed(&b, &[overlay(2)], Some(route)))).await.unwrap();
    let mut fresh = within(a.mesh.connect(link)).await.unwrap();
    echo_round_trip(&mut fresh, 4096).await;
}

#[tokio::test]
async fn a_gateway_that_cannot_carry_the_mesh_mtu_is_refused() {
    // A 1200 tunnel carries 1152-byte datagrams; a 1200 mesh needs 1232.
    let small = tunnel(NESTED_MTU).await;
    let a = nested(&[overlay(1)]).await;
    let refused = within(a.mesh.add_gateway(small.gateway_socket().await)).await;
    assert!(
        matches!(refused, Err(WgError::DatagramTooLarge { len: 1232, max: 1152 })),
        "{refused:?}"
    );
    let fits = tunnel(TUNNEL_MTU).await;
    within(a.mesh.add_gateway(fits.gateway_socket().await)).await.unwrap();
}
