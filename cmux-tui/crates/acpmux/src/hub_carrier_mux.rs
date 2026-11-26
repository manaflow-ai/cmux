//! One kept, multiplexed circuit per machine pair (`HubCarrier::dial_service`). Leo, 2026-11-23:
//! "we should make our own better ssh."
//!
//! A named-service dial (`_acpmux/remote.pipe`, `tools/carrier-pipe`, a session circuit) used to
//! open a whole new circuit every time: a platform ticket call, a relay allocation, the far
//! machine joining, Noise XX, then the service hello and its answer. Now the first such dial to a
//! machine opens one circuit whose hello names the `mux` service, and the daemon keeps it. Each
//! dial after that is a new stream on it: one OPEN record carrying the service hello, one ANSWER
//! back, so a second dial to the same machine costs about one relay round trip. Twenty dials at
//! once share the one circuit (the first opens it, the rest wait on that open, not on twenty).
//!
//! Wire (each one Noise record on the circuit): `kind u8`, `stream u32` big-endian, payload.
//! - OPEN (dialer's odd ids): the service hello a plain circuit's first record would carry.
//! - ANSWER: the hello's answer record (`{"ok":true}` or the refusal), as on a plain circuit.
//! - DATA: stream bytes. WINDOW: `u32` bytes the receiver wrote on, the sender's credit back.
//!   Each stream starts with [`WINDOW_BYTES`] of credit, so a slow reader stalls only its stream
//!   and the bytes held for it stay bounded.
//! - FIN: the sender is done writing (a half close, as TCP's). RESET: the stream ends now.
//! - PING / PONG (stream 0): the dialer's keepalive.
//!
//! Liveness is by event. The circuit is dropped when the relay or the far machine closes it, when
//! a record does not parse, when the dialer's keepalive hears nothing for two periods, and when
//! an OPEN gets no answer and nothing else came back after it (the dialer sends a PING with every
//! OPEN, so a slow admission on a live circuit is told apart from a dead one). The next dial then
//! opens a new kept circuit, once; past that it takes the plain path. A circuit with no stream
//! for [`Timings::kept_idle`] closes itself.
//!
//! A machine whose acpmux predates this answers the `mux` hello `service.unknown` (its
//! `named_service` knows no such service): that dial takes a plain circuit, and the carrier dials
//! that machine the plain way, asking again only after [`NO_MUX_ASK_AGAIN`]. No plain circuit
//! is dialed beside the ask: a service hello can ask the far owner for consent, once per dial.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use bytes::{BufMut, Bytes, BytesMut};
use cmux_remote::link::FrameLink;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Notify, Semaphore, mpsc, oneshot};

use super::{
    CHUNK_BYTES, DUPLEX_BYTES, HubStream, Incoming, SERVICE_HELLO, ServiceRefusal, Stats,
    connect_session, named_service, read_service_answer, service_answer,
};
use super::{CircuitLane as Lane, CircuitService};

const OPEN: u8 = 1;
const ANSWER: u8 = 2;
const DATA: u8 = 3;
const WINDOW: u8 = 4;
const FIN: u8 = 5;
const RESET: u8 = 6;
const PING: u8 = 7;
const PONG: u8 = 8;
const HEADER: usize = 5;

/// Each stream's credit: bytes a sender may have in flight before the receiver wrote them on.
pub(crate) const WINDOW_BYTES: u32 = 256 * 1024;
/// The service a kept circuit's hello names.
pub(crate) const MUX_SERVICE: &str = "mux";
/// How long a machine that answered the `mux` hello `service.unknown` is dialed the plain way
/// before it is asked again (its acpmux may have updated since).
pub(crate) const NO_MUX_ASK_AGAIN: Duration = Duration::from_secs(600);
/// How long an OPEN waits for its answer before the circuit is suspected: past it, the circuit
/// counts as dead only if nothing at all came back since the OPEN (its PING's PONG included).
pub(crate) const ANSWER_SUSPECT: Duration = Duration::from_secs(3);

/// The owner of every kept circuit's tasks. Each ends on its own: a stream when both its
/// directions end or it is reset, a circuit's reader when the circuit ends, its keepalive when
/// the circuit closes or the carrier that kept it is gone.
fn scope() -> &'static cmux_scope::Scope {
    static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
    SCOPE.get_or_init(|| cmux_scope::Scope::new("hub carrier kept circuits"))
}

