//! Noise IK on resume (RFD 0164 B8, `cmux-braid-session`): a link to a daemon the client has met
//! runs IK, so its welcome is back one round trip sooner, and every reconnect saves a round trip
//! per link phase.
//!
//! The handshake tests run on an in-memory link; the reconnect tests on a real daemon behind a
//! link that delays every frame by a fixed one-way latency, so the saving shows up in wall time.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_braid_session::Pattern;
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{
    AuthGrant, AuthRequest, ClientAuthMode, ClientHandshake, ConnectionAttemptId, CryptoError,
    InboundAuthEvidence, NetworkPeer, ServerAuthenticator, ServiceAuthority, StaticIdentity,
    accept_secure_link, initiate_secure_link,
};
use cmux_remote::daemon::{
    DirectWebSocketOptions, RemoteDaemon, serve_direct_websocket_with_options,
};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::provider::{
    CarrierEvidence, ConnectRequest, DirectWebSocketProvider, LinkGroup, LinkRequest,
    ProviderCapabilities, ProviderError, TransportProvider,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
use tokio::sync::{Mutex, mpsc};
use tokio::time::Instant;
use url::Url;

/// One way, so a round trip is 50 ms: a phone on LTE to a Cloud VM, or a coast-to-coast link.
const ONE_WAY: Duration = Duration::from_millis(25);

// ---------------------------------------------------------------------------------------------
// Handshake level.

/// An in-memory link whose frames arrive `delay` after they are sent, in order.
struct DelayedChannel {
    out: mpsc::UnboundedSender<(Instant, Bytes)>,
    inc: Mutex<mpsc::UnboundedReceiver<(Instant, Bytes)>>,
    delay: Duration,
}

fn channel_pair(delay: Duration) -> (DelayedChannel, DelayedChannel) {
    let (a_out, b_in) = mpsc::unbounded_channel();
    let (b_out, a_in) = mpsc::unbounded_channel();
    (
        DelayedChannel { out: a_out, inc: Mutex::new(a_in), delay },
        DelayedChannel { out: b_out, inc: Mutex::new(b_in), delay },
    )
}

#[async_trait]
impl FrameLink for DelayedChannel {
    fn description(&self) -> &str {
        "delayed channel"
    }

    fn maximum_frame_bytes(&self) -> usize {
        65_535
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        self.out.send((Instant::now() + self.delay, frame)).map_err(|_| LinkError::Closed)
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let Some((at, frame)) = self.inc.lock().await.recv().await else { return Ok(None) };
        tokio::time::sleep_until(at).await;
        Ok(Some(frame))
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.inc.lock().await.close();
        Ok(())
    }
}

struct Accept;

#[async_trait]
impl ServerAuthenticator for Accept {
    async fn invitation_secret(&self, _id: &str) -> Result<Option<[u8; 32]>, CryptoError> {
        Ok(None)
    }

    async fn authorize(&self, _request: AuthRequest) -> Result<AuthGrant, String> {
        Ok(AuthGrant {
            device_id: "device".into(),
            daemon_name: "daemon".into(),
            revocation_generation: 0,
            authority: ServiceAuthority::default(),
        })
    }
}

fn handshake(
    client: &StaticIdentity,
    daemon: [u8; 32],
    generation: u64,
    daemon_takes_ik: bool,
) -> ClientHandshake {
    ClientHandshake {
        identity: client.clone(),
        expected_daemon: Some(daemon),
        auth: ClientAuthMode::Carrier,
        device_name: "client".into(),
        session: SessionId([7; 16]),
        lane: Lane::Control,
        lanes: vec![Lane::Control],
        generation,
        connection_attempt: ConnectionAttemptId([3; 16]),
        resume: BTreeMap::new(),
        daemon_takes_ik,
        early: Vec::new(),
        handshake_timeout: Duration::from_secs(5),
    }
}

/// One link: the client's time from its first byte to the daemon's welcome, the pattern it ran,
/// and whether the welcome offered IK. The daemon answers one record with its own.
async fn one_link(
    daemon: &StaticIdentity,
    config: ClientHandshake,
) -> Result<(Duration, Pattern, bool), CryptoError> {
    let (near, far) = channel_pair(ONE_WAY);
    let server = tokio::spawn({
        let daemon = daemon.clone();
        async move {
            let accepted = accept_secure_link(
                Box::new(far),
                &daemon,
                &Accept,
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            )
            .await?;
            let ping = accepted.link.receive().await.unwrap().unwrap();
            accepted.link.send(ping).await.unwrap();
            Ok::<_, CryptoError>(accepted.link.pattern())
        }
    });
    let started = Instant::now();
    let secure = initiate_secure_link(Box::new(near), config).await?;
    let elapsed = started.elapsed();
    secure.send(Bytes::from_static(b"ping")).await.unwrap();
    assert_eq!(&secure.receive().await.unwrap().unwrap()[..], b"ping");
    let daemon_pattern = server.await.unwrap()?;
    assert_eq!(daemon_pattern, secure.pattern(), "both ends ran one pattern");
    Ok((elapsed, secure.pattern(), secure.peer_takes_ik()))
}

#[tokio::test(start_paused = true)]
async fn a_met_daemon_takes_ik_and_its_welcome_is_back_a_round_trip_sooner() {
    let client = StaticIdentity::generate().unwrap();
    let daemon = StaticIdentity::generate().unwrap();
    let key = daemon.public_key();

    // First meeting: XX, the welcome two round trips out, and the daemon offers IK.
    let (xx, pattern, offered) =
        one_link(&daemon, handshake(&client, key, 0, false)).await.unwrap();
    assert_eq!(pattern, Pattern::Xx);
    assert!(offered, "a daemon with IK says so in its welcome");
    // Resume: IK, the hello in the first message, the welcome one round trip out.
    let (ik, pattern, offered) = one_link(&daemon, handshake(&client, key, 1, true)).await.unwrap();
    assert_eq!(pattern, Pattern::Ik);
    assert!(offered);
    let round_trip = ONE_WAY * 2;
    assert_eq!(xx, round_trip * 2, "XX: {xx:?}");
    assert_eq!(ik, round_trip, "IK: {ik:?}");
    eprintln!("welcome after: XX {xx:?}, IK {ik:?} (one way {ONE_WAY:?})");
}

#[tokio::test(start_paused = true)]
async fn ik_is_never_run_without_a_pinned_key_and_never_carries_a_grant() {
    let client = StaticIdentity::generate().unwrap();
    let daemon = StaticIdentity::generate().unwrap();
    let mut unpinned = handshake(&client, daemon.public_key(), 1, true);
    unpinned.expected_daemon = None;
    assert_eq!(one_link(&daemon, unpinned).await.unwrap().1, Pattern::Xx);
    // A first connect's grant rides only XX's forward-secret third message.
    let mut grant = handshake(&client, daemon.public_key(), 0, true);
    grant.auth = ClientAuthMode::Grant { token: zeroize::Zeroizing::new("token".into()) };
    let (near, far) = channel_pair(ONE_WAY);
    let server = tokio::spawn({
        let daemon = daemon.clone();
        async move {
            accept_secure_link(
                Box::new(far),
                &daemon,
                &Accept,
                InboundAuthEvidence::Network(NetworkPeer::Relay),
            )
            .await
            .map(|accepted| accepted.link.pattern())
        }
    });
    let secure = initiate_secure_link(Box::new(near), grant).await.unwrap();
    assert_eq!(secure.pattern(), Pattern::Xx);
    assert_eq!(server.await.unwrap().unwrap(), Pattern::Xx);
}

#[tokio::test(start_paused = true)]
async fn ik_to_the_wrong_key_fails_the_handshake() {
    let client = StaticIdentity::generate().unwrap();
    let daemon = StaticIdentity::generate().unwrap();
    let impostor = StaticIdentity::generate().unwrap();
    let error = one_link(&impostor, handshake(&client, daemon.public_key(), 1, true))
        .await
        .expect_err("an IK link to a daemon without the pinned key was accepted");
    assert!(
        matches!(
            error,
            CryptoError::Noise(_) | CryptoError::LinkError(_) | CryptoError::UnexpectedEof
        ),
        "{error:?}"
    );
}

// ---------------------------------------------------------------------------------------------
// A real daemon.

/// The one-way latency and carrier open cost of a modelled path.
#[derive(Clone, Copy, Debug)]
struct Path {
    one_way: Duration,
    /// Round trips a link's open costs before its first byte: 1 for a direct WebSocket (its
    /// upgrade on a warm connection), 2 for a relay (the socket's upgrade, then `Connect` and the
    /// relay's inline `Ready`).
    open_round_trips: u32,
}

impl Path {
    /// The direct path the B8 numbers were measured on.
    const DIRECT_50: Self = Self { one_way: ONE_WAY, open_round_trips: 1 };

    fn round_trip(self) -> Duration {
        self.one_way * 2
    }

    fn open_cost(self) -> Duration {
        self.round_trip() * self.open_round_trips
    }
}

/// The frames one link's client sent.
type SentFrames = Arc<StdMutex<Vec<Bytes>>>;
/// A delayed frame read: the time it may be delivered, or the link's end or error.
type DelayedRead = Result<Option<(Instant, Bytes)>, LinkError>;

/// A link group that delays every frame by its path's one-way latency each way, charges the
/// path's open cost per open (a carrier dial), and keeps every frame the client sent, per link,
/// for the replay test. While `withhold` is set its links keep what the client sends and deliver
/// none of it: a carrier that died with frames in flight.
struct DelayedGroup {
    inner: Arc<dyn LinkGroup>,
    sent: Sent,
    path: Path,
    withhold: Arc<AtomicBool>,
}

struct DelayedLink {
    inner: Arc<dyn FrameLink>,
    out: mpsc::UnboundedSender<(Instant, Bytes)>,
    inc: Mutex<mpsc::UnboundedReceiver<DelayedRead>>,
    sent: SentFrames,
    one_way: Duration,
    withhold: Arc<AtomicBool>,
}

impl DelayedLink {
    fn new(
        inner: Box<dyn FrameLink>,
        sent: SentFrames,
        one_way: Duration,
        withhold: Arc<AtomicBool>,
    ) -> Self {
        let inner: Arc<dyn FrameLink> = Arc::from(inner);
        let (out, mut to_send) = mpsc::unbounded_channel::<(Instant, Bytes)>();
        tokio::spawn({
            let inner = inner.clone();
            async move {
                while let Some((at, frame)) = to_send.recv().await {
                    tokio::time::sleep_until(at).await;
                    if inner.send(frame).await.is_err() {
                        return;
                    }
                }
            }
        });
        let (arrived, inc) = mpsc::unbounded_channel();
        tokio::spawn({
            let inner = inner.clone();
            async move {
                loop {
                    let next = inner.receive().await;
                    let end = !matches!(next, Ok(Some(_)));
                    let next =
                        next.map(|frame| frame.map(|frame| (Instant::now() + one_way, frame)));
                    if arrived.send(next).is_err() || end {
                        return;
                    }
                }
            }
        });
        Self { inner, out, inc: Mutex::new(inc), sent, one_way, withhold }
    }
}

#[async_trait]
impl FrameLink for DelayedLink {
    fn description(&self) -> &str {
        "delayed"
    }

    fn maximum_frame_bytes(&self) -> usize {
        self.inner.maximum_frame_bytes()
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        self.sent.lock().unwrap().push(frame.clone());
        if self.withhold.load(Ordering::Acquire) {
            return Ok(());
        }
        self.out.send((Instant::now() + self.one_way, frame)).map_err(|_| LinkError::Closed)
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let Some(next) = self.inc.lock().await.recv().await else { return Ok(None) };
        let Some((at, frame)) = next? else { return Ok(None) };
        tokio::time::sleep_until(at).await;
        Ok(Some(frame))
    }

    async fn close(&self) -> Result<(), LinkError> {
        self.inner.close().await
    }
}

#[async_trait]
impl LinkGroup for DelayedGroup {
    fn description(&self) -> &str {
        "delayed"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        self.inner.capabilities()
    }

    fn evidence(&self) -> &CarrierEvidence {
        self.inner.evidence()
    }

    async fn open(&self, request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        tokio::time::sleep(self.path.open_cost()).await;
        let link = self.inner.open(request).await?;
        let sent = Arc::new(StdMutex::new(Vec::new()));
        self.sent.lock().unwrap().push((request, sent.clone()));
        Ok(Box::new(DelayedLink::new(link, sent, self.path.one_way, self.withhold.clone())))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.inner.close().await
    }
}

struct Daemon {
    auth: Arc<AuthDatabase>,
    server: cmux_remote::daemon::DirectWebSocketServer,
    accepted: mpsc::Receiver<Arc<cmux_remote::daemon::ServerConnection>>,
    _state: tempfile::TempDir,
}

async fn daemon() -> Daemon {
    let state = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "ik-resume", false).unwrap();
    let (daemon, accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());
    let server = serve_direct_websocket_with_options(
        daemon,
        "127.0.0.1:0".parse().unwrap(),
        65_535,
        DirectWebSocketOptions { trusted_carrier: true, ..Default::default() },
    )
    .await
    .unwrap();
    Daemon { auth, server, accepted, _state: state }
}

