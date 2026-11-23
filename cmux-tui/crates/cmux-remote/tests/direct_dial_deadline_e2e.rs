//! A direct WebSocket dial and the first connect above it end within a bound, whatever the
//! carrier does: a dial that never connects, a socket that accepts and never finishes the
//! upgrade, a carrier whose open never returns, a peer that goes silent right after the upgrade,
//! and a link that dies right after the connect. Each of the first four used to hold the caller
//! forever (no deadline covered the dial or the carrier's open); the last is the heartbeat's
//! bound on a link that is already up, checked here on the direct path right after open.
//!
//! The carrier is in memory (`tokio::io::duplex`) behind a test [`Dialer`], so the clock is
//! paused and every bound is checked exactly, in no wall time. One test dials a real TCP
//! listener to check the same bound over the operating system's stack.

use std::fmt;
use std::io;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use async_trait::async_trait;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectPolicy,
};
use cmux_remote::crypto::{ClientAuthMode, NetworkPeer, StaticIdentity};
use cmux_remote::daemon::{DaemonSessionPolicy, InboundLink, RemoteDaemon};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{
    CarrierEvidence, ConnectRequest, DIRECT_DIAL_TIMEOUT, DialedStream, Dialer,
    DirectWebSocketProvider, LinkGroup, LinkRequest, OsTcpDialer, ProviderCapabilities,
    ProviderError, TransportProvider, TungsteniteWebSocketLink, connect_websocket_via,
    connect_websocket_within,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
use tempfile::TempDir;
use tokio::io::{AsyncRead, AsyncWrite, DuplexStream, ReadBuf};
use tokio::time::Instant;
use url::Url;

const MAXIMUM: usize = 65_535;
/// Far past every bound under test: reaching it means the call hung, as it did before.
const WATCHDOG: Duration = Duration::from_secs(600);
const HOST: &str = "cold-machine.invalid";

/// What the far end of a test dial does.
#[derive(Clone)]
enum Peer {
    /// The connect itself never finishes (a black-holed SYN, a tunnel with no handshake).
    NeverConnects,
    /// The connect finishes and the peer never answers the upgrade.
    SilentAfterConnect,
    /// The upgrade finishes and the peer never speaks again.
    SilentAfterUpgrade,
    /// A real daemon behind the upgrade.
    Daemon(Arc<RemoteDaemon>),
}

/// A [`Dialer`] whose bytes run over an in-memory pipe, with a switch that freezes every stream
/// it made: reads never return and writes vanish, as a peer that dropped off the network does.
struct TestDialer {
    peer: Peer,
    frozen: Arc<AtomicBool>,
    /// Far ends kept open, so a silent peer is silent rather than closed.
    held: Mutex<Vec<DuplexStream>>,
}

impl TestDialer {
    fn new(peer: Peer) -> Arc<Self> {
        Arc::new(Self { peer, frozen: Arc::default(), held: Mutex::default() })
    }
}

impl fmt::Debug for TestDialer {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("TestDialer")
    }
}

#[async_trait]
impl Dialer for TestDialer {
    fn name(&self) -> &'static str {
        "test"
    }

    async fn dial(&self, _host: &str, _port: u16) -> Result<DialedStream, LinkError> {
        let (near, far) = tokio::io::duplex(1 << 20);
        match &self.peer {
            Peer::NeverConnects => std::future::pending().await,
            Peer::SilentAfterConnect => self.held.lock().unwrap().push(far),
            Peer::SilentAfterUpgrade => {
                tokio::spawn(async move {
                    let socket = tokio_tungstenite::accept_async(far).await.unwrap();
                    std::future::pending::<()>().await;
                    drop(socket);
                });
            }
            Peer::Daemon(daemon) => {
                let daemon = daemon.clone();
                tokio::spawn(async move {
                    let socket = tokio_tungstenite::accept_async(far).await.unwrap();
                    let link = TungsteniteWebSocketLink::new("test daemon side", MAXIMUM, socket);
                    let _ = daemon
                        .accept(InboundLink::trusted_network(Box::new(link), NetworkPeer::Tcp))
                        .await;
                });
            }
        }
        Ok(Box::new(Freezable { inner: near, frozen: self.frozen.clone() }))
    }
}

struct Freezable {
    inner: DuplexStream,
    frozen: Arc<AtomicBool>,
}

impl AsyncRead for Freezable {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        if self.frozen.load(Ordering::Acquire) {
            return Poll::Pending;
        }
        Pin::new(&mut self.inner).poll_read(cx, buf)
    }
}