/// The hello record of a kept circuit.
pub(crate) fn mux_hello() -> Bytes {
    let mut record = SERVICE_HELLO.to_vec();
    record.extend_from_slice(
        serde_json::json!({"service": MUX_SERVICE, "version": 1}).to_string().as_bytes(),
    );
    Bytes::from(record)
}

/// Whether a circuit's first record asks for a kept, multiplexed circuit.
pub(crate) fn is_mux_hello(first: &[u8]) -> bool {
    first.strip_prefix(SERVICE_HELLO).is_some_and(|body| {
        serde_json::from_slice::<serde_json::Value>(body).is_ok_and(|hello| {
            hello.get("service").and_then(serde_json::Value::as_str) == Some(MUX_SERVICE)
        })
    })
}

fn record(kind: u8, id: u32, payload: &[u8]) -> Bytes {
    let mut out = BytesMut::with_capacity(HEADER + payload.len());
    out.put_u8(kind);
    out.put_u32(id);
    out.put_slice(payload);
    out.freeze()
}

fn parse(record: &Bytes) -> Option<(u8, u32, Bytes)> {
    let kind = *record.first()?;
    let id = u32::from_be_bytes(record.get(1..HEADER)?.try_into().ok()?);
    Some((kind, id, record.slice(HEADER..)))
}

enum Event {
    Data(Bytes),
    Fin,
}

struct Entry {
    events: mpsc::UnboundedSender<Event>,
    credit: Arc<Semaphore>,
    answer: Option<oneshot::Sender<Result<(), ServiceRefusal>>>,
    /// `gauges.links.keptStreamsOpen`, given back when the stream leaves the circuit.
    _open: crate::gauges::Held,
}

/// Which end of a kept circuit this is.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    Dialer,
    Server,
}

/// One kept circuit and its streams.
pub(crate) struct Mux {
    link: Arc<dyn FrameLink>,
    role: Role,
    streams: Mutex<HashMap<u32, Entry>>,
    next: AtomicU32,
    closed: AtomicBool,
    closing: Notify,
    /// When the last record came in, any kind.
    heard: Mutex<Instant>,
    /// When the last stream ended (or the circuit opened), for the idle close.
    quiet_since: Mutex<Instant>,
    stats: Arc<Stats>,
    /// The dialer's: where the answer to its `mux` hello goes, the circuit's first record back.
    hello: Mutex<Option<oneshot::Sender<Result<(), ServiceRefusal>>>>,
    /// `gauges.links.hubKeptOpen`: given back at `close`, or when the circuit drops unclosed.
    open: Mutex<Option<crate::gauges::Held>>,
}

/// The answer to a kept circuit's `mux` hello.
pub(crate) type HelloAnswer = oneshot::Receiver<Result<(), ServiceRefusal>>;

impl Mux {
    fn new(link: Box<dyn FrameLink>, role: Role, stats: Arc<Stats>) -> Arc<Self> {
        Arc::new(Self {
            link: Arc::from(link),
            role,
            streams: Mutex::new(HashMap::new()),
            next: AtomicU32::new(1),
            closed: AtomicBool::new(false),
            closing: Notify::new(),
            heard: Mutex::new(Instant::now()),
            quiet_since: Mutex::new(Instant::now()),
            stats,
            hello: Mutex::new(None),
            open: Mutex::new(Some(crate::gauges::Held::on(&crate::gauges::links().hub_kept_open))),
        })
    }

    pub(crate) fn is_closed(&self) -> bool {
        self.closed.load(Ordering::SeqCst)
    }

    /// How many streams ride the circuit now.
    pub(crate) fn streams(&self) -> usize {
        self.streams.lock().unwrap_or_else(|e| e.into_inner()).len()
    }

    fn heard(&self) -> Instant {
        *self.heard.lock().unwrap_or_else(|e| e.into_inner())
    }

    async fn send(&self, kind: u8, id: u32, payload: &[u8]) -> Result<(), String> {
        if self.is_closed() {
            return Err("the kept circuit closed".into());
        }
        self.link.send(record(kind, id, payload)).await.map_err(|e| e.to_string())
    }

