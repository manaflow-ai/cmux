//! Live relay acceptance probe. Grants are supplied by an external signing authority
//! over stdin; private authority keys never enter the probe process.
use anyhow::{bail, Context, Result};
use cmux_v3_grants::{AuthorityKeys, Revocations, Scope};
use cmux_v3_transport::{
    authorize_probe, peer, relay_auth, PeerBehaviour, PeerBehaviourEvent, Probe, ProbeReply,
};
use ed25519_dalek::VerifyingKey;
use futures::StreamExt;
use libp2p::{
    identity, multiaddr::Protocol, relay, request_response, swarm::SwarmEvent, Multiaddr, PeerId,
    Swarm,
};
use serde::Deserialize;
use std::{
    collections::BTreeMap,
    io::{BufRead, Write},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
#[derive(Deserialize)]
struct Input {
    relay: String,
    team: String,
    reserve: String,
    connect: String,
    keys: BTreeMap<String, String>,
}
fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
}
async fn auth(
    peer: &mut Swarm<PeerBehaviour>,
    relay: PeerId,
    request: relay_auth::Request,
) -> Result<relay_auth::Response> {
    peer.behaviour_mut()
        .relay_auth
        .send_request(&relay, request);
    loop {
        match peer.select_next_some().await {
            SwarmEvent::Behaviour(PeerBehaviourEvent::RelayAuth(
                request_response::Event::Message {
                    message: request_response::Message::Response { response, .. },
                    ..
                },
            )) => return Ok(response),
            SwarmEvent::Behaviour(PeerBehaviourEvent::RelayAuth(
                request_response::Event::OutboundFailure { error, .. },
            )) => bail!("relay authentication failed: {error}"),
            _ => {}
        }
    }
}
#[tokio::main]
async fn main() -> Result<()> {
    let a = identity::Keypair::generate_ed25519();
    let b = identity::Keypair::generate_ed25519();
    let source = a.public().to_peer_id();
    let destination = b.public().to_peer_id();
    println!(
        "{}",
        serde_json::json!({"source":source.to_string(),"destination":destination.to_string()})
    );
    std::io::stdout().flush()?;
    let input: Input = tokio::task::spawn_blocking(|| -> Result<Input> {
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        if line.len() > 32768 {
            bail!("input too large")
        };
        Ok(serde_json::from_str(&line)?)
    })
    .await??;
    tokio::time::timeout(Duration::from_secs(90), async {
        let address:Multiaddr=input.relay.parse()?;
        let relay=match address.iter().last(){Some(Protocol::P2p(id))=>id,_=>bail!("relay address must end in peer ID")};
        let mut keys=AuthorityKeys::default();
        for (id,hex) in input.keys {
            let bytes=decode_hex(&hex)?;
            keys.insert(id,VerifyingKey::from_bytes(&bytes.try_into().map_err(|_|anyhow::anyhow!("invalid authority key"))?)?);
        }
        let mut host=peer(b).await?;let mut client=peer(a).await?;
        host.dial(address.clone())?;
        if auth(&mut host,relay,relay_auth::Request::Reserve{team:input.team.clone(),grant:"forged".into()}).await?!=relay_auth::Response::Denied {bail!("forged grant accepted")}
        if auth(&mut host,relay,relay_auth::Request::Reserve{team:input.team.clone(),grant:input.reserve}).await?!=relay_auth::Response::Accepted {bail!("valid reservation denied")}
        let reservation=address.with(Protocol::P2pCircuit);
        host.listen_on(reservation.clone())?;
        loop {if matches!(host.select_next_some().await,SwarmEvent::Behaviour(PeerBehaviourEvent::Relay(relay::client::Event::ReservationReqAccepted{..}))){break;}}
        client.dial(input.relay.parse::<Multiaddr>()?)?;
        if auth(&mut client,relay,relay_auth::Request::Connect{team:input.team.clone(),destination:destination.to_string(),grant:input.connect.clone()}).await?!=relay_auth::Response::Accepted{bail!("valid connection denied")}
        client.dial(reservation.with(Protocol::P2p(destination)))?;
        let start=Instant::now();
        for index in 0..160 {
            let message=format!("{index}:{}","x".repeat(2048));
            client.behaviour_mut().probe.send_request(&destination,Probe{grant:input.connect.clone(),message:message.clone()});
            loop {tokio::select! {
                event=client.select_next_some()=>match event {
                    SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::Message{message:request_response::Message::Response{response,..},..}))=>{if response!=(ProbeReply::Accepted{message:message.clone()}){bail!("incorrect response")};break;},
                    SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::OutboundFailure{error,..}))=>bail!("probe failed: {error}"),
                    _=>{}
                },
                event=host.select_next_some()=>if let SwarmEvent::Behaviour(PeerBehaviourEvent::Probe(request_response::Event::Message{peer,message:request_response::Message::Request{request,channel,..},..}))=event {
                    let response=authorize_probe(&keys,Scope{team:&input.team,source:peer,destination,action:"connect"},request,now(),&Revocations::default());
                    host.behaviour_mut().probe.send_response(channel,response).map_err(|_|anyhow::anyhow!("response channel closed"))?;
                }
            }}
        }
        println!("{}",serde_json::json!({"passed":true,"messages":160,"payload_bytes_each_way":160*2048,"elapsed_ms":start.elapsed().as_millis(),"relay":input.relay,"forged_grant":"denied"}));
        Ok::<_,anyhow::Error>(())
    }).await.context("live relay deadline exceeded")??;
    Ok(())
}
fn decode_hex(s: &str) -> Result<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        bail!("invalid hex")
    };
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).context("invalid hex"))
        .collect()
}