type Sent = Arc<StdMutex<Vec<(LinkRequest, SentFrames)>>>;

async fn group(daemon: &Daemon, session: SessionId, sent: &Sent) -> Arc<dyn LinkGroup> {
    group_on(daemon, session, sent, Path::DIRECT_50, LanePolicy::Isolated).await
}

async fn group_on(
    daemon: &Daemon,
    session: SessionId,
    sent: &Sent,
    path: Path,
    lane_policy: LanePolicy,
) -> Arc<dyn LinkGroup> {
    group_withholding(daemon, session, sent, path, lane_policy, Arc::default()).await
}

async fn group_withholding(
    daemon: &Daemon,
    session: SessionId,
    sent: &Sent,
    path: Path,
    lane_policy: LanePolicy,
    withhold: Arc<AtomicBool>,
) -> Arc<dyn LinkGroup> {
    let endpoint =
        Url::parse(&format!("ws://127.0.0.1:{}/v1/link", daemon.server.local_addr().port()))
            .unwrap();
    let inner = DirectWebSocketProvider::new(65_535)
        .with_carrier_auth(true)
        .connect(ConnectRequest { endpoint, session, lane_policy, routing: Default::default() })
        .await
        .unwrap();
    Arc::new(DelayedGroup { inner, sent: sent.clone(), path, withhold })
}