    /// Close the circuit and end every stream on it (their readers see the end, their writers an
    /// error, an open waiting on its answer an error).
    pub(crate) async fn close(&self) {
        if self.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        let streams = std::mem::take(&mut *self.streams.lock().unwrap_or_else(|e| e.into_inner()));
        for entry in streams.into_values() {
            entry.credit.close();
        }
        self.open.lock().unwrap_or_else(|e| e.into_inner()).take();
        self.closing.notify_waiters();
        let _ = self.link.close().await;
    }

    fn remove(&self, id: u32) {
        let mut streams = self.streams.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(entry) = streams.remove(&id) {
            entry.credit.close();
        }
        if streams.is_empty() {
            *self.quiet_since.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
        }
    }

    fn register(
        &self,
        id: u32,
        answer: Option<oneshot::Sender<Result<(), ServiceRefusal>>>,
    ) -> Option<(mpsc::UnboundedReceiver<Event>, Arc<Semaphore>)> {
        let (events, received) = mpsc::unbounded_channel();
        let credit = Arc::new(Semaphore::new(WINDOW_BYTES as usize));
        let mut streams = self.streams.lock().unwrap_or_else(|e| e.into_inner());
        // Checked under the lock `close` takes the streams under: none is added after it.
        if self.is_closed() || streams.contains_key(&id) {
            return None;
        }
        let _open = crate::gauges::Held::on(&crate::gauges::links().kept_streams_open);
        streams.insert(id, Entry { events, credit: credit.clone(), answer, _open });
        Some((received, credit))
    }

    /// Read the circuit's records until it ends, then close it. `incoming` (the serving side)
    /// answers each OPEN; `from` is the dialer's key as the handshake proved it.
    async fn read(self: Arc<Self>, incoming: Option<(Arc<Incoming>, Option<String>)>) {
        loop {
            let record = match self.link.receive().await {
                Ok(Some(record)) => record,
                Ok(None) => break,
                Err(e) => {
                    tracing::debug!("hub carrier: a kept circuit ended: {e}");
                    break;
                }
            };
            *self.heard.lock().unwrap_or_else(|e| e.into_inner()) = Instant::now();
            let hello = self.hello.lock().unwrap_or_else(|e| e.into_inner()).take();
            if let Some(hello) = hello {
                let answer = read_service_answer(&record);
                let refused = answer.is_err();
                let _ = hello.send(answer);
                if refused {
                    break;
                }
                continue;
            }
            let Some((kind, id, payload)) = parse(&record) else { break };
            match kind {
                PING => {
                    if self.send(PONG, 0, &[]).await.is_err() {
                        break;
                    }
                }
                PONG => {}
                OPEN => {
                    // Only the dialer opens streams, on odd ids.
                    let Some((incoming, from)) = incoming.as_ref() else { break };
                    if id % 2 == 0 {
                        break;
                    }
                    let Some((events, credit)) = self.register(id, None) else { break };
                    let mux = self.clone();
                    let (incoming, from) = (incoming.clone(), from.clone());
                    scope().spawn_named("hub carrier kept stream (serving)", async move {
                        mux.serve_open(incoming, from, id, payload, events, credit).await
                    });
                }
                ANSWER => {
                    let answer = read_service_answer(&payload);
                    let waiting = self
                        .streams
                        .lock()
                        .unwrap_or_else(|e| e.into_inner())
                        .get_mut(&id)
                        .and_then(|entry| entry.answer.take());
                    let refused = answer.is_err();
                    if let Some(waiting) = waiting {
                        let _ = waiting.send(answer);
                    }
                    if refused {
                        self.remove(id);
                    }
                }
                DATA | FIN => {
                    let streams = self.streams.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(entry) = streams.get(&id) {
                        let event = if kind == DATA { Event::Data(payload) } else { Event::Fin };
                        let _ = entry.events.send(event);
                    }
                }
                WINDOW => {
                    let Some(granted) = payload.get(..4).and_then(|b| b.try_into().ok()) else {
                        break;
                    };
                    let granted = u32::from_be_bytes(granted) as usize;
                    let streams = self.streams.lock().unwrap_or_else(|e| e.into_inner());
                    if let Some(entry) = streams.get(&id) {
                        // A peer granting past the window is broken; the credit stays bounded.
                        let room = (WINDOW_BYTES as usize)
                            .saturating_sub(entry.credit.available_permits());
                        entry.credit.add_permits(granted.min(room));
                    }
                }
                RESET => self.remove(id),
                _ => break,
            }
        }
        self.close().await;
    }

