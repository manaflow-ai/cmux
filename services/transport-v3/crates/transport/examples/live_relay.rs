//! Live relay acceptance probe. Grants are supplied by an external signing authority
//! over stdin; private authority keys never enter the probe process.
use anyhow::{bail, Context, Result};
use cmux_v3_grants::{AuthorityKeys, Revocations};
use cmux_v3_transport::{peer, relay_auth, session, PeerBehaviour, PeerBehaviourEvent};
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
    sync::Arc,
    time::{Duration, Instant},
};
#[derive(Deserialize)]
struct Input {
    relay: String,
    team: String,
    reserve: String,
    connect: String,
    keys: BTreeMap<String, String>,
}
async fn pump<T>(
    a: &mut Swarm<PeerBehaviour>,
    b: &mut Swarm<PeerBehaviour>,
    future: impl std::future::Future<Output = T>,
) -> T {
    tokio::pin!(future);
    loop {
        tokio::select! {
            value = &mut future => return value,
            _ = a.select_next_some() => {},
            _ = b.select_next_some() => {},
        }
    }
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
        let start = Instant::now();
        let keys = Arc::new(keys);
        let (_, updates) = tokio::sync::watch::channel(Arc::new(Revocations::default()));
        let client_context = session::Context::new(input.team.clone(), source, keys.clone(), updates.clone(), 4)?;
        let host_context = session::Context::new(input.team.clone(), destination, keys, updates, 4)?;
        let mut control = client.behaviour().streams.new_control();
        let mut incoming = host.behaviour().streams.new_control().accept(session::PROTOCOL)?;
        let lane = session::Lane { kind: session::LaneKind::Control, resource: None, cursor: None };
        let (mut sending, mut receiving) = pump(&mut client, &mut host, async {
            let accept = async {
                let (peer, stream) = incoming.next().await.context("stream listener closed")?;
                anyhow::ensure!(peer == source, "unexpected source identity");
                Ok::<_, anyhow::Error>(host_context.accept(peer, stream).await?.1)
            };
            let (client, host) = tokio::join!(client_context.open(&mut control, destination, input.connect.clone(), lane), accept);
            Ok::<_, anyhow::Error>((client?, host?))
        }).await?;
        pump(&mut client, &mut host, sending.renew(input.connect)).await?;
        pump(&mut client, &mut host, async {
            for index in 0_u64..160 {
                let mut message = vec![b'x'; 2048];
                message[..8].copy_from_slice(&index.to_be_bytes());
                sending.send(message.clone().into()).await?;
                let received = receiving.receive().await?.ok_or_else(|| anyhow::anyhow!("clean eof"))?;
                anyhow::ensure!(received.as_ref() == message, "incorrect request bytes");
                receiving.send(received).await?;
                anyhow::ensure!(sending.receive().await?.as_ref().is_some_and(|received| received.as_ref() == message), "incorrect response bytes");
            }
            Ok::<_, anyhow::Error>(())
        }).await?;
        println!("{}",serde_json::json!({"passed":true,"protocol":"/cmux/transport/3/session","messages":160,"payload_bytes_each_way":160*2048,"elapsed_ms":start.elapsed().as_millis(),"relay":input.relay,"forged_grant":"denied","renewal":"acknowledged"}));
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
