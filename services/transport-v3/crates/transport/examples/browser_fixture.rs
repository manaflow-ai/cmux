//! Loopback-only fixture for a real browser-to-Rust Circuit Relay v2 test.
//! Ephemeral lab identities and enrollment; never deploy this as an authorization service.
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_v3_authority::{Device, TeamPolicy, DEFAULT_POLICY};
use cmux_v3_grants::{AuthorityKeys, GrantSigner, LeasePolicy, Revocations};
use cmux_v3_transport::{authorize_probe, peer, PeerBehaviourEvent};
use ed25519_dalek::SigningKey;
use futures::StreamExt;
use libp2p::{
    allow_block_list, identify, identity,
    multiaddr::Protocol,
    noise, relay, request_response,
    swarm::{NetworkBehaviour, SwarmEvent},
    tcp, yamux, PeerId, SwarmBuilder,
};

#[derive(NetworkBehaviour)]
struct Relay {
    allow: allow_block_list::Behaviour<allow_block_list::AllowedPeers>,
    relay: relay::Behaviour,
    identify: identify::Behaviour,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let browser: PeerId = std::env::args()
        .nth(1)
        .ok_or_else(|| anyhow::anyhow!("missing browser peer"))?
        .parse()?;
    let mut host = peer(identity::Keypair::generate_ed25519()).await?;
    let destination = *host.local_peer_id();
    let mut relay = SwarmBuilder::with_new_identity()
        .with_tokio()
        .with_tcp(
            tcp::Config::default(),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_websocket(noise::Config::new, yamux::Config::default)
        .await?
        .with_behaviour(|key| {
            let mut allow = allow_block_list::Behaviour::default();
            allow.allow_peer(browser);
            allow.allow_peer(destination);
            Relay {
                allow,
                relay: relay::Behaviour::new(key.public().to_peer_id(), relay::Config::default()),
                identify: identify::Behaviour::new(identify::Config::new(
                    "cmux/transport/3".into(),
                    key.public(),
                )),
            }
        })?
        .build();
    relay.listen_on("/ip4/127.0.0.1/tcp/0/ws".parse()?)?;
    let address = loop {
        if let SwarmEvent::NewListenAddr { address, .. } = relay.select_next_some().await {
            break address;
        }
    };
    relay.add_external_address(address.clone());
    let address = address
        .with(Protocol::P2p(*relay.local_peer_id()))
        .with(Protocol::P2pCircuit);
    host.listen_on(address.clone())?;
    let epoch = now();
    let devices = [browser, destination].map(|peer| Device {
        peer,
        owner: "lab-user".into(),
        tags: vec![],
        active: true,
        lease: LeasePolicy::default(),
    });
    let policy = TeamPolicy::new(
        "browser-test".into(),
        1,
        epoch,
        epoch + 120,
        devices.into(),
        DEFAULT_POLICY,
    )?;
    // The deterministic key is confined to this loopback test fixture.
    let key = SigningKey::from_bytes(&[62; 32]);
    let mut keys = AuthorityKeys::default();
    keys.insert("lab".into(), key.verifying_key());
    let grant = GrantSigner::new("lab".into(), &key)?.sign(
        &policy.authorize(browser, destination, "connect", epoch)?,
        epoch,
    )?;
    let revocations = Revocations::default();
    let deadline = tokio::time::sleep(Duration::from_secs(90));
    tokio::pin!(deadline);
    let mut announced = false;
    loop {
        tokio::select! {
            _ = &mut deadline => return Ok(()),
            _ = relay.select_next_some() => {},
            event = host.select_next_some() => match event {
                SwarmEvent::Behaviour(PeerBehaviourEvent::Relay(relay::client::Event::ReservationReqAccepted { .. })) if !announced => {
                    announced = true;
                    println!("{}", serde_json::json!({"address": address.clone().with(Protocol::P2p(destination)).to_string(), "grant": grant}));
                },
                SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::Message {
                    peer, message: request_response::Message::Request { request, channel, .. }, ..
                })) => {
                    let reply = authorize_probe(&keys, cmux_v3_grants::Scope { team: "browser-test", source: peer, destination, action: "connect" }, request, now(), &revocations);
                    let _ = host.behaviour_mut().probe.send_response(channel, reply);
                },
                _ => {},
            }
        }
    }
}