impl AsyncWrite for Freezable {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        if self.frozen.load(Ordering::Acquire) {
            return Poll::Ready(Ok(buf.len()));
        }
        Pin::new(&mut self.inner).poll_write(cx, buf)
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.frozen.load(Ordering::Acquire) {
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        if self.frozen.load(Ordering::Acquire) {
            return Poll::Ready(Ok(()));
        }
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

fn endpoint() -> Url {
    Url::parse(&format!("ws://{HOST}/v1/link")).unwrap()
}

fn config(session: SessionId, reconnect: ReconnectPolicy) -> ClientConnectionConfig {
    ClientConnectionConfig {
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Carrier,
        device_name: "direct-dial-deadline".into(),
        session,
        lane_policy: LanePolicy::Single,
        limits: SessionLimits::default(),
        reconnect,
    }
}

async fn direct_group(dialer: Arc<TestDialer>, session: SessionId) -> Arc<dyn LinkGroup> {
    DirectWebSocketProvider::with_dialer(MAXIMUM, dialer)
        .with_carrier_auth(true)
        .connect(ConnectRequest {
            endpoint: endpoint(),
            session,
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap()
}

/// The first connect's result and how long it took, or a panic at [`WATCHDOG`].
async fn first_connect(
    group: Arc<dyn LinkGroup>,
    session: SessionId,
) -> (Result<Arc<ClientConnection>, ConnectionError>, Duration) {
    let started = Instant::now();
    let result = tokio::time::timeout(
        WATCHDOG,
        ClientConnection::connect(group, config(session, ReconnectPolicy::default())),
    )
    .await
    .unwrap_or_else(|_| panic!("the first connect still hung after {WATCHDOG:?}"));
    (result, started.elapsed())
}

fn transport_reason(error: &LinkError) -> &str {
    match error {
        LinkError::Transport(reason) => reason,
        other => panic!("expected a retryable transport error, got {other}"),
    }
}

/// A dial whose connect never finishes ends at the dial's bound and says which stage stalled.
#[tokio::test(start_paused = true)]
async fn a_dial_that_never_connects_fails_at_the_bound_naming_the_stage() {
    let dialer = TestDialer::new(Peer::NeverConnects);
    let started = Instant::now();
    let error =
        tokio::time::timeout(WATCHDOG, connect_websocket_via(&endpoint(), MAXIMUM, &*dialer))
            .await
            .expect("the dial still hung")
            .expect_err("a dial that never connects succeeded");
    assert_eq!(started.elapsed(), DIRECT_DIAL_TIMEOUT);
    assert_eq!(
        transport_reason(&error),
        format!("test connect to {HOST}:80 did not finish within 12 s")
    );
}

/// A peer that accepts the connect and never answers the upgrade (hang mid-open) ends at the
/// same bound, and the error names the upgrade and the peer.
#[tokio::test(start_paused = true)]
async fn an_upgrade_that_never_finishes_fails_at_the_bound_naming_the_stage() {
    let dialer = TestDialer::new(Peer::SilentAfterConnect);
    let started = Instant::now();
    let error =
        tokio::time::timeout(WATCHDOG, connect_websocket_via(&endpoint(), MAXIMUM, &*dialer))
            .await
            .expect("the dial still hung")
            .expect_err("an upgrade nobody answered succeeded");
    assert_eq!(started.elapsed(), DIRECT_DIAL_TIMEOUT);
    assert_eq!(
        transport_reason(&error),
        format!("websocket upgrade to {HOST}:80 did not finish within 12 s")
    );
}

/// The same hang over a real TCP listener that accepts and never answers the upgrade. A short
/// bound keeps the wall time small; the default bound is checked in paused time above.
#[tokio::test]
async fn a_tcp_listener_that_accepts_and_never_upgrades_fails_within_the_bound() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let held = tokio::spawn(async move {
        let mut accepted = Vec::new();
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            accepted.push(stream);
        }
    });
    let endpoint = Url::parse(&format!("ws://{address}/v1/link")).unwrap();
    let bound = Duration::from_millis(500);
    let started = std::time::Instant::now();
    let error = tokio::time::timeout(
        Duration::from_secs(30),
        connect_websocket_within(&endpoint, MAXIMUM, &OsTcpDialer, bound),
    )
    .await
    .expect("the dial still hung")
    .expect_err("an upgrade nobody answered succeeded");
    let took = started.elapsed();
    assert!(took >= bound, "the dial gave up before its bound, after {took:?}");
    assert!(took < bound + Duration::from_secs(5), "the dial took {took:?} past a {bound:?} bound");
    assert_eq!(
        transport_reason(&error),
        format!("websocket upgrade to {address} did not finish within 500 ms")
    );
    held.abort();
}

/// The first connect over a direct route whose upgrade never finishes fails with the stage
/// named, instead of hanging: nothing above the dial had a deadline before.
#[tokio::test(start_paused = true)]
async fn a_first_connect_whose_upgrade_hangs_fails_naming_the_stage() {
    let session = SessionId([41; 16]);
    let group = direct_group(TestDialer::new(Peer::SilentAfterConnect), session).await;
    let (result, took) = first_connect(group, session).await;
    let error = result.expect_err("a first connect over a hung upgrade succeeded");
    assert_eq!(took, DIRECT_DIAL_TIMEOUT);
    assert!(error.is_retryable_carrier_failure(), "{error}");
    assert!(
        error
            .to_string()
            .contains(&format!("websocket upgrade to {HOST}:80 did not finish within 12 s")),
        "{error}"
    );
}

/// A carrier whose open never returns (any provider, whatever its own bounds) fails the first
/// connect at the attempt's timeout: the attempt clock starts before the open now.
#[tokio::test(start_paused = true)]
async fn a_first_connect_whose_carrier_open_hangs_fails_at_the_attempt_timeout() {
    struct HangingGroup(CarrierEvidence);

    #[async_trait]
    impl LinkGroup for HangingGroup {
        fn description(&self) -> &str {
            "hanging carrier"
        }

        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities::WEBSOCKET
        }

        fn evidence(&self) -> &CarrierEvidence {
            &self.0
        }

        async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
            std::future::pending().await
        }

        async fn close(&self) -> Result<(), ProviderError> {
            Ok(())
        }
    }

