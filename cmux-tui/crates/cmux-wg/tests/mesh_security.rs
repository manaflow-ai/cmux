//! The mesh's security invariants: crypto-key routing on receive, silence
//! toward unknown keys, peer removal, and non-overlapping allowed IPs.

mod mesh_support;

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use boringtun::noise::{Tunn, TunnResult};
use cmux_wg::testing::random_keypair;
use cmux_wg::{IpNetwork, WgError, WgPeer};
use mesh_support::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UdpSocket;
use tokio::time::{Instant, timeout, timeout_at};

fn v4(text: &str) -> IpAddr {
    text.parse().expect("literal")
}

#[tokio::test]
async fn a_packet_from_outside_the_peers_allowed_ips_is_dropped() {
    // B owns two addresses, but A routes only B's IPv6 address to B's key.
    let a = node(&[v4("10.77.0.1"), overlay(1)]).await;
    let b = node(&[v4("10.77.0.2"), overlay(2)]).await;
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[v4("10.77.0.1"), overlay(1)], true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());

    // From 10.77.0.2, outside B's allowed IPs on A: A never accepts it.
    let spoofed = timeout(QUIET, b.mesh.connect(SocketAddr::new(v4("10.77.0.1"), LINK_PORT))).await;
    assert!(!matches!(spoofed, Ok(Ok(_))), "a connection from outside B's allowed IPs opened");
    assert!(accepted.try_recv().is_err(), "A accepted a connection from outside B's allowed IPs");

    // From B's routed address the same peer connects at once.
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    let (key, remote) = within(accepted.recv()).await.unwrap();
    assert_eq!(key, b.public);
    assert_eq!(remote.ip(), overlay(2), "the accepted remote is inside the key's allowed IPs");
    echo_round_trip(&mut stream, 4096).await;
    assert!(accepted.try_recv().is_err(), "exactly one connection was accepted");
}

/// A handshake initiation to `responder` from a fresh, unknown key.
fn unknown_initiation(responder: [u8; 32]) -> Vec<u8> {
    let (private, _) = random_keypair();
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
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("no initiation: {other:?}"),
    }
}

#[tokio::test]
async fn an_unknown_initiator_gets_no_handshake_and_peers_still_connect() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());

    let attacker = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let mut buffer = [0u8; 2048];
    for _ in 0..4 {
        attacker.send_to(&unknown_initiation(a.public), a.udp).await.unwrap();
    }
    let answer = timeout(QUIET, attacker.recv_from(&mut buffer)).await;
    assert!(answer.is_err(), "an unknown key got an answer: {answer:?}");

    // A flood of random keys. It must never earn a handshake response. Past
    // the handshake rate limit WireGuard may send a cookie reply (64 bytes,
    // type 3, no state on the responder); nothing else may come back.
    for _ in 0..2000 {
        attacker.send_to(&unknown_initiation(a.public), a.udp).await.unwrap();
    }
    let deadline = Instant::now() + QUIET;
    while let Ok(Ok((len, _))) = timeout_at(deadline, attacker.recv_from(&mut buffer)).await {
        assert_eq!((len, buffer[0]), (64, 3), "only a cookie reply may answer a flood");
    }

    // A configured peer still gets through.
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, b.public);
    echo_round_trip(&mut stream, 4096).await;
}