/// Reconnects on `path`, the time each took, after a first connect. The first redial learns
/// nothing new (the first connect's welcome already offered IK), so every one runs IK.
async fn reconnect_times(
    runs: usize,
    path: Path,
    lane_policy: LanePolicy,
) -> (Duration, Vec<Duration>) {
    let mut daemon = daemon().await;
    let session = SessionId([21; 16]);
    let sent = Sent::default();
    let identity = StaticIdentity::generate().unwrap();
    let started = Instant::now();
    let client = ClientConnection::connect(
        group_on(&daemon, session, &sent, path, lane_policy).await,
        ClientConnectionConfig {
            identity,
            expected_daemon: Some(daemon.auth.identity().public_key()),
            auth: ClientAuthMode::Carrier,
            device_name: "ik-resume-client".into(),
            session,
            lane_policy,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..Default::default() },
        },
    )
    .await
    .unwrap();
    let first = started.elapsed();
    let accepted = daemon.accepted.recv().await.unwrap();
    let mut times = Vec::new();
    for n in 0..runs {
        let replacement = group_on(&daemon, session, &sent, path, lane_policy).await;
        let started = Instant::now();
        client.reconnect(replacement).await.unwrap();
        times.push(started.elapsed());
        let payload = Bytes::from(format!("after {n}"));
        client.send(Lane::Interactive, 1, payload.clone(), FrameFlags::empty()).await.unwrap();
        assert_eq!(accepted.receive().await.unwrap().unwrap().payload, payload);
    }
    client.close().await.unwrap();
    daemon.server.shutdown().await.unwrap();
    (first, times)
}