    let session = SessionId([42; 16]);
    let group = Arc::new(HangingGroup(CarrierEvidence::None));
    let (result, took) = first_connect(group, session).await;
    let error = result.expect_err("a first connect over a hung open succeeded");
    let attempt = ReconnectPolicy::default().attempt_timeout;
    assert_eq!(took, attempt);
    assert!(error.is_retryable_carrier_failure(), "{error}");
    assert!(error.to_string().contains("on hanging carrier did not finish within 15 s"), "{error}");
}

/// A peer that finishes the upgrade and then never speaks fails the first connect at the
/// attempt's timeout, counted from the start of the open.
#[tokio::test(start_paused = true)]
async fn a_first_connect_silent_after_the_upgrade_fails_at_the_attempt_timeout() {
    let session = SessionId([43; 16]);
    let group = direct_group(TestDialer::new(Peer::SilentAfterUpgrade), session).await;
    let (result, took) = first_connect(group, session).await;
    let error = result.expect_err("a first connect to a silent peer succeeded");
    let attempt = ReconnectPolicy::default().attempt_timeout;
    assert!(took <= attempt, "a first connect to a silent peer took {took:?}");
    assert!(error.is_retryable_carrier_failure(), "{error}");
}

/// A direct link that dies right after the first connect (frames vanish, no socket error) is
/// declared dead within one heartbeat interval plus its answer window.
#[tokio::test(start_paused = true)]
async fn a_direct_link_dead_right_after_open_is_detected_within_the_heartbeat_bound() {
    let dir = TempDir::new().unwrap();
    let auth = AuthDatabase::load_or_create(dir.path(), "direct-dial-deadline", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::with_policy(
        auth,
        SessionLimits::default(),
        DaemonSessionPolicy { resume_lease: Duration::from_secs(600) },
    )
    .unwrap();
    // The daemon's application reads every session, which answers heartbeats.
    tokio::spawn(async move {
        while let Some(connection) = accepted.recv().await {
            tokio::spawn(async move { while let Ok(Some(_)) = connection.receive().await {} });
        }
    });
    let dialer = TestDialer::new(Peer::Daemon(daemon));
    let session = SessionId([44; 16]);
    let group = direct_group(dialer.clone(), session).await;
    let (client, _) = first_connect(group, session).await;
    let client = client.expect("the first connect to a live daemon failed");
    let reader = client.clone();
    tokio::spawn(async move { while let Ok(Some(_)) = reader.receive().await {} });

    let mut state = client.subscribe_state();
    assert_eq!(*state.borrow_and_update(), ConnectionState::Connected);
    dialer.frozen.store(true, Ordering::Release);
    let died = Instant::now();
    tokio::time::timeout(WATCHDOG, state.wait_for(|state| *state != ConnectionState::Connected))
        .await
        .expect("a dead direct link was never noticed")
        .unwrap();
    let took = died.elapsed();
    let policy = ReconnectPolicy::default();
    let bound = policy.heartbeat_interval.unwrap() + policy.heartbeat_timeout;
    assert!(took <= bound, "a direct link dead right after open took {took:?} to notice");
    client.close().await.ok();
}
