//! Bounded application streams over authenticated libp2p connections.
//! An independent permission task cancels stalled I/O at expiry or revocation.
//! Sending means flushed to the transport, not executed by the remote application.

use bytes::{Bytes, BytesMut};
use cmux_v3_grants::{Admission, AuthorityKeys, Revocations, Scope};
use futures::{SinkExt, StreamExt};
use libp2p::{PeerId, Stream, StreamProtocol};
use serde::{Deserialize, Serialize};
use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{mpsc, oneshot, watch, OwnedSemaphorePermit, Semaphore};
use tokio_util::{
    codec::{Framed, LengthDelimitedCodec},
    compat::{Compat, FuturesAsyncReadCompatExt},
};

pub const PROTOCOL: StreamProtocol = StreamProtocol::new("/cmux/transport/3/session");
pub const MAX_DATA: usize = 64 * 1024;
const MAX_HELLO: usize = 16 * 1024;
const QUEUE: usize = 8;
const HANDSHAKE: Duration = Duration::from_secs(5);
const DATA: u8 = 0;
const RENEW: u8 = 1;
const RENEWED: u8 = 2;
type Wire = Framed<Compat<Stream>, LengthDelimitedCodec>;
type Reply = oneshot::Sender<Result<(), Error>>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum Error {
    #[error("session closed")]
    Closed,
    #[error("transport failed")]
    Transport,
    #[error("invalid session protocol")]
    Protocol,
    #[error("access denied")]
    Denied,
    #[error("authorization expired")]
    Expired,
    #[error("authorization revoked")]
    Revoked,
    #[error("session capacity reached")]
    Capacity,
    #[error("renewal already pending")]
    Busy,
    #[error("handshake timed out")]
    Timeout,
}
impl From<cmux_v3_grants::Error> for Error {
    fn from(value: cmux_v3_grants::Error) -> Self {
        match value {
            cmux_v3_grants::Error::Expired => Self::Expired,
            cmux_v3_grants::Error::Revoked => Self::Revoked,
            _ => Self::Denied,
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum LaneKind {
    Control,
    Events,
    Terminal,
    TerminalInput,
    Artifact,
    Simulator,
}
impl LaneKind {
    pub fn action(self) -> &'static str {
        match self {
            Self::Terminal => "terminal_read",
            Self::TerminalInput => "terminal_write",
            _ => "connect",
        }
    }
}

#[derive(Clone, Copy)]
struct GrantScope {
    source: PeerId,
    destination: PeerId,
    lane: LaneKind,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Lane {
    pub kind: LaneKind,
    pub resource: Option<String>,
    pub cursor: Option<u64>,
}
impl Lane {
    fn validate(&self) -> Result<(), Error> {
        if self
            .resource
            .as_ref()
            .is_some_and(|s| s.is_empty() || s.len() > 1024 || s.chars().any(char::is_control))
        {
            return Err(Error::Protocol);
        }
        Ok(())
    }
}
#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Hello {
    grant: String,
    lane: Lane,
}

/// One context per enrolled team identity. The caller supplies authenticated
/// updates through `revocations`; dropping that feed preserves the offline lease.
#[derive(Clone)]
pub struct Context {
    team: String,
    local: PeerId,
    keys: Arc<AuthorityKeys>,
    revocations: watch::Receiver<Arc<Revocations>>,
    capacity: Arc<Semaphore>,
    clock: Arc<Clock>,
}
struct Clock {
    epoch: u64,
    started: Instant,
}
impl Clock {
    fn now(&self) -> u64 {
        unix_now().max(self.epoch.saturating_add(self.started.elapsed().as_secs()))
    }
}
fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs())
}
impl Context {
    pub fn new(
        team: String,
        local: PeerId,
        keys: Arc<AuthorityKeys>,
        revocations: watch::Receiver<Arc<Revocations>>,
        maximum_sessions: usize,
    ) -> Result<Self, Error> {
        if team.is_empty() || team.len() > 256 || maximum_sessions == 0 || maximum_sessions > 4096 {
            return Err(Error::Capacity);
        }
        Ok(Self {
            team,
            local,
            keys,
            revocations,
            capacity: Arc::new(Semaphore::new(maximum_sessions)),
            clock: Arc::new(Clock {
                epoch: unix_now(),
                started: Instant::now(),
            }),
        })
    }
    fn admit(&self, scope: GrantScope, token: &str) -> Result<Admission, Error> {
        self.keys
            .admit(
                token,
                Scope {
                    team: &self.team,
                    source: scope.source,
                    destination: scope.destination,
                    action: scope.lane.action(),
                },
                self.clock.now(),
                &self.revocations.borrow(),
            )
            .map_err(Into::into)
    }