    /// The serving side of one OPEN: admit the service as a plain circuit's hello is admitted,
    /// answer, then carry the stream.
    async fn serve_open(
        self: Arc<Self>,
        incoming: Arc<Incoming>,
        from: Option<String>,
        id: u32,
        hello: Bytes,
        events: mpsc::UnboundedReceiver<Event>,
        credit: Arc<Semaphore>,
    ) {
        let named = named_service(&hello).unwrap_or_else(|| {
            Err(ServiceRefusal::new("service.unknown", "a kept circuit's stream named no service"))
        });
        let refuse = |refusal: ServiceRefusal| {
            let mux = self.clone();
            async move {
                tracing::info!("hub carrier: a kept circuit's stream was refused: {refusal}");
                let _ = mux.send(ANSWER, id, &service_answer(&Err(refusal))).await;
                mux.remove(id);
            }
        };
        match named {
            Ok(CircuitService::CmuxTui { port }) => match incoming.cmux_tui(port).await {
                Ok(local) => self.carry_admitted(id, local, events, credit).await,
                Err(refusal) => refuse(refusal).await,
            },
            Ok(CircuitService::CmuxTuiResume { port }) => {
                match resume::open(&incoming, from, port).await {
                    Ok((local, serving)) => {
                        tokio::join!(serving, self.carry_admitted(id, local, events, credit));
                    }
                    Err(refusal) => refuse(refusal).await,
                }
            }
            Ok(CircuitService::CmuxTuiSession) => {
                let local = match incoming.admit_session(from).await {
                    Ok(socket) => connect_session(&socket).await.map_err(|e| {
                        ServiceRefusal::new(
                            "service.unreachable",
                            format!("this machine's cmux-tui session is not running: {e}"),
                        )
                    }),
                    Err(refusal) => Err(refusal),
                };
                match local {
                    Ok(local) => self.carry_admitted(id, local, events, credit).await,
                    Err(refusal) => refuse(refusal).await,
                }
            }
            Ok(CircuitService::MachineCall) => match incoming.machine_call(from).await {
                Ok(local) => self.carry_admitted(id, local, events, credit).await,
                Err(refusal) => refuse(refusal).await,
            },
            Ok(CircuitService::TransferSource) => match incoming.transfer(from).await {
                Ok((local, serving)) => {
                    tokio::join!(serving, self.carry_admitted(id, local, events, credit));
                }
                Err(refusal) => refuse(refusal).await,
            },
            // The acpmux listener, reached as a plain circuit with no hello reaches it: the
            // peer link and its hub probe ride the pair's one kept circuit.
            Ok(CircuitService::Acpmux)
                if incoming.carrier.acpmux_streams.load(Ordering::SeqCst) =>
            {
                match tokio::net::TcpStream::connect(incoming.websocket).await {
                    Ok(local) => {
                        let _ = local.set_nodelay(true);
                        self.carry_admitted(id, local, events, credit).await
                    }
                    Err(e) => {
                        refuse(ServiceRefusal::new(
                            "service.unreachable",
                            format!("this machine's acpmux listener is not reachable: {e}"),
                        ))
                        .await
                    }
                }
            }
            // A daemon from before acpmux streams answered this way; its dialers go plain.
            Ok(CircuitService::Acpmux) => {
                refuse(ServiceRefusal::new("service.unknown", "no such service")).await
            }
            Err(refusal) => refuse(refusal).await,
        }
    }

    async fn carry_admitted<S>(
        self: Arc<Self>,
        id: u32,
        local: S,
        events: mpsc::UnboundedReceiver<Event>,
        credit: Arc<Semaphore>,
    ) where
        S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
    {
        if self.send(ANSWER, id, &service_answer(&Ok(()))).await.is_err() {
            self.remove(id);
            return;
        }
        self.stats.accepted.fetch_add(1, Ordering::Relaxed);
        self.carry(id, local, events, credit).await;
    }

