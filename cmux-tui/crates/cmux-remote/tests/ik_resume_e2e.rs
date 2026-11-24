//! Noise IK on resume (RFD 0164 B8, `cmux-braid-session`): a link to a daemon the client has met
//! runs IK, so its welcome is back one round trip sooner, and every reconnect saves a round trip
//! per link phase.
//!
//! The handshake tests run on an in-memory link; the reconnect tests on a real daemon behind a
//! link that delays every frame by a fixed one-way latency, so the saving shows up in wall time.

use std::collections::BTreeMap;
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

/// A link group that delays every frame by [`ONE_WAY`] each way, charges a round trip per open
/// (a carrier dial), and keeps every frame the client sent, per link, for the replay test.
/// The frames one link's client sent.
type SentFrames = Arc<StdMutex<Vec<Bytes>>>;
/// A delayed frame read: the time it may be delivered, or the link's end or error.
type DelayedRead = Result<Option<(Instant, Bytes)>, LinkError>;

struct DelayedGroup {
    inner: Arc<dyn LinkGroup>,
    sent: Arc<StdMutex<Vec<(LinkRequest, SentFrames)>>>,
}

struct DelayedLink {
    inner: Arc<dyn FrameLink>,
    out: mpsc::UnboundedSender<(Instant, Bytes)>,
    inc: Mutex<mpsc::UnboundedReceiver<DelayedRead>>,
    sent: Arc<StdMutex<Vec<Bytes>>>,
}

impl DelayedLink {
    fn new(inner: Box<dyn FrameLink>, sent: Arc<StdMutex<Vec<Bytes>>>) -> Self {
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
                        next.map(|frame| frame.map(|frame| (Instant::now() + ONE_WAY, frame)));
                    if arrived.send(next).is_err() || end {
                        return;
                    }
                }
            }
        });
        Self { inner, out, inc: Mutex::new(inc), sent }
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
        self.out.send((Instant::now() + ONE_WAY, frame)).map_err(|_| LinkError::Closed)
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
        tokio::time::sleep(ONE_WAY * 2).await;
        let link = self.inner.open(request).await?;
        let sent = Arc::new(StdMutex::new(Vec::new()));
        self.sent.lock().unwrap().push((request, sent.clone()));
        Ok(Box::new(DelayedLink::new(link, sent)))
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

type Sent = Arc<StdMutex<Vec<(LinkRequest, Arc<StdMutex<Vec<Bytes>>>)>>>;

async fn group(daemon: &Daemon, session: SessionId, sent: &Sent) -> Arc<dyn LinkGroup> {
    let endpoint =
        Url::parse(&format!("ws://127.0.0.1:{}/v1/link", daemon.server.local_addr().port()))
            .unwrap();
    let inner = DirectWebSocketProvider::new(65_535)
        .with_carrier_auth(true)
        .connect(ConnectRequest {
            endpoint,
            session,
            lane_policy: LanePolicy::Isolated,
            routing: Default::default(),
        })
        .await
        .unwrap();
    Arc::new(DelayedGroup { inner, sent: sent.clone() })
}

/// Reconnects at [`ONE_WAY`], the time each took, after a first connect. The first redial learns
/// nothing new (the first connect's welcome already offered IK), so every one runs IK.
async fn reconnect_times(runs: usize) -> (Duration, Vec<Duration>) {
    let mut daemon = daemon().await;
    let session = SessionId([21; 16]);
    let sent = Sent::default();
    let identity = StaticIdentity::generate().unwrap();
    let started = Instant::now();
    let client = ClientConnection::connect(
        group(&daemon, session, &sent).await,
        ClientConnectionConfig {
            identity,
            expected_daemon: Some(daemon.auth.identity().public_key()),
            auth: ClientAuthMode::Carrier,
            device_name: "ik-resume-client".into(),
            session,
            lane_policy: LanePolicy::Isolated,
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
        let replacement = group(&daemon, session, &sent).await;
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
    let (first, mut times) = reconnect_times(20).await;
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
    // one round trip saved per phase. The bound sits between the two: XX on either phase lands
    // above it.
    assert!(median < ONE_WAY * 11, "reconnect took {median:?}: IK did not take");
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