fn median(times: &mut [Duration]) -> Duration {
    times.sort();
    times[times.len() / 2]
}

/// Before/after for the scoreboard's resume rows: the same harness on the base commit (XX on every
/// link) and on this one. Real sockets, so the numbers carry a little loopback noise on top of the
/// round trips.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reconnect_saves_a_round_trip_per_link_phase() {
    let (first, mut times) = reconnect_times(20, Path::DIRECT_50, LanePolicy::Isolated).await;
    let median = median(&mut times);
    eprintln!(
        "ik-resume one-way {ONE_WAY:?}: first connect {first:?}, reconnect median {median:?} \
         (min {:?}, max {:?}, n {})",
        times[0],
        times[times.len() - 1],
        times.len()
    );
    // A reconnect is an open then each phase's handshake and link-ready, plus the session's own
    // resume exchange. Measured at 25 ms one way: base (XX on every link) median 331 ms, IK 229 ms,
    // one round trip saved per phase.
    // Opening every lane link at once leaves one phase: fleet, 25 ms one way, 208 ms with the
    // two phases and 105 ms with one (an open and the IK exchange; link-ready rides behind the
    // welcome). The bound sits between them.
    assert!(median < ONE_WAY * 6, "reconnect took {median:?}: the lane links did not open at once");
}