    /// Carry one stream between `io` and the circuit until both directions ended or either side
    /// reset it.
    async fn carry<S>(
        self: Arc<Self>,
        id: u32,
        io: S,
        mut events: mpsc::UnboundedReceiver<Event>,
        credit: Arc<Semaphore>,
    ) where
        S: AsyncRead + AsyncWrite + Send + Unpin,
    {
        let (mut read, mut write) = tokio::io::split(io);
        let chunk = self.link.maximum_frame_bytes().saturating_sub(HEADER).clamp(1, CHUNK_BYTES);
        let up = async {
            let mut buf = vec![0u8; chunk];
            loop {
                let n = read.read(&mut buf).await.map_err(|e| e.to_string())?;
                if n == 0 {
                    return self.send(FIN, id, &[]).await;
                }
                let permits = u32::try_from(n).map_err(|e| e.to_string())?;
                credit.acquire_many(permits).await.map_err(|e| e.to_string())?.forget();
                let bytes = buf.get(..n).ok_or("the read overran its buffer")?;
                self.send(DATA, id, bytes).await?;
                self.stats.sent.fetch_add(n as u64, Ordering::Relaxed);
                self.stats.records.fetch_add(1, Ordering::Relaxed);
            }
        };
        let down = async {
            while let Some(event) = events.recv().await {
                match event {
                    Event::Data(bytes) => {
                        write.write_all(&bytes).await.map_err(|e| e.to_string())?;
                        self.stats.received.fetch_add(bytes.len() as u64, Ordering::Relaxed);
                        self.stats.records.fetch_add(1, Ordering::Relaxed);
                        let granted = u32::try_from(bytes.len()).unwrap_or(u32::MAX);
                        self.send(WINDOW, id, &granted.to_be_bytes()).await?;
                    }
                    Event::Fin => {
                        let _ = write.shutdown().await;
                        return Ok::<_, String>(());
                    }
                }
            }
            Err("the stream was reset".to_owned())
        };
        // The two directions end in this block, so `write` is free for the close after it.
        let clean = {
            tokio::pin!(up, down);
            let (mut up_done, mut down_done) = (false, false);
            loop {
                tokio::select! {
                    ended = &mut up, if !up_done => match ended {
                        Ok(()) => up_done = true,
                        Err(_) => break false,
                    },
                    ended = &mut down, if !down_done => match ended {
                        Ok(()) => down_done = true,
                        Err(_) => break false,
                    },
                }
                if up_done && down_done {
                    break true;
                }
            }
        };
        if !clean {
            let _ = self.send(RESET, id, &[]).await;
        }
        let _ = write.shutdown().await;
        self.remove(id);
    }

    /// Open one stream naming `hello`'s service. `Ok(Err)` is the far machine's refusal;
    /// `Err` says the circuit failed under the open (the caller drops it and dials again).
    pub(crate) async fn open(
        self: &Arc<Self>,
        hello: Bytes,
        answer_wait: Duration,
    ) -> Result<Result<HubStream, ServiceRefusal>, String> {
        let id = self.next.fetch_add(2, Ordering::SeqCst);
        let (answered, answer) = oneshot::channel();
        let (events, credit) =
            self.register(id, Some(answered)).ok_or("the kept circuit closed")?;
        let sent_at = Instant::now();
        if let Err(e) = self.send(OPEN, id, &hello).await {
            self.remove(id);
            return Err(e);
        }
        // A PING with every OPEN: if anything comes back, the circuit is alive.
        let _ = self.send(PING, 0, &[]).await;
        tokio::pin!(answer);
        let answered = match tokio::time::timeout(ANSWER_SUSPECT, &mut answer).await {
            Ok(answered) => answered,
            // Alive but slow to admit (a loaded machine reading its consent), or this machine
            // did not run for a whole suspect window (its timer fired that late, so its reader
            // had no turn to hear the far side either, cmux#52200): wait it out.
            Err(_) if self.heard() > sent_at || sent_at.elapsed() >= ANSWER_SUSPECT * 2 => {
                match tokio::time::timeout(answer_wait.saturating_sub(ANSWER_SUSPECT), answer).await
                {
                    Ok(answered) => answered,
                    Err(_) => {
                        let _ = self.send(RESET, id, &[]).await;
                        self.remove(id);
                        return Ok(Err(ServiceRefusal::new(
                            "service.bad_answer",
                            "the machine did not answer the service hello in time",
                        )));
                    }
                }
            }
            Err(_) => {
                self.remove(id);
                return Err("the kept circuit went silent".into());
            }
        };
        match answered {
            Err(_) => Err("the kept circuit closed before the stream was answered".into()),
            Ok(Err(refusal)) => Ok(Err(refusal)),
            Ok(Ok(())) => {
                self.stats.kept_opens.fetch_add(1, Ordering::Relaxed);
                crate::gauges::bump(&crate::gauges::links().kept_stream_opens);
                let (ours, theirs) = tokio::io::duplex(DUPLEX_BYTES);
                let mux = self.clone();
                scope().spawn_named("hub carrier kept stream", async move {
                    mux.carry(id, theirs, events, credit).await
                });
                Ok(Ok(ours))
            }
        }
    }

