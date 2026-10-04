//! Unit tests of the mesh driver's receive path.

use boringtun::noise::{Tunn, TunnResult};
use ip_network::IpNetwork;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

use super::*;
use crate::testing::random_keypair;

fn initiation(private: [u8; 32], responder: &PublicKey) -> Vec<u8> {
    let mut tunn = Tunn::new(StaticSecret::from(private), *responder, None, None, 0, None);
    let mut buffer = [0u8; 256];
    match tunn.format_handshake_initiation(&mut buffer, false) {
        TunnResult::WriteToNetwork(packet) => packet.to_vec(),
        other => panic!("no initiation: {other:?}"),
    }
}

#[tokio::test]
async fn a_flood_of_unknown_initiators_leaves_no_state() {
    let (private, _) = random_keypair();
    let config = WgMeshConfig {
        private_key: Zeroizing::new(private),
        addresses: vec![InterfaceAddress { address: "fd7c:6d78::1".parse().unwrap(), prefix: 128 }],
        mtu: 1380,
    };
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let (_commands, receiver) = mpsc::channel(1);
    let mut driver = MeshDriver::new(config, socket, receiver).unwrap();
    let (_, known) = random_keypair();
    let allowed = IpNetwork::new("fd7c:6d78::2".parse::<IpAddr>().unwrap(), 128).unwrap();
    let peer = WgPeer {
        public_key: known,
        preshared_key: None,
        allowed_ips: vec![allowed],
        endpoint: None,
        persistent_keepalive: None,
    };
    driver.add_peer(peer).unwrap();
    let responder = *driver.table.public();

    let attacker = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let source = Some(attacker.local_addr().unwrap());
    for _ in 0..3 * HANDSHAKES_PER_SECOND {
        let (stranger, _) = random_keypair();
        driver.handle_datagram(&initiation(stranger, &responder), source);
    }

    assert_eq!(driver.table.len(), 1, "no peer was created");
    assert_eq!(driver.table.index_count(), 1, "no session index was created");
    let peer = driver.table.get_mut(&known).unwrap();
    assert_eq!(peer.endpoint, None, "a stranger's datagram moved a peer");
    assert_eq!(peer.tunn.time_since_last_handshake(), None);
    assert_eq!(driver.stack.sockets.iter().count(), 0);
    assert!(driver.stack.syn_origins.as_ref().unwrap().is_empty());
}
