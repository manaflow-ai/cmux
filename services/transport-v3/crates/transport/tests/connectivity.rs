//! Real sockets and libp2p handshakes. Loopback proves protocol composition, not NAT traversal.
use std::time::Duration;

use cmux_v3_authority::{Device, TeamPolicy, DEFAULT_POLICY};
use cmux_v3_grants::{AuthorityKeys, GrantSigner, LeasePolicy, Revocations};
use cmux_v3_transport::{
    authorize_probe, peer, PeerBehaviour, PeerBehaviourEvent, Probe, ProbeReply,
};
use ed25519_dalek::SigningKey;
use futures::StreamExt;
use libp2p::{
    identify, identity, noise, ping, relay, request_response,
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, Multiaddr, PeerId, Swarm, SwarmBuilder,
};

#[derive(NetworkBehaviour)]
struct RelayBehaviour {
    relay: relay::Behaviour,
    identify: identify::Behaviour,
    ping: ping::Behaviour,
}

async fn relay() -> Swarm<RelayBehaviour> {
    SwarmBuilder::with_new_identity()
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )
        .unwrap()
        .with_quic()
        .with_dns()
        .unwrap()
        .with_websocket(noise::Config::new, yamux::Config::default)
        .await
        .unwrap()
        .with_behaviour(|key| RelayBehaviour {
            // Laboratory relay: bound only to loopback, never shipped as a public server.
            relay: relay::Behaviour::new(key.public().to_peer_id(), relay::Config::default()),
            identify: identify::Behaviour::new(identify::Config::new(
                "cmux/transport/3".into(),
                key.public(),
            )),
            ping: ping::Behaviour::default(),
        })
        .unwrap()
        .build()
}

async fn listen(swarm: &mut Swarm<PeerBehaviour>, address: &str) -> Multiaddr {
    swarm.listen_on(address.parse().unwrap()).unwrap();
    loop {
        if let SwarmEvent::NewListenAddr { address, .. } = swarm.select_next_some().await {
            return address;
        }
    }
}

fn authorize(a: PeerId, b: PeerId) -> (AuthorityKeys, String) {
    let devices = [a, b].map(|peer| Device {
        peer,
        owner: "alice".into(),
        tags: vec![],
        active: true,
        lease: LeasePolicy::default(),
    });
    let policy =
        TeamPolicy::new("team".into(), 1, 1000, 1100, devices.into(), DEFAULT_POLICY).unwrap();
    let grant = policy.authorize(a, b, "connect", 1000).unwrap();
    let key = SigningKey::from_bytes(&[24; 32]);
    let mut keys = AuthorityKeys::default();
    keys.insert("test".into(), key.verifying_key());
    let token = GrantSigner::new("test".into(), &key)
        .unwrap()
        .sign(&grant, 1000)
        .unwrap();
    (keys, token)
}

#[allow(clippy::too_many_arguments)]
async fn exchange(
    a: &mut Swarm<PeerBehaviour>,
    b: &mut Swarm<PeerBehaviour>,
    relay: &mut Swarm<RelayBehaviour>,
    keys: &AuthorityKeys,
    token: String,
    now: u64,
    revoked: &Revocations,
) -> ProbeReply {
    let target = *b.local_peer_id();
    a.behaviour_mut().probe.send_request(
        &target,
        Probe {
            grant: token,
            message: "hello from v3".into(),
        },
    );
    loop {
        tokio::select! {
            event = a.select_next_some() => match event {
                SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::Message {
                    message: request_response::Message::Response { response, .. }, ..
                })) => return response,
                SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::OutboundFailure { error, .. })) => panic!("probe failed: {error}"),
                _ => {}
            },
            event = b.select_next_some() => {
                if let SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::Message {
                    peer, message: request_response::Message::Request { request, channel, .. }, ..
                })) = event {
                    let response = authorize_probe(keys, cmux_v3_grants::Scope { team: "team", source: peer, destination: target, action: "connect" }, request, now, revoked);
                    b.behaviour_mut().probe.send_response(channel, response).unwrap();
                }
            },
            _ = relay.select_next_some() => {}
        }
    }
}

async fn scenario(address: &str, relayed: bool) {
    let mut a = peer(identity::Keypair::generate_ed25519()).await.unwrap();
    let mut b = peer(identity::Keypair::generate_ed25519()).await.unwrap();
    let mut r = relay().await;
    let destination = *b.local_peer_id();
    let dial_address = if relayed {
        r.listen_on(address.parse().unwrap()).unwrap();
        let relay_address = loop {
            if let SwarmEvent::NewListenAddr { address, .. } = r.select_next_some().await {
                break address;
            }
        };
        r.add_external_address(relay_address.clone());
        let reservation = relay_address
            .with(libp2p::multiaddr::Protocol::P2p(*r.local_peer_id()))
            .with(libp2p::multiaddr::Protocol::P2pCircuit);
        b.listen_on(reservation.clone()).unwrap();
        loop {
            tokio::select! {
                event = b.select_next_some() => if matches!(event,
                    SwarmEvent::Behaviour(PeerBehaviourEvent::Relay(relay::client::Event::ReservationReqAccepted { .. }))) { break; },
                _ = r.select_next_some() => {}
            }
        }
        reservation.with(libp2p::multiaddr::Protocol::P2p(destination))
    } else {
        listen(&mut b, address)
            .await
            .with(libp2p::multiaddr::Protocol::P2p(destination))
    };
    a.dial(dial_address).unwrap();
    let (keys, token) = authorize(*a.local_peer_id(), destination);
    let mut revoked = Revocations::default();
    let reply = exchange(&mut a, &mut b, &mut r, &keys, token.clone(), 1001, &revoked).await;
    assert_eq!(
        reply,
        ProbeReply::Accepted {
            message: "hello from v3".into()
        }
    );
    assert_eq!(
        exchange(&mut a, &mut b, &mut r, &keys, token.clone(), 1300, &revoked).await,
        ProbeReply::Denied
    );
    revoked.revoke_device("team".into(), *a.local_peer_id());
    assert_eq!(
        exchange(&mut a, &mut b, &mut r, &keys, token, 1002, &revoked).await,
        ProbeReply::Denied
    );
}

#[tokio::test]
async fn direct_quic_checks_authorization_on_existing_connection() {
    tokio::time::timeout(
        Duration::from_secs(20),
        scenario("/ip4/127.0.0.1/udp/0/quic-v1", false),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn websocket_relay_works_without_udp_or_direct_listener() {
    tokio::time::timeout(
        Duration::from_secs(20),
        scenario("/ip4/127.0.0.1/tcp/0/ws", true),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn quic_relay_checks_authorization_on_existing_connection() {
    tokio::time::timeout(
        Duration::from_secs(20),
        scenario("/ip4/127.0.0.1/udp/0/quic-v1", true),
    )
    .await
    .unwrap();
}