    /// The dialer's keepalive and idle close, until the circuit closes or `owner` (the carrier)
    /// is gone.
    async fn keep(self: Arc<Self>, owner: Weak<()>, every: Duration, idle: Duration) {
        loop {
            tokio::select! {
                _ = tokio::time::sleep(every) => {}
                _ = self.closing.notified() => return,
            }
            if self.is_closed() {
                return;
            }
            let quiet = self.streams() == 0
                && self.quiet_since.lock().unwrap_or_else(|e| e.into_inner()).elapsed() >= idle;
            if owner.upgrade().is_none() || quiet || self.heard().elapsed() >= every * 2 {
                self.close().await;
                return;
            }
            if self.send(PING, 0, &[]).await.is_err() {
                self.close().await;
                return;
            }
        }
    }
}

/// Start the dialer's end of a kept circuit whose `mux` hello was just sent: streams may open on
/// it at once, and the hello's answer comes on the returned receiver.
pub(crate) fn start_dialer(
    link: Box<dyn FrameLink>,
    stats: Arc<Stats>,
    owner: Weak<()>,
    every: Duration,
    idle: Duration,
) -> (Arc<Mux>, HelloAnswer) {
    let mux = Mux::new(link, Role::Dialer, stats);
    let (said, answer) = oneshot::channel();
    *mux.hello.lock().unwrap_or_else(|e| e.into_inner()) = Some(said);
    scope().spawn_named("hub carrier kept circuit reader", mux.clone().read(None));
    scope().spawn_named("hub carrier kept circuit keepalive", mux.clone().keep(owner, every, idle));
    (mux, answer)
}

/// Serve a kept circuit whose `mux` hello this machine answered, until it ends.
pub(crate) async fn serve(
    link: Box<dyn FrameLink>,
    incoming: Arc<Incoming>,
    from: Option<String>,
    stats: Arc<Stats>,
) {
    let mux = Mux::new(link, Role::Server, stats);
    debug_assert!(mux.role == Role::Server);
    mux.read(Some((incoming, from))).await;
}

/// The kept circuit to one machine, or why there is none.
#[derive(Default)]
pub(crate) struct Kept {
    pub(crate) live: Option<Arc<Mux>>,
    /// Set when the machine answered the `mux` hello `service.unknown`.
    pub(crate) no_mux_until: Option<Instant>,
    /// Set when the machine's kept circuit refused an acpmux stream `service.unknown` (it
    /// predates them): acpmux dials go plain to it until then.
    pub(crate) no_acpmux_until: Option<Instant>,
}

/// Every kept circuit of a carrier, by machine (`daemonId`) and [`Lane`](super::CircuitLane).
#[derive(Default)]
pub(crate) struct KeptCircuits {
    by_machine: Mutex<HashMap<(String, Lane), Arc<tokio::sync::Mutex<Kept>>>>,
}

impl KeptCircuits {
    pub(crate) fn slot(&self, daemon: &str, lane: Lane) -> Arc<tokio::sync::Mutex<Kept>> {
        self.by_machine
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .entry((daemon.to_owned(), lane))
            .or_default()
            .clone()
    }

    /// Drop every kept circuit (a rekey: the far machines pinned the old key).
    pub(crate) fn clear(&self) {
        let all = std::mem::take(&mut *self.by_machine.lock().unwrap_or_else(|e| e.into_inner()));
        for slot in all.into_values() {
            if let Ok(kept) = slot.try_lock()
                && let Some(mux) = kept.live.clone()
            {
                scope().spawn_named(
                    "hub carrier kept circuit close",
                    async move { mux.close().await },
                );
            }
        }
    }

    /// The live kept circuits to `daemon` open now, cheap first.
    pub(crate) fn live(&self, daemon: &str) -> Vec<Arc<Mux>> {
        let by_machine = self.by_machine.lock().unwrap_or_else(|e| e.into_inner());
        [Lane::Cheap, Lane::Bulk]
            .into_iter()
            .filter_map(|lane| by_machine.get(&(daemon.to_owned(), lane)).cloned())
            .filter_map(|slot| slot.try_lock().ok()?.live.clone())
            .filter(|mux| !mux.is_closed())
            .collect()
    }
}

