//! A mesh that moved to a new key and still answers its retired key, only
//! for the peers it put on it (`WgMesh::start_retiring`).

mod mesh_support;

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use boringtun::noise::handshake::parse_handshake_anon;
use boringtun::noise::rate_limiter::RateLimiter;
use boringtun::noise::{Packet, Tunn, TunnResult};
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

/// A peer kept on the retired key that already knows the current key (it
/// took it, the answer saying so was lost) reaches the mesh on it.
#[tokio::test]
async fn a_peer_on_the_retired_key_that_knows_the_current_one_moves_to_it() {
    let (old_private, _) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer_on_retired_key(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    let (_echo, mut accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    assert_eq!(within(accepted.recv()).await.unwrap().0, b.public);
    echo_round_trip(&mut stream, 4096).await;
}

/// A handshake initiation from `private` to `responder`, from a fresh session.
fn initiation(private: [u8; 32], responder: [u8; 32]) -> Vec<u8> {
    let mut tunn = Tunn::new(
        x25519_dalek::StaticSecret::from(private),
        x25519_dalek::PublicKey::from(responder),
        None,
        None,
        7,
        None,
    );
    let mut buffer = [0u8; 256];
    match tunn.format_handshake_initiation(&mut buffer, false) {
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("no initiation: {other:?}"),
    }
}

/// A handshake message's MAC1 (WireGuard: keyed BLAKE2s of the message up
/// to its two MACs, by the hash of "mac1----" and the receiver's key), which
/// anyone may compute; MAC2 is left empty.
fn seal_mac1(message: &mut [u8], responder: [u8; 32]) {
    use blake2::digest::consts::U16;
    use blake2::digest::{Digest, KeyInit, Mac};
    let key =
        blake2::Blake2s256::new().chain_update(b"mac1----").chain_update(responder).finalize();
    let mut mac = <blake2::Blake2sMac<U16> as KeyInit>::new_from_slice(&key).expect("key");
    let body = message.len() - 32;
    Mac::update(&mut mac, &message[..body]);
    message[body..body + 16].copy_from_slice(&mac.finalize().into_bytes());
    message[body + 16..].fill(0);
}

/// Whether `socket` gets any datagram within `wait`.
async fn answered(socket: &UdpSocket, wait: Duration) -> bool {
    let mut buffer = [0u8; 256];
    timeout(wait, socket.recv_from(&mut buffer)).await.is_ok()
}

/// An initiation to the current key that names a peer on the retired key,
/// with a valid MAC1 but a timestamp it did not seal, moves nothing: the
/// peer's session on the retired key keeps carrying its stream.
#[tokio::test]
async fn a_forged_initiation_to_the_current_key_leaves_the_retired_session_alone() {
    let (old_private, old_public) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer_on_retired_key(peer_of(&b, &[overlay(2)], false))).await.unwrap();
    within(b.mesh.add_peer(known_as(&a, old_public, true))).await.unwrap();
    let (_echo, _accepted) = spawn_echo(within(a.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(b.mesh.connect(SocketAddr::new(overlay(1), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut stream, 512).await;

    // B's static key, sealed right; the timestamp's ciphertext is not.
    let mut forged = initiation(b.private, a.public);
    forged[90] ^= 0x01;
    seal_mac1(&mut forged, a.public);
    let attacker = UdpSocket::bind("127.0.0.1:0").await.expect("bind");
    attacker.send_to(&forged, a.udp).await.expect("send");
    assert!(!answered(&attacker, QUIET).await, "a forged initiation was answered");
    echo_round_trip(&mut stream, 4096).await;
}

/// An initiation to the current key seen once is answered and moves the
/// peer; the same one again is not answered (its timestamp is no newer),
/// and a newer one is.
#[tokio::test]
async fn a_replayed_initiation_to_the_current_key_is_not_answered() {
    let (old_private, _) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let (b_private, b_public) = random_keypair();
    let b = WgPeer {
        public_key: b_public,
        preshared_key: None,
        allowed_ips: vec![host(overlay(2))],
        route: None,
        candidates: Vec::new(),
        persistent_keepalive: None,
    };
    within(a.mesh.add_peer_on_retired_key(b)).await.unwrap();
    let socket = UdpSocket::bind("127.0.0.1:0").await.expect("bind");
    let first = initiation(b_private, a.public);
    socket.send_to(&first, a.udp).await.expect("send");
    assert!(answered(&socket, TIMEOUT).await, "an authentic initiation was not answered");
    socket.send_to(&first, a.udp).await.expect("send");
    assert!(!answered(&socket, QUIET).await, "a replayed initiation was answered");
    tokio::time::sleep(Duration::from_millis(100)).await;
    socket.send_to(&initiation(b_private, a.public), a.udp).await.expect("send");
    assert!(answered(&socket, TIMEOUT).await, "a newer initiation was not answered");
}

/// A probe from the current key to a peer that only knows the retired one
/// goes unanswered, and the retired session keeps carrying its stream the
/// whole time; to a peer that knows the current key, it moves the session.
#[tokio::test]
async fn a_probe_of_the_current_key_never_interrupts_the_retired_session() {
    let (old_private, old_public) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = node(&[overlay(2)]).await;
    within(a.mesh.add_peer_on_retired_key(peer_of(&b, &[overlay(2)], true))).await.unwrap();
    within(b.mesh.add_peer(known_as(&a, old_public, true))).await.unwrap();
    let (_echo, _accepted) = spawn_echo(within(b.mesh.listen(LINK_PORT)).await.unwrap());
    let mut stream = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut stream, 512).await;
    for _ in 0..3 {
        let probed = timeout(Duration::from_millis(700), a.mesh.probe_current(b.public)).await;
        assert!(!matches!(probed, Ok(Ok(true))), "a peer that does not know the key answered");
        echo_round_trip(&mut stream, 4096).await;
    }

    // B learns A's current key: the next probe is answered.
    within(b.mesh.remove_peer(old_public)).await.unwrap();
    within(b.mesh.add_peer(peer_of(&a, &[overlay(1)], true))).await.unwrap();
    assert!(within(a.mesh.probe_current(b.public)).await.unwrap());
    let mut fresh = within(a.mesh.connect(SocketAddr::new(overlay(2), LINK_PORT))).await.unwrap();
    echo_round_trip(&mut fresh, 512).await;
}

/// A handshake response to the current key naming a peer on the retired key,
/// with a valid MAC1 and nothing else: past the current session's handshake
/// rate, it is answered with a cookie challenge, which checked only that
/// MAC1. The challenge goes to the sender; the peer stays on its retired
/// session and is not moved to the current key.
#[tokio::test]
async fn a_cookie_challenge_to_a_forged_response_never_moves_the_peer() {
    let (old_private, old_public) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let (b_private, b_public) = random_keypair();
    let b = WgPeer {
        public_key: b_public,
        preshared_key: None,
        allowed_ips: vec![host(overlay(2))],
        route: None,
        candidates: Vec::new(),
        persistent_keepalive: None,
    };
    within(a.mesh.add_peer_on_retired_key(b)).await.unwrap();

    // B's session on the retired key; A's answer names the index A gave B.
    let socket = UdpSocket::bind("127.0.0.1:0").await.expect("bind");
    let mut tunn = Tunn::new(
        x25519_dalek::StaticSecret::from(b_private),
        x25519_dalek::PublicKey::from(old_public),
        None,
        None,
        7,
        None,
    );
    let mut scratch = [0u8; 256];
    let TunnResult::WriteToNetwork(first) = tunn.format_handshake_initiation(&mut scratch, false)
    else {
        panic!("no initiation");
    };
    socket.send_to(first, a.udp).await.expect("send");
    let mut buffer = [0u8; 256];
    let (length, _) = within(socket.recv_from(&mut buffer)).await.expect("response");
    let response = buffer.get(..length).expect("response").to_vec();
    assert_eq!(response.first(), Some(&2), "A did not answer with a response");
    let receiver: [u8; 4] =
        response.get(4..8).and_then(|bytes| bytes.try_into().ok()).expect("index");
    if let TunnResult::WriteToNetwork(keepalive) =
        tunn.decapsulate(Some(a.udp.ip()), &response, &mut scratch)
    {
        socket.send_to(keepalive, a.udp).await.expect("send");
    }

    // Responses to A's current key from another address: MAC1 right, the
    // rest garbage, until the current session's rate limiter challenges one.
    let attacker = UdpSocket::bind("127.0.0.1:0").await.expect("bind");
    let mut forged = [0u8; 92];
    forged[0] = 2;
    forged[4..8].copy_from_slice(&[1, 2, 3, 4]);
    forged[8..12].copy_from_slice(&receiver);
    forged[12..60].fill(0x5a);
    seal_mac1(&mut forged, a.public);
    let mut challenged = false;
    for _ in 0..32 {
        attacker.send_to(&forged, a.udp).await.expect("send");
        let mut reply = [0u8; 256];
        if let Ok(Ok((length, _))) =
            timeout(Duration::from_millis(100), attacker.recv_from(&mut reply)).await
        {
            assert_eq!(
                (reply.first(), length),
                (Some(&3), 64),
                "a forged response got more than a cookie"
            );
            challenged = true;
            break;
        }
    }
    assert!(challenged, "no forged response was challenged");

    // Still on the retired key: a probe of the current key is not answered at
    // once (it is for a peer already there) and goes unanswered.
    let probed = timeout(QUIET, a.mesh.probe_current(b_public)).await;
    assert!(
        !matches!(probed, Ok(Ok(true))),
        "a cookie challenge moved the peer to the current key"
    );
}

/// A peer with no mesh of its own: a socket and a key, answering by hand.
struct Bare {
    socket: UdpSocket,
    private: [u8; 32],
    public: [u8; 32],
}

impl Bare {
    async fn bind() -> Self {
        let (private, public) = random_keypair();
        let socket = UdpSocket::bind("127.0.0.1:0").await.expect("bind");
        Self { socket, private, public }
    }

    /// It, as a peer at overlay address 2, at its socket.
    fn peer(&self) -> WgPeer {
        WgPeer {
            public_key: self.public,
            preshared_key: None,
            allowed_ips: vec![host(overlay(2))],
            route: Some(self.socket.local_addr().expect("local addr").into()),
            candidates: Vec::new(),
            persistent_keepalive: None,
        }
    }

    /// The next handshake initiation from the key `from`, and where it came
    /// from. Initiations from another key (the mesh's retired one) are skipped.
    async fn initiation_from(&self, from: [u8; 32]) -> (Vec<u8>, SocketAddr) {
        let private = x25519_dalek::StaticSecret::from(self.private);
        let public = x25519_dalek::PublicKey::from(self.public);
        let mut buffer = [0u8; 256];
        loop {
            let (length, source) = self.socket.recv_from(&mut buffer).await.expect("recv");
            let datagram = buffer.get(..length).expect("datagram");
            if let Ok(Packet::HandshakeInit(initiation)) = Tunn::parse_incoming_packet(datagram)
                && parse_handshake_anon(&private, &public, &initiation)
                    .is_ok_and(|half| half.peer_static_public == from)
            {
                return (datagram.to_vec(), source);
            }
        }
    }

    /// A session with `responder`, its handshakes checked by `limiter` when given.
    fn session(&self, responder: [u8; 32], limiter: Option<Arc<RateLimiter>>) -> Tunn {
        Tunn::new(
            x25519_dalek::StaticSecret::from(self.private),
            x25519_dalek::PublicKey::from(responder),
            None,
            None,
            9,
            limiter,
        )
    }
}

/// A probe of the current key whose initiation is lost is sent again by the
/// current session's own timers, and the peer's answer to that one moves the
/// peer there: one probe, and the peer never starts a handshake of its own.
#[tokio::test]
async fn a_probe_whose_initiation_was_lost_is_sent_again_until_answered() {
    let (old_private, _) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = Bare::bind().await;
    within(a.mesh.add_peer_on_retired_key(b.peer())).await.unwrap();
    let peer = async {
        let (lost, _) = b.initiation_from(a.public).await;
        let (again, from) = b.initiation_from(a.public).await;
        assert_ne!(lost, again, "the same initiation twice");
        let mut session = b.session(a.public, None);
        let mut scratch = [0u8; 256];
        let TunnResult::WriteToNetwork(response) =
            session.decapsulate(Some(from.ip()), &again, &mut scratch)
        else {
            panic!("the initiation sent again was not answered");
        };
        b.socket.send_to(response, from).await.expect("send");
    };
    let probe = async { tokio::join!(a.mesh.probe_current(b.public), peer).0 };
    let probed =
        timeout(Duration::from_secs(20), probe).await.expect("the lost probe was never sent again");
    assert!(probed.unwrap(), "the answered probe did not move the peer");
}

/// A peer under load challenges a probe of the current key with a cookie:
/// the current session takes the cookie (not the peer's session on the
/// retired key), and its next initiation, which carries it, is answered.
#[tokio::test]
async fn a_cookie_challenge_to_a_probe_reaches_the_current_session() {
    let (old_private, _) = random_keypair();
    let a = retiring(overlay(1), old_private).await;
    let b = Bare::bind().await;
    within(a.mesh.add_peer_on_retired_key(b.peer())).await.unwrap();
    let peer = async {
        // Always under load: an initiation without this side's cookie is challenged.
        let limiter = Arc::new(RateLimiter::new(&x25519_dalek::PublicKey::from(b.public), 0));
        let mut session = b.session(a.public, Some(limiter));
        let mut scratch = [0u8; 256];
        let mut challenged = 0;
        loop {
            let (initiation, from) = b.initiation_from(a.public).await;
            match session.decapsulate(Some(from.ip()), &initiation, &mut scratch) {
                TunnResult::WriteToNetwork(reply) if reply.first() == Some(&3) => {
                    challenged += 1;
                    b.socket.send_to(reply, from).await.expect("send");
                }
                TunnResult::WriteToNetwork(response) => {
                    b.socket.send_to(response, from).await.expect("send");
                    return challenged;
                }
                _ => {}
            }
        }
    };
    let probe = async { tokio::join!(a.mesh.probe_current(b.public), peer) };
    let (probed, challenged) = timeout(Duration::from_secs(20), probe)
        .await
        .expect("the challenged probe never carried its cookie");
    assert!(challenged >= 1, "the probe was never challenged");
    assert!(probed.unwrap(), "the answered probe did not move the peer");
}