    /// The libp2p Control authenticates `destination` before this protocol runs.
    pub async fn open(
        &self,
        control: &mut libp2p_stream::Control,
        destination: PeerId,
        grant: String,
        lane: Lane,
    ) -> Result<Session, Error> {
        lane.validate()?;
        let scope = GrantScope {
            source: self.local,
            destination,
            lane: lane.kind,
        };
        self.admit(scope, &grant)?;
        let slot = self
            .capacity
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Capacity)?;
        tokio::time::timeout(HANDSHAKE, async {
            let stream = control
                .open_stream(destination, PROTOCOL)
                .await
                .map_err(|_| Error::Transport)?;
            let mut wire = framed(stream, MAX_HELLO);
            let body = serde_json::to_vec(&Hello {
                grant: grant.clone(),
                lane,
            })
            .map_err(|_| Error::Protocol)?;
            if body.len() > MAX_HELLO {
                return Err(Error::Protocol);
            }
            wire.send(body.into()).await.map_err(|_| Error::Transport)?;
            let response = wire
                .next()
                .await
                .ok_or(Error::Closed)?
                .map_err(|_| Error::Transport)?;
            if response.as_ref() != b"accepted" {
                return Err(Error::Denied);
            }
            let admission = self.admit(scope, &grant)?;
            Ok(self.start(wire, scope, admission, true, slot))
        })
        .await
        .map_err(|_| Error::Timeout)?
    }

    /// `source` MUST come from libp2p IncomingStreams, never a caller's header.
    pub async fn accept(&self, source: PeerId, stream: Stream) -> Result<(Lane, Session), Error> {
        let slot = self
            .capacity
            .clone()
            .try_acquire_owned()
            .map_err(|_| Error::Capacity)?;
        tokio::time::timeout(HANDSHAKE, async {
            let mut wire = framed(stream, MAX_HELLO);
            let body = wire
                .next()
                .await
                .ok_or(Error::Closed)?
                .map_err(|_| Error::Protocol)?;
            let hello: Hello = serde_json::from_slice(&body).map_err(|_| Error::Protocol)?;
            hello.lane.validate()?;
            let scope = GrantScope {
                source,
                destination: self.local,
                lane: hello.lane.kind,
            };
            let admission = self.admit(scope, &hello.grant)?;
            wire.send(Bytes::from_static(b"accepted"))
                .await
                .map_err(|_| Error::Transport)?;
            // The reply itself can stall. Do not return an already-expired session.
            admission.check(self.clock.now(), &self.revocations.borrow())?;
            Ok((hello.lane, self.start(wire, scope, admission, false, slot)))
        })
        .await
        .map_err(|_| Error::Timeout)?
    }
    fn start(
        &self,
        mut wire: Wire,
        scope: GrantScope,
        admission: Admission,
        initiator: bool,
        slot: OwnedSemaphorePermit,
    ) -> Session {
        wire.codec_mut().set_max_frame_length(MAX_DATA + 1);
        let (out_tx, out_rx) = mpsc::channel(QUEUE);
        let (in_tx, in_rx) = mpsc::channel(QUEUE);
        let (closed_tx, closed_rx) = watch::channel(None);
        let (permit_tx, _) = watch::channel(Arc::new(admission));
        let guard = Arc::new(Guard {
            context: self.clone(),
            scope,
            permit: permit_tx,
        });
        let running = guard.clone();
        let task = tokio::spawn(async move {
            let _slot = slot;
            let result = drive(wire, out_rx, in_tx, running, initiator).await;
            closed_tx.send_replace(Some(result));
        });
        Session {
            outgoing: out_tx,
            incoming: in_rx,
            closed: closed_rx,
            guard,
            task,
        }
    }
}

fn framed(stream: Stream, limit: usize) -> Wire {
    LengthDelimitedCodec::builder()
        .max_frame_length(limit)
        .new_framed(stream.compat())
}