/// The before/after rows at 50 and 150 ms round trips, on a direct path (an open is one round
/// trip) and a relay-like one (two), with a Cloud client's `Auto` lanes (three links). Prints one
/// line per row; `CMUX_IK_RESUME_RUNS` sets the reconnects per row (default 8).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn resume_rows_at_50_and_150_ms() {
    let runs =
        std::env::var("CMUX_IK_RESUME_RUNS").ok().and_then(|runs| runs.parse().ok()).unwrap_or(8);
    for one_way in [Duration::from_millis(25), Duration::from_millis(75)] {
        for open_round_trips in [1, 2] {
            let path = Path { one_way, open_round_trips };
            let (first, mut times) = reconnect_times(runs, path, LanePolicy::Auto).await;
            let median = median(&mut times);
            eprintln!(
                "resume-row rtt={:?} open_rtts={open_round_trips} first={first:?} \
                 reconnect_median={median:?} min={:?} max={:?} n={}",
                path.round_trip(),
                times[0],
                times[times.len() - 1],
                times.len()
            );
            // One phase is an open and one round trip (fleet: 105 ms at 50 ms with a one round
            // trip open, 455 ms at 150 ms with two); two phases in a row took twice that.
            let one_phase = path.open_cost() + path.round_trip();
            assert!(median < one_phase + path.round_trip(), "{path:?}: {median:?}");
        }
    }
}