#[path = "hub_carrier_resume.rs"]
mod resume;

#[cfg(test)]
mod live {
    use super::super::{
        CircuitService, HubCarrier, PlatformTickets, Tickets, Timings, service_hello,
    };
    use cmux_remote::link::FrameLink;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    /// Where one cold circuit's time goes, stage by stage, dialed from this machine's own home
    /// to a live peer (run on demand, never in CI: it spends real tickets):
    /// `CARRIER_STAGES_PEER=<daemonId> cargo test -p acpmux --features hub-carrier --lib
    /// carrier_stages_live -- --ignored --nocapture`. A dialer only: it registers nothing, takes
    /// no key lock (it reads the node key as the cmux link's path does) and leaves the running
    /// daemon alone. `hello_ms` (service hello to its answer, the far side's sshd connect
    /// included) is what a stream open on an already-open circuit costs: one OPEN, one ANSWER.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "dials a live peer from this machine's home"]
    async fn carrier_stages_live() {
        let peer = std::env::var("CARRIER_STAGES_PEER").expect("CARRIER_STAGES_PEER=<daemonId>");
        let port: u16 =
            std::env::var("CARRIER_STAGES_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(22);
        let runs: usize =
            std::env::var("CARRIER_STAGES_RUNS").ok().and_then(|p| p.parse().ok()).unwrap_or(5);
        let home = crate::config::default_home();
        let config = crate::config::Config::load_from(&home.join("config.json")).unwrap();
        let relay = config.mesh_relay.clone().expect("this home is not joined");
        let tickets = Arc::new(PlatformTickets {
            hub: crate::mesh_http::HttpHub::new(&relay).unwrap(),
            shown: relay.shown(),
        });
        let key = crate::mesh_node_key::read_noise_static(&home).unwrap();
        // CARRIER_STAGES_FRESH=1: a new carrier per run, so every dial is a first one (no kept
        // ticket, no kept circuit): the cold dial before cut 5's ticket cache.
        let fresh = std::env::var_os("CARRIER_STAGES_FRESH").is_some();
        let mut carrier = HubCarrier::new(tickets.clone(), *key, Timings::default());
        let ms = |d: Duration| format!("{:.0}", d.as_secs_f64() * 1e3);
        for run in 0..runs {
            // A raw TCP connect to the relay the ticket names, to split TCP from TLS+WS+allocate.
            let answer = tickets.connect(&peer).await.unwrap();
            let now_s = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();
            eprintln!("CARRIER-STAGES ticket expires_at={} now={now_s}", answer.expires_at);
            let url = url::Url::parse(&answer.relay).unwrap();
            let target = format!("{}:{}", url.host_str().unwrap(), url.port().unwrap_or(443));
            let started = Instant::now();
            let tcp = tokio::net::TcpStream::connect(&target).await.unwrap();
            let tcp_ms = started.elapsed();
            drop(tcp);

            if fresh {
                carrier = HubCarrier::new(tickets.clone(), *key, Timings::default());
            }
            let started = Instant::now();
            let (secure, stages) = carrier.open_circuit(&peer).await.unwrap();
            let step = Instant::now();
            let hello = service_hello(CircuitService::CmuxTui { port }).unwrap();
            HubCarrier::ask_service(&secure, hello, Duration::from_secs(10))
                .await
                .unwrap()
                .map_err(|r| format!("{r:?}"))
                .unwrap();
            let hello_ms = step.elapsed();
            let step = Instant::now();
            let first = tokio::time::timeout(Duration::from_secs(10), secure.receive())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            let byte_ms = step.elapsed();
            assert!(first.starts_with(b"SSH-"), "{first:?}");
            let total = started.elapsed();
            eprintln!(
                "CARRIER-STAGES run={run} ticket={} relay={} (tcp_alone={}) peer_join={} noise={} \
                 hello={} first_byte={} total={}",
                ms(stages.ticket),
                ms(stages.relay),
                ms(tcp_ms),
                ms(stages.peer_join),
                ms(stages.noise),
                ms(hello_ms),
                ms(byte_ms),
                ms(total),
            );
            let _ = secure.close().await;
        }
    }
}
