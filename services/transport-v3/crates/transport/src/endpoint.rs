//! One swarm owner per enrolled team identity. No app or FFI pointers enter it.
use crate::{
    peer, relay_auth,
    session::{Context, Error, Lane, Session},
    PeerBehaviourEvent,
};
use cmux_v3_grants::{AuthorityKeys, Revocations};
use futures::StreamExt;
use libp2p::{
    core::transport::ListenerId, identity, multiaddr::Protocol, request_response,
    swarm::SwarmEvent, Multiaddr, PeerId,
};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::{
    sync::{mpsc, oneshot, watch, Mutex},
    task::{JoinHandle, JoinSet},
};
use tokio_util::sync::CancellationToken;

type Reply<T> = oneshot::Sender<Result<T, Error>>;
const DEADLINE: Duration = Duration::from_secs(10);
const MAX_PENDING: usize = 64;

pub struct Accepted {
    pub peer: PeerId,
    pub lane: Lane,
    pub session: Session,
}
pub struct Endpoint {
    pub peer: PeerId,
    team: String,
    context: Context,
    authority_keys: Arc<AuthorityKeys>,
    control: libp2p_stream::Control,
    commands: mpsc::Sender<Command>,
    incoming: Mutex<mpsc::Receiver<Accepted>>,
    revocations: watch::Sender<Arc<Revocations>>,
    stopped: CancellationToken,
    task: JoinHandle<()>,
}
enum Command {
    Address(PeerId, Multiaddr, Reply<()>),
    Listen(Multiaddr, Reply<Multiaddr>),
    Auth(PeerId, relay_auth::Request, Reply<()>),
    Addresses(Reply<Vec<Multiaddr>>),
}
impl Drop for Endpoint {
    fn drop(&mut self) {
        self.close();
    }
}
impl Endpoint {
    pub async fn new(
        key: identity::Keypair,
        team: String,
        keys: Arc<AuthorityKeys>,
    ) -> Result<Self, Error> {
        let mut swarm = peer(key).await.map_err(|_| Error::Transport)?;
        let peer = *swarm.local_peer_id();
        let (revocations, updates) = watch::channel(Arc::new(Revocations::default()));
        let authority_keys = keys.clone();
        let context = Context::new(team.clone(), peer, keys, updates, 64)?;
        let control = swarm.behaviour().streams.new_control();
        let mut streams = control
            .clone()
            .accept(crate::session::PROTOCOL)
            .map_err(|_| Error::Protocol)?;
        let (commands, mut requests) = mpsc::channel(MAX_PENDING);
        let (accepted, incoming) = mpsc::channel(8);
        let stopped = CancellationToken::new();
        let stop = stopped.clone();
        let ctx = context.clone();
        let task = tokio::spawn(async move {
            let mut auth = HashMap::<request_response::OutboundRequestId, Reply<()>>::new();
            let mut listening = HashMap::<Multiaddr, (ListenerId, Option<Multiaddr>)>::new();
            let mut waiting = HashMap::<ListenerId, Vec<Reply<Multiaddr>>>::new();
            let mut admissions = JoinSet::new();
            let mut cleanup = tokio::time::interval(Duration::from_secs(1));
            loop {
                tokio::select! {
                    biased;
                    _ = stop.cancelled() => break,
                    _ = cleanup.tick() => {
                        auth.retain(|_, reply| !reply.is_closed());
                        let expired: Vec<_> = waiting.iter_mut().filter_map(|(id, replies)| {
                            replies.retain(|r| !r.is_closed()); replies.is_empty().then_some(*id)
                        }).collect();
                        for id in expired { waiting.remove(&id); swarm.remove_listener(id); }
                    },
                    command = requests.recv() => match command {
                        None => break,
                        Some(Command::Address(peer, addr, reply)) => {
                            swarm.add_peer_address(peer, addr); let _ = reply.send(Ok(()));
                        },
                        Some(Command::Addresses(reply)) => {
                            let _ = reply.send(Ok(swarm.listeners().take(64).cloned().collect()));
                        },
                        Some(Command::Listen(address, reply)) => {
                            if let Some((id, known)) = listening.get(&address) {
                                if let Some(known) = known { let _ = reply.send(Ok(known.clone())); }
                                else {
                                    let replies = waiting.entry(*id).or_default();
                                    if replies.len() < 8 { replies.push(reply); } else { let _ = reply.send(Err(Error::Capacity)); }
                                }
                            } else if listening.len() >= 16 { let _ = reply.send(Err(Error::Capacity)); }
                            else {
                                match swarm.listen_on(address.clone()) {
                                    Ok(id) => { listening.insert(address, (id, None)); waiting.insert(id, vec![reply]); },
                                    Err(_) => { let _ = reply.send(Err(Error::Transport)); },
                                }
                            }
                        },
                        Some(Command::Auth(peer, request, reply)) => {
                            if auth.len() >= MAX_PENDING { let _ = reply.send(Err(Error::Capacity)); }
                            else { let id = swarm.behaviour_mut().relay_auth.send_request(&peer, request); auth.insert(id, reply); }
                        },
                    },
                    Some((peer, stream)) = streams.next(), if admissions.len() < 32 => {
                        let ctx = ctx.clone();
                        admissions.spawn(async move {
                            let (lane, session) = ctx.accept(peer, stream).await?;
                            Ok::<_, Error>(Accepted { peer, lane, session })
                        });
                    },
                    Some(result) = admissions.join_next(), if !admissions.is_empty() => {
                        if let Ok(Ok(value)) = result { let _ = accepted.try_send(value); }
                    },
                    event = swarm.select_next_some() => match event {
                        SwarmEvent::NewListenAddr { listener_id, address } => {
                            if let Some((_, known)) = listening.values_mut().find(|(id, _)| *id == listener_id) {
                                *known = Some(address.clone());
                            }
                            if let Some(replies) = waiting.remove(&listener_id) {
                                for reply in replies { let _ = reply.send(Ok(address.clone())); }
                            }
                        },
                        SwarmEvent::ListenerClosed { listener_id, .. } => {
                            listening.retain(|_, (id, _)| *id != listener_id);
                            if let Some(replies) = waiting.remove(&listener_id) {
                                for reply in replies { let _ = reply.send(Err(Error::Transport)); }
                            }
                        },
                        SwarmEvent::Behaviour(PeerBehaviourEvent::RelayAuth(request_response::Event::Message {
                            message: request_response::Message::Response { request_id, response }, ..
                        })) => {
                            if let Some(reply) = auth.remove(&request_id) {
                                let _ = reply.send(if response == relay_auth::Response::Accepted { Ok(()) } else { Err(Error::Denied) });
                            }
                        },
                        SwarmEvent::Behaviour(PeerBehaviourEvent::RelayAuth(request_response::Event::OutboundFailure { request_id, .. })) => {
                            if let Some(reply) = auth.remove(&request_id) { let _ = reply.send(Err(Error::Transport)); }
                        },
                        _ => {},
                    }
                }
            }
        });
        Ok(Self {
            peer,
            team,
            context,
            authority_keys,
            control,
            commands,
            incoming: Mutex::new(incoming),
            revocations,
            stopped,
            task,
        })
    }
    pub fn close(&self) {
        self.stopped.cancel();
        self.task.abort();
    }
    pub fn cancellation(&self) -> CancellationToken {
        self.stopped.clone()
    }
    async fn request<T>(&self, make: impl FnOnce(Reply<T>) -> Command) -> Result<T, Error> {
        let (tx, rx) = oneshot::channel();
        tokio::select! {
            biased;
            _ = self.stopped.cancelled() => Err(Error::Closed),
            result = tokio::time::timeout(DEADLINE, async {
                self.commands.send(make(tx)).await.map_err(|_| Error::Closed)?;
                rx.await.map_err(|_| Error::Closed)?
            }) => result.map_err(|_| Error::Timeout)?,
        }
    }
    pub async fn listen(&self, address: Multiaddr) -> Result<Multiaddr, Error> {
        self.request(|reply| Command::Listen(address, reply)).await
    }
    pub async fn addresses(&self) -> Result<Vec<Multiaddr>, Error> {
        self.request(Command::Addresses).await
    }
    pub async fn reserve(&self, relay: Multiaddr, grant: String) -> Result<Multiaddr, Error> {
        let relay_peer = match relay.iter().last() {
            Some(Protocol::P2p(peer)) => peer,
            _ => return Err(Error::Protocol),
        };
        self.request(|r| Command::Address(relay_peer, relay.clone(), r))
            .await?;
        self.request(|r| {
            Command::Auth(
                relay_peer,
                relay_auth::Request::Reserve {
                    team: self.team.clone(),
                    grant,
                },
                r,
            )
        })
        .await?;
        self.listen(relay.with(Protocol::P2pCircuit)).await
    }
    pub async fn open(
        &self,
        target: PeerId,
        address: Multiaddr,
        grant: String,
        relay_grant: Option<String>,
        lane: Lane,
    ) -> Result<Session, Error> {
        if address.iter().last() != Some(Protocol::P2p(target)) || address.len() > 2048 {
            return Err(Error::Protocol);
        }
        let mut prefix = Multiaddr::empty();
        for protocol in address.iter() {
            if protocol == Protocol::P2pCircuit {
                let relay = match prefix.iter().last() {
                    Some(Protocol::P2p(peer)) => peer,
                    _ => return Err(Error::Protocol),
                };
                let relay_grant = relay_grant.ok_or(Error::Denied)?;
                self.request(|r| Command::Address(relay, prefix, r)).await?;
                self.request(|r| {
                    Command::Auth(
                        relay,
                        relay_auth::Request::Connect {
                            team: self.team.clone(),
                            destination: target.to_string(),
                            grant: relay_grant,
                        },
                        r,
                    )
                })
                .await?;
                break;
            }
            prefix.push(protocol);
        }
        self.request(|r| Command::Address(target, address, r))
            .await?;
        let mut control = self.control.clone();
        tokio::select! {
            biased;
            _ = self.stopped.cancelled() => Err(Error::Closed),
            value = self.context.open(&mut control, target, grant, lane) => value,
        }
    }
    pub async fn accept(&self) -> Result<Accepted, Error> {
        tokio::select! {
            biased;
            _ = self.stopped.cancelled() => Err(Error::Closed),
            value = async { self.incoming.lock().await.recv().await } => value.ok_or(Error::Closed),
        }
    }
    /// Apply an authority-signed, ordered feed event. Raw peer lists are never
    /// accepted from application code.
    pub fn apply_revocation_token(&self, token: &str) -> Result<(), Error> {
        let update = self
            .authority_keys
            .admit_revocation(token, &self.team, unix_now())
            .map_err(|_| Error::Denied)?;
        let mut next = self.revocations.borrow().as_ref().clone();
        next.apply_update(&update).map_err(|_| Error::Denied)?;
        self.revocations.send_replace(Arc::new(next));
        Ok(())
    }
}

fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}