/// A recorded IK resume (prelude and first message) replayed later reaches a daemon that already
/// moved past its generation: it is refused, and the live session never notices.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_replayed_ik_resume_is_refused_and_the_live_session_carries_on() {
    let mut daemon = daemon().await;
    let session = SessionId([22; 16]);
    let sent = Sent::default();
    let identity = StaticIdentity::generate().unwrap();
    let client = ClientConnection::connect(
        group(&daemon, session, &sent).await,
        ClientConnectionConfig {
            identity,
            expected_daemon: Some(daemon.auth.identity().public_key()),
            auth: ClientAuthMode::Carrier,
            device_name: "ik-replay-client".into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..Default::default() },
        },
    )
    .await
    .unwrap();
    let accepted = daemon.accepted.recv().await.unwrap();
    client.reconnect(group(&daemon, session, &sent).await).await.unwrap();
    client.reconnect(group(&daemon, session, &sent).await).await.unwrap();

    // The first link of generation 1: its prelude names IK, and its first message carries the
    // hello. Replay those two frames on a fresh carrier link.
    let (request, frames) = {
        let sent = sent.lock().unwrap();
        let (request, frames) =
            sent.iter().find(|(request, _)| request.generation == 1).expect("a generation-1 link");
        (*request, frames.lock().unwrap().clone())
    };
    let prelude = String::from_utf8_lossy(&frames[0]).into_owned();
    assert!(prelude.contains(r#""pattern":"ik""#), "generation 1 ran IK: {prelude}");
    let raw = group(&daemon, session, &Sent::default()).await;
    let replay = raw.open(request).await.unwrap();
    for frame in &frames[..2] {
        replay.send(frame.clone()).await.unwrap();
    }
    // The daemon may finish the Noise exchange (it cannot tell a replay from msg1 alone), but no
    // session state moves: the replayer holds no keys, and the generation is stale.
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        while let Ok(Some(_)) = replay.receive().await {}
    })
    .await;

    let payload = Bytes::from_static(b"after replay");
    client.send(Lane::Interactive, 1, payload.clone(), FrameFlags::empty()).await.unwrap();
    assert_eq!(accepted.receive().await.unwrap().unwrap().payload, payload);
    assert!(accepted.snapshot().await.generation >= 2);
    client.close().await.unwrap();
    daemon.server.shutdown().await.unwrap();
}

/// Three Control frames the client sent on a carrier that died with them in flight.
fn withheld_payloads() -> Vec<Bytes> {
    (0..3_u8).map(|n| Bytes::from(vec![b'a' + n; 500])).collect()
}

/// What a withheld-then-delivered reconnect showed.
struct Withheld {
    /// From the reconnect's start to the daemon reading the first withheld frame.
    arrival: Duration,
    client: Arc<ClientConnection>,
    accepted: Arc<cmux_remote::daemon::ServerConnection>,
    daemon: Daemon,
    sent: Sent,
    session: SessionId,
}

/// Connects on `path` with a Cloud client's `Auto` lanes, withholds three Control frames on the
/// first carrier, and reconnects. The daemon reads each withheld frame once, in order, and then a
/// frame sent after the reconnect: no copy of any of them in between.
async fn withheld_then_delivered(path: Path, session: SessionId) -> Withheld {
    let mut daemon = daemon().await;
    let sent = Sent::default();
    let withhold = Arc::new(AtomicBool::new(false));
    let client = ClientConnection::connect(
        group_withholding(&daemon, session, &sent, path, LanePolicy::Auto, withhold.clone()).await,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(daemon.auth.identity().public_key()),
            auth: ClientAuthMode::Carrier,
            device_name: "early-data-client".into(),
            session,
            lane_policy: LanePolicy::Auto,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(1), ..Default::default() },
        },
    )
    .await
    .unwrap();
    let accepted = daemon.accepted.recv().await.unwrap();
    withhold.store(true, Ordering::Release);
    let payloads = withheld_payloads();
    for payload in &payloads {
        client.send(Lane::Control, 1, payload.clone(), FrameFlags::empty()).await.unwrap();
    }
    let replacement = group_on(&daemon, session, &sent, path, LanePolicy::Auto).await;
    let started = Instant::now();
    let reconnect = tokio::spawn({
        let client = client.clone();
        async move { client.reconnect(replacement).await }
    });
    let mut arrival = None;
    for payload in &payloads {
        let frame = accepted.receive().await.unwrap().unwrap();
        arrival.get_or_insert_with(|| started.elapsed());
        assert_eq!((frame.lane, &frame.payload), (Lane::Control, payload));
    }
    reconnect.await.unwrap().unwrap();
    let after = Bytes::from_static(b"after the reconnect");
    client.send(Lane::Control, 1, after.clone(), FrameFlags::empty()).await.unwrap();
    assert_eq!(accepted.receive().await.unwrap().unwrap().payload, after, "a duplicate arrived");
    Withheld { arrival: arrival.unwrap(), client, accepted, daemon, sent, session }
}