struct Guard {
    context: Context,
    scope: GrantScope,
    permit: watch::Sender<Arc<Admission>>,
}
impl Guard {
    fn check(&self) -> Result<(), Error> {
        self.permit
            .borrow()
            .check(self.context.clock.now(), &self.context.revocations.borrow())
            .map_err(Into::into)
    }
    fn validate(&self, token: &str) -> Result<Admission, Error> {
        self.check()?;
        let permit = self.context.admit(self.scope, token)?;
        if permit.version() < self.permit.borrow().version() {
            return Err(Error::Denied);
        }
        Ok(permit)
    }
    fn replace(&self, permit: Admission) -> Result<(), Error> {
        self.check()?;
        permit.check(self.context.clock.now(), &self.context.revocations.borrow())?;
        self.permit.send_replace(Arc::new(permit));
        Ok(())
    }
    async fn invalidated(&self) -> Error {
        let mut permits = self.permit.subscribe();
        let mut revocations = self.context.revocations.clone();
        let mut online = true;
        loop {
            if let Err(error) = self.check() {
                return error;
            }
            // Wall time catches suspension; elapsed time prevents backward clock extension.
            let remaining = self
                .permit
                .borrow()
                .expires_at()
                .map(|exp| exp.saturating_sub(self.context.clock.now()).min(1))
                .unwrap_or(1);
            tokio::select! {
                _ = tokio::time::sleep(Duration::from_secs(remaining)) => {},
                _ = permits.changed() => {},
                result = revocations.changed(), if online => { online = result.is_ok(); },
            }
        }
    }
}

enum Outbound {
    Data(Bytes, Reply),
    Renew(String, Reply),
    Ack(u64),
}
struct Pending {
    id: u64,
    permit: Admission,
    reply: Reply,
}

/// One admitted lane, with bounded queues and deterministic task ownership.
/// Dropping it closes the stream and releases the context's capacity permit.
pub struct Session {
    outgoing: mpsc::Sender<Outbound>,
    incoming: mpsc::Receiver<Bytes>,
    closed: watch::Receiver<Option<Error>>,
    guard: Arc<Guard>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.task.abort();
    }
}
impl Session {
    /// A bounded sender allows writes and renewal while another task reads.
    /// The Session still owns lifetime; dropping it closes all sender handles.
    pub fn sender(&self) -> SessionSender {
        SessionSender {
            outgoing: self.outgoing.clone(),
            closed: self.closed.clone(),
            guard: self.guard.clone(),
            abort: self.task.abort_handle(),
        }
    }
    pub async fn send(&self, bytes: Bytes) -> Result<(), Error> {
        self.sender().send(bytes).await
    }
    /// Returns only after the receiving endpoint acknowledges the signed renewal.
    /// Only the stream initiator may renew. This never extends a token locally.
    pub async fn renew(&self, token: String) -> Result<(), Error> {
        self.sender().renew(token).await
    }
    pub async fn receive(&mut self) -> Result<Bytes, Error> {
        self.guard.check()?;
        let bytes = self.incoming.recv().await.ok_or_else(|| self.failure())?;
        // Never expose buffered application bytes after revocation or expiry.
        self.guard.check()?;
        Ok(bytes)
    }
    pub async fn closed(&self) -> Error {
        let mut closed = self.closed.clone();
        while closed.borrow().is_none() {
            if closed.changed().await.is_err() {
                return Error::Closed;
            }
        }
        let result = (*closed.borrow()).unwrap_or(Error::Closed);
        result
    }
    fn failure(&self) -> Error {
        self.guard
            .check()
            .err()
            .or(*self.closed.borrow())
            .unwrap_or(Error::Closed)
    }
}

#[derive(Clone)]
pub struct SessionSender {
    outgoing: mpsc::Sender<Outbound>,
    closed: watch::Receiver<Option<Error>>,
    guard: Arc<Guard>,
    abort: tokio::task::AbortHandle,
}
impl SessionSender {
    pub async fn send(&self, bytes: Bytes) -> Result<(), Error> {
        if bytes.is_empty() || bytes.len() > MAX_DATA {
            return Err(Error::Protocol);
        }
        self.guard.check()?;
        let (tx, rx) = oneshot::channel();
        self.command(Outbound::Data(bytes, tx), rx).await
    }
    pub async fn renew(&self, token: String) -> Result<(), Error> {
        self.guard.validate(&token)?;
        let (tx, rx) = oneshot::channel();
        self.command(Outbound::Renew(token, tx), rx).await
    }
    async fn command(
        &self,
        command: Outbound,
        reply: oneshot::Receiver<Result<(), Error>>,
    ) -> Result<(), Error> {
        let failure = || {
            self.guard
                .check()
                .err()
                .or(*self.closed.borrow())
                .unwrap_or(Error::Closed)
        };
        match tokio::time::timeout(Duration::from_secs(10), async {
            self.outgoing.send(command).await.map_err(|_| failure())?;
            reply.await.map_err(|_| failure())?
        })
        .await
        {
            Ok(result) => result,
            Err(_) => {
                self.abort.abort();
                Err(Error::Timeout)
            }
        }
    }
}

