//! Independent v3 libp2p composition. No iroh or legacy transport dependencies.
//! The probe protocol is for interoperability verification; it does not expose application RPC.

use std::time::Duration;

use libp2p::{
    dcutr, identify, identity, noise, ping, relay, request_response, swarm::NetworkBehaviour, tcp,
    yamux, StreamProtocol, Swarm, SwarmBuilder,
};
use serde::{Deserialize, Serialize};

pub mod relay_auth;
pub mod session;

pub const PROBE_PROTOCOL: StreamProtocol = StreamProtocol::new("/cmux/transport/3/probe");

#[derive(Debug, Serialize, Deserialize)]
pub struct Probe {
    pub grant: String,
    pub message: String,
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ProbeReply {
    Accepted { message: String },
    Denied,
}

/// Evaluate the grant before touching application data. The peer IDs come from libp2p.
pub fn authorize_probe(
    keys: &cmux_v3_grants::AuthorityKeys,
    scope: cmux_v3_grants::Scope<'_>,
    probe: Probe,
    now: u64,
    revocations: &cmux_v3_grants::Revocations,
) -> ProbeReply {
    if scope.action != "connect"
        || probe.message.len() > 4096
        || keys.admit(&probe.grant, scope, now, revocations).is_err()
    {
        return ProbeReply::Denied;
    }
    ProbeReply::Accepted {
        message: probe.message,
    }
}

#[derive(NetworkBehaviour)]
pub struct PeerBehaviour {
    pub streams: libp2p_stream::Behaviour,
    pub relay_auth: relay_auth::Behaviour,
    pub relay: relay::client::Behaviour,
    pub identify: identify::Behaviour,
    pub dcutr: dcutr::Behaviour,
    pub ping: ping::Behaviour,
    pub probe: request_response::json::Behaviour<Probe, ProbeReply>,
}

/// One transport instance per enrolled identity. UDP direct paths and TCP/WebSocket relay paths
/// use the same PeerId. QUIC supplies TLS; stream transports use Noise and Yamux.
pub async fn peer(key: identity::Keypair) -> anyhow::Result<Swarm<PeerBehaviour>> {
    Ok(SwarmBuilder::with_existing_identity(key)
        .with_tokio()
        .with_tcp(
            tcp::Config::default().nodelay(true),
            noise::Config::new,
            yamux::Config::default,
        )?
        .with_quic()
        .with_dns()?
        .with_websocket(noise::Config::new, yamux::Config::default)
        .await?
        .with_relay_client(noise::Config::new, yamux::Config::default)?
        .with_behaviour(|key, relay| PeerBehaviour {
            streams: libp2p_stream::Behaviour::new(),
            relay_auth: relay_auth::behaviour(),
            relay,
            identify: identify::Behaviour::new(identify::Config::new(
                "cmux/transport/3".into(),
                key.public(),
            )),
            dcutr: dcutr::Behaviour::new(key.public().to_peer_id()),
            ping: ping::Behaviour::default(),
            probe: request_response::json::Behaviour::new(
                [(PROBE_PROTOCOL, request_response::ProtocolSupport::Full)],
                request_response::Config::default().with_request_timeout(Duration::from_secs(10)),
            ),
        })?
        .with_swarm_config(|config| config.with_idle_connection_timeout(Duration::from_secs(60)))
        .build())
}