/// The early-data rows: how long a reconnect takes to put the Control frames a dead carrier
/// withheld in front of the daemon, at 50 and 150 ms round trips. Early data puts them in the
/// Control link's IK hello, so the daemon reads them as the link group commits (an open and half
/// a round trip); after the commit, the replay is a round trip later (link-ready back, the replay
/// out). `CMUX_IK_RESUME_RUNS` sets the runs per row (default 8).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn early_rows_at_50_and_150_ms() {
    let runs =
        std::env::var("CMUX_IK_RESUME_RUNS").ok().and_then(|runs| runs.parse().ok()).unwrap_or(8);
    for one_way in [Duration::from_millis(25), Duration::from_millis(75)] {
        for open_round_trips in [1, 2] {
            let path = Path { one_way, open_round_trips };
            let mut times = Vec::new();
            for _ in 0..runs {
                let run = withheld_then_delivered(path, SessionId([24; 16])).await;
                times.push(run.arrival);
                run.client.close().await.unwrap();
                run.daemon.server.shutdown().await.unwrap();
            }
            let median = median(&mut times);
            eprintln!(
                "early-row rtt={:?} open_rtts={open_round_trips} withheld_control_median={median:?} \
                 min={:?} max={:?} n={}",
                path.round_trip(),
                times[0],
                times[times.len() - 1],
                times.len()
            );
            // Early: the open and half a round trip. After the commit: the open and a round trip
            // and a half. The bound sits between them.
            assert!(median < path.open_cost() + path.round_trip(), "{path:?}: {median:?}");
        }
    }
}

/// The early first flight, recorded and replayed: once the session has moved past its
/// generation the daemon refuses it, and nothing it carried reaches the session again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_replayed_early_first_flight_delivers_nothing_twice() {
    let run = withheld_then_delivered(Path::DIRECT_50, SessionId([25; 16])).await;
    // The generation-1 Control link's IK hello carried the withheld frames; the Interactive
    // link's, at the same generation, carried none.
    let first_message = |lane: Lane| {
        let sent = run.sent.lock().unwrap();
        let (request, frames) = sent
            .iter()
            .find(|(request, _)| request.generation == 1 && request.lane == lane)
            .expect("a generation-1 link");
        (*request, frames.lock().unwrap()[..2].to_vec())
    };
    let (control, flight) = first_message(Lane::Control);
    let (_, interactive) = first_message(Lane::Interactive);
    assert!(
        flight[1].len() > interactive[1].len() + 1_500,
        "the Control hello carried no early data: {} vs {} bytes",
        flight[1].len(),
        interactive[1].len()
    );
    // Stale generation: the session moves on, then the first flight comes again.
    run.client
        .reconnect(
            group_on(&run.daemon, run.session, &Sent::default(), Path::DIRECT_50, LanePolicy::Auto)
                .await,
        )
        .await
        .unwrap();
    let raw =
        group_on(&run.daemon, run.session, &Sent::default(), Path::DIRECT_50, LanePolicy::Auto)
            .await;
    let replay = raw.open(control).await.unwrap();
    for frame in &flight {
        replay.send(frame.clone()).await.unwrap();
    }
    let _ = tokio::time::timeout(Duration::from_secs(2), async {
        while let Ok(Some(_)) = replay.receive().await {}
    })
    .await;
    let payload = Bytes::from_static(b"after the replayed flight");
    run.client.send(Lane::Control, 1, payload.clone(), FrameFlags::empty()).await.unwrap();
    assert_eq!(
        run.accepted.receive().await.unwrap().unwrap().payload,
        payload,
        "the replayed flight delivered something again"
    );
    run.client.close().await.unwrap();
    run.daemon.server.shutdown().await.unwrap();
}