async fn drive(
    wire: Wire,
    mut outgoing: mpsc::Receiver<Outbound>,
    incoming: mpsc::Sender<Bytes>,
    guard: Arc<Guard>,
    initiator: bool,
) -> Error {
    let (mut sink, mut stream) = wire.split();
    let (control_tx, mut control_rx) = mpsc::channel(4);
    let pending = Mutex::<Option<Pending>>::new(None);
    let read = async {
        while let Some(frame) = stream.next().await {
            let frame = frame.map_err(|_| Error::Transport)?;
            guard.check()?;
            match frame.first().copied() {
                Some(DATA) if frame.len() > 1 => {
                    if !initiator && guard.scope.lane == LaneKind::Terminal {
                        return Err(Error::Denied);
                    }
                    incoming
                        .send(frame.freeze().slice(1..))
                        .await
                        .map_err(|_| Error::Closed)?;
                }
                Some(RENEW) if !initiator && frame.len() > 9 && frame.len() <= 8192 + 9 => {
                    let id =
                        u64::from_be_bytes(frame[1..9].try_into().map_err(|_| Error::Protocol)?);
                    let token = std::str::from_utf8(&frame[9..]).map_err(|_| Error::Protocol)?;
                    guard.replace(guard.validate(token)?)?;
                    control_tx
                        .send(Outbound::Ack(id))
                        .await
                        .map_err(|_| Error::Closed)?;
                }
                Some(RENEWED) if initiator && frame.len() == 9 => {
                    let id =
                        u64::from_be_bytes(frame[1..9].try_into().map_err(|_| Error::Protocol)?);
                    let item = pending
                        .lock()
                        .map_err(|_| Error::Closed)?
                        .take()
                        .ok_or(Error::Protocol)?;
                    if item.id != id {
                        return Err(Error::Protocol);
                    }
                    guard.replace(item.permit)?;
                    let _ = item.reply.send(Ok(()));
                }
                _ => return Err(Error::Protocol),
            }
        }
        Err::<(), _>(Error::Closed)
    };
    let write = async {
        let mut sequence = 0_u64;
        loop {
            let command = tokio::select! {
                biased;
                value = control_rx.recv() => value.ok_or(Error::Closed)?,
                value = outgoing.recv() => value.ok_or(Error::Closed)?,
            };
            guard.check()?;
            let mut body = BytesMut::new();
            let reply = match command {
                Outbound::Data(bytes, reply) => {
                    if initiator && guard.scope.lane == LaneKind::Terminal {
                        let _ = reply.send(Err(Error::Denied));
                        continue;
                    }
                    body.extend_from_slice(&[DATA]);
                    body.extend_from_slice(&bytes);
                    Some(reply)
                }
                Outbound::Ack(id) => {
                    body.extend_from_slice(&[RENEWED]);
                    body.extend_from_slice(&id.to_be_bytes());
                    None
                }
                Outbound::Renew(token, reply) => {
                    if !initiator {
                        let _ = reply.send(Err(Error::Denied));
                        continue;
                    }
                    let permit = match guard.validate(&token) {
                        Ok(permit) => permit,
                        Err(error) => {
                            let _ = reply.send(Err(error));
                            continue;
                        }
                    };
                    let mut state = pending.lock().map_err(|_| Error::Closed)?;
                    if state.is_some() {
                        let _ = reply.send(Err(Error::Busy));
                        continue;
                    }
                    sequence = sequence.checked_add(1).ok_or(Error::Protocol)?;
                    *state = Some(Pending {
                        id: sequence,
                        permit,
                        reply,
                    });
                    body.extend_from_slice(&[RENEW]);
                    body.extend_from_slice(&sequence.to_be_bytes());
                    body.extend_from_slice(token.as_bytes());
                    None
                }
            };
            sink.send(body.freeze())
                .await
                .map_err(|_| Error::Transport)?;
            if let Some(reply) = reply {
                let _ = reply.send(Ok(()));
            }
        }
        #[allow(unreachable_code)]
        Ok::<(), Error>(())
    };
    // Cancellation drops both stream halves, queued data and pending acknowledgments.
    // Neither backpressure nor an unresponsive peer can delay permission enforcement.
    tokio::select! {
        biased;
        error = guard.invalidated() => error,
        result = read => result.err().unwrap_or(Error::Closed),
        result = write => result.err().unwrap_or(Error::Closed),
    }
}