#[tokio::test]
async fn a_removed_peer_loses_its_streams_and_cannot_handshake() {
    let a = node(&[overlay(1)]).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let mut listener = within(a.mesh.listen(LINK_PORT)).await.unwrap();
    let a_link = SocketAddr::new(overlay(1), LINK_PORT);

    let mut from_b = within(b.mesh.connect(a_link)).await.unwrap();
    let (mut at_a, key) = within(listener.accept()).await.unwrap();
    assert_eq!(key, b.public);
    within(from_b.write_all(b"ping")).await.unwrap();
    let mut ping = [0u8; 4];
    within(at_a.read_exact(&mut ping)).await.unwrap();
    assert_eq!(&ping, b"ping");

    assert!(within(a.mesh.remove_peer(b.public)).await.unwrap());
    assert!(!within(a.mesh.remove_peer(b.public)).await.unwrap(), "already removed");

    // A's end of B's connection fails with an error, not a clean EOF.
    let mut byte = [0u8; 1];
    let read = within(at_a.read(&mut byte)).await;
    assert!(read.is_err(), "a read after removal must fail, got {read:?}");
    let write = within(at_a.write_all(b"x")).await;
    assert!(write.is_err(), "a write after removal must fail");

    // B's old session is dead on A, and a fresh session with B's key cannot
    // complete a handshake.
    let old = timeout(QUIET, b.mesh.connect(a_link)).await;
    assert!(!matches!(old, Ok(Ok(_))), "the removed peer's old session still connects");
    let (private, public) = (b.private, b.public);
    b.mesh.shutdown().await;
    let fresh = node_with_key(&[overlay(2)], private, public).await;
    within(fresh.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let attempt = timeout(QUIET, fresh.mesh.connect(a_link)).await;
    assert!(!matches!(attempt, Ok(Ok(_))), "the removed key completed a handshake");
    assert!(
        timeout(Duration::from_millis(200), listener.accept()).await.is_err(),
        "A accepted a connection from a removed key"
    );

    // Adding the key back restores it, so the refusal was the removal.
    within(a.mesh.add_peer(peer_of(&fresh, &[overlay(2)], false))).await.unwrap();
    let mut again = within(fresh.mesh.connect(a_link)).await.unwrap();
    let (mut at_a, key) = within(listener.accept()).await.unwrap();
    assert_eq!(key, public);
    within(again.write_all(b"back")).await.unwrap();
    let mut back = [0u8; 4];
    within(at_a.read_exact(&mut back)).await.unwrap();
    assert_eq!(&back, b"back");
}

fn key_only_peer(allowed: &[IpNetwork]) -> WgPeer {
    WgPeer {
        public_key: random_keypair().1,
        preshared_key: None,
        allowed_ips: allowed.to_vec(),
        endpoint: None,
        persistent_keepalive: None,
    }
}

fn network(address: IpAddr, prefix: u8) -> IpNetwork {
    IpNetwork::new(address, prefix).expect("network")
}

#[tokio::test]
async fn overlapping_allowed_ips_are_refused() {
    let a = node(&[overlay(1)]).await;
    let b = key_only_peer(&[network(overlay(0), 120)]);
    within(a.mesh.add_peer(b.clone())).await.unwrap();

    for overlapping in [network(overlay(5), 128), network(overlay(0), 64), network(overlay(0), 120)]
    {
        let c = key_only_peer(&[network(overlay(0x200), 128), overlapping]);
        let error = within(a.mesh.add_peer(c)).await.unwrap_err();
        assert!(
            matches!(error, WgError::AllowedIpsOverlap(net) if net == overlapping),
            "{overlapping} must be refused, got {error:?}"
        );
    }

    // A disjoint network is fine, and so is replacing B with its own networks.
    let c = key_only_peer(&[network(overlay(0x200), 128)]);
    within(a.mesh.add_peer(c.clone())).await.unwrap();
    within(a.mesh.add_peer(b.clone())).await.unwrap();

    // Replacing B with a network C holds is refused like any overlap.
    let moved = WgPeer { allowed_ips: vec![network(overlay(0x200), 128)], ..b.clone() };
    let error = within(a.mesh.add_peer(moved)).await.unwrap_err();
    assert!(matches!(error, WgError::AllowedIpsOverlap(_)), "{error:?}");

    // Two networks of one peer may not overlap each other either, and this
    // side's own key is never a peer.
    let twice = key_only_peer(&[network(overlay(0x300), 128), network(overlay(0x300), 120)]);
    assert!(matches!(within(a.mesh.add_peer(twice)).await, Err(WgError::AllowedIpsOverlap(_))));
    let own = WgPeer { public_key: a.public, ..key_only_peer(&[network(overlay(0x400), 128)]) };
    assert!(matches!(within(a.mesh.add_peer(own)).await, Err(WgError::InvalidPeer(_))));
}
