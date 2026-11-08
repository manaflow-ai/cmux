#![cfg(unix)]
//! The single redialer's contract (cmuxterm-hq#7766, PR 1), on a paused clock with the real
//! `RemoteDaemon` and `ClientConnection` over in-memory links:
//!
//! - every redial spends from one token bucket, so a link that dies right after each
//!   reconnect cannot dial faster than the budget's refill;
//! - a silent link is declared dead within 6 s (a 2 s probe answered within 4 s);
//! - an action's deadline bounds the recovery it waits on;
//! - a parked link redials at once on a network change, and a dial hung on the old network
//!   is dropped for a new one;
//! - a dead link's first redial goes at once.
//!
//! Run (from `cmux-tui/`): `cargo test -p cmux-remote --test redial_budget_e2e`.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectPolicy,
};
use cmux_remote::crypto::{ClientAuthMode, NetworkPeer, StaticIdentity};
use cmux_remote::daemon::{DaemonSessionPolicy, InboundLink, RemoteDaemon};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{
    CarrierEvidence, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{LanePolicy, SessionId};
use tempfile::TempDir;
use tokio::sync::watch;
use tokio::time::Instant;

const MAXIMUM_FRAME_BYTES: usize = 65_535;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// One direction of one in-memory link.
#[derive(Default)]
struct Pipe {
    state: Mutex<PipeState>,
    changed: watch::Sender<u64>,
}

#[derive(Default)]
struct PipeState {
    queue: VecDeque<Bytes>,
    cut: bool,
    finished: bool,
}

impl Pipe {
    fn poke(&self) {
        self.changed.send_modify(|n| *n = n.wrapping_add(1));
    }

    fn cut(&self) {
        {
            let mut s = lock(&self.state);
            s.cut = true;
            s.queue.clear();
        }
        self.poke();
    }
}

struct MemLink {
    out: Arc<Pipe>,
    inc: Arc<Pipe>,
    /// While set, frames are swallowed: the network is gone but no socket says so.
    silent: Arc<AtomicBool>,
}

#[async_trait]
impl FrameLink for MemLink {
    fn description(&self) -> &str {
        "memory link"
    }

    fn maximum_frame_bytes(&self) -> usize {
        MAXIMUM_FRAME_BYTES
    }

    async fn send(&self, frame: Bytes) -> Result<(), LinkError> {
        {
            let mut s = lock(&self.out.state);
            if s.cut {
                return Err(LinkError::Transport("memory link cut".into()));
            }
            if s.finished {
                return Err(LinkError::Closed);
            }
            if self.silent.load(Ordering::Acquire) {
                return Ok(());
            }
            s.queue.push_back(frame);
        }
        self.out.poke();
        Ok(())
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let mut changed = self.inc.changed.subscribe();
        loop {
            {
                let mut s = lock(&self.inc.state);
                if s.cut {
                    return Err(LinkError::Transport("memory link cut".into()));
                }
                if let Some(frame) = s.queue.pop_front() {
                    return Ok(Some(frame));
                }
                if s.finished {
                    return Ok(None);
                }
            }
            changed.borrow_and_update();
            if changed.changed().await.is_err() {
                return Ok(None);
            }
        }
    }

    async fn close(&self) -> Result<(), LinkError> {
        lock(&self.out.state).finished = true;
        self.out.poke();
        self.inc.cut();
        Ok(())
    }
}

/// The carrier: each dial is logged, and the test can refuse, hang, silence or cut links.
struct TestGroup {
    daemon: Arc<RemoteDaemon>,
    evidence: CarrierEvidence,
    /// New dials fail at once (no route).
    down: AtomicBool,
    /// New dials never answer (a dial on a network that went away).
    hang: AtomicBool,
    /// Every link opened from now on is cut this long after it opens.
    flap_after: Mutex<Option<Duration>>,
    silent: Arc<AtomicBool>,
    links: Mutex<Vec<(Arc<Pipe>, Arc<Pipe>)>>,
    dials: Mutex<Vec<Instant>>,
}

impl TestGroup {
    fn dials_since(&self, since: Instant) -> usize {
        lock(&self.dials).iter().filter(|at| **at >= since).count()
    }

    fn first_dial_since(&self, since: Instant) -> Option<Instant> {
        lock(&self.dials).iter().copied().find(|at| *at >= since)
    }

    fn cut_all(&self) {
        for (up, down) in std::mem::take(&mut *lock(&self.links)) {
            up.cut();
            down.cut();
        }
    }
}

#[async_trait]
impl LinkGroup for TestGroup {
    fn description(&self) -> &str {
        "test carrier"
    }

    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities::MULTI_STREAM
    }

    fn evidence(&self) -> &CarrierEvidence {
        &self.evidence
    }

    async fn open(&self, _request: LinkRequest) -> Result<Box<dyn FrameLink>, ProviderError> {
        lock(&self.dials).push(Instant::now());
        if self.hang.load(Ordering::Acquire) {
            std::future::pending::<()>().await;
        }
        if self.down.load(Ordering::Acquire) {
            return Err(ProviderError::Link(LinkError::Transport("no route to host".into())));
        }
        let up = Arc::new(Pipe::default());
        let down = Arc::new(Pipe::default());
        lock(&self.links).push((up.clone(), down.clone()));
        if let Some(after) = *lock(&self.flap_after) {
            let (up, down) = (up.clone(), down.clone());
            tokio::spawn(async move {
                tokio::time::sleep(after).await;
                up.cut();
                down.cut();
            });
        }
        let client = MemLink { out: up.clone(), inc: down.clone(), silent: self.silent.clone() };
        let server = MemLink { out: down, inc: up, silent: self.silent.clone() };
        let daemon = self.daemon.clone();
        tokio::spawn(async move {
            let _ = daemon
                .accept(InboundLink::trusted_network(Box::new(server), NetworkPeer::Relay))
                .await;
        });
        Ok(Box::new(client))
    }

    async fn close(&self) -> Result<(), ProviderError> {
        Ok(())
    }
}

struct Harness {
    _dir: TempDir,
    group: Arc<TestGroup>,
    client: Arc<ClientConnection>,
}

async fn harness(reconnect: ReconnectPolicy) -> Harness {
    let dir = TempDir::new().unwrap();
    let auth = AuthDatabase::load_or_create(dir.path(), "redial-budget", false).unwrap();
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
    let expected = daemon.auth().identity().public_key();
    let group = Arc::new(TestGroup {
        daemon,
        evidence: CarrierEvidence::Relay { provider: "test".into() },
        down: AtomicBool::new(false),
        hang: AtomicBool::new(false),
        flap_after: Mutex::new(None),
        silent: Arc::new(AtomicBool::new(false)),
        links: Mutex::new(Vec::new()),
        dials: Mutex::new(Vec::new()),
    });
    let client = ClientConnection::connect(
        group.clone(),
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(expected),
            auth: ClientAuthMode::Carrier,
            device_name: "redial-budget".into(),
            session: SessionId([7; 16]),
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect,
        },
    )
    .await
    .unwrap();
    // The app's reader: always wants the link, as the service multiplexer does.
    let reader = client.clone();
    tokio::spawn(async move { while let Ok(Some(_)) = reader.receive().await {} });
    Harness { _dir: dir, group, client }
}

fn policy() -> ReconnectPolicy {
    // Jitter off so every run is one schedule.
    ReconnectPolicy { full_jitter: false, ..ReconnectPolicy::default() }
}

async fn wait_state(client: &ClientConnection, want: ConnectionState, within: Duration) -> bool {
    let mut state = client.subscribe_state();
    tokio::time::timeout(within, state.wait_for(|state| *state == want)).await.is_ok()
}

/// A link that comes up and dies again right away (a flapping carrier) must not make the
/// connection dial as fast as each reconnect succeeds: every redial spends a token, and
/// tokens come back one per 2 s. The old code cleared its backoff on every success and so
/// redialed at once, every time.
#[tokio::test(start_paused = true)]
async fn a_flapping_link_dials_no_faster_than_the_budget() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    *lock(&h.group.flap_after) = Some(Duration::from_millis(50));
    let start = Instant::now();
    h.group.cut_all();
    tokio::time::sleep(Duration::from_secs(60)).await;
    let dials = h.group.dials_since(start);
    // capacity 4 + one token per 2 s over 60 s.
    assert!(dials <= 4 + 30, "{dials} dials in 60 s; the budget allows 34");
    assert!(dials >= 20, "{dials} dials in 60 s; a budgeted link still redials");
}

/// A link that goes silent (frames vanish, no socket error) is declared dead and redialed
/// within 6 s. The old 5 s probe and 15 s answer window took up to 20 s.
#[tokio::test(start_paused = true)]
async fn a_silent_link_is_redialed_within_6_s() {
    let h = harness(policy()).await;
    // Let the first probe pass so the silence starts at a random point of the interval.
    tokio::time::sleep(Duration::from_millis(2_100)).await;
    let start = Instant::now();
    h.group.silent.store(true, Ordering::Release);
    tokio::time::sleep(Duration::from_secs(30)).await;
    let first = h.group.first_dial_since(start).expect("the silent link was never redialed");
    let took = first - start;
    assert!(took <= Duration::from_secs(6), "a silent link took {took:?} to be declared dead");
}

/// An action passes its deadline; the recovery it waits on ends by then with the typed
/// answer, however long the outage lasts. The link itself keeps trying afterwards.
#[tokio::test(start_paused = true)]
async fn an_action_deadline_bounds_the_recovery() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    h.group.down.store(true, Ordering::Release);
    h.group.cut_all();
    // The reader sees the cut and starts the link's own recovery.
    tokio::time::sleep(Duration::from_millis(1)).await;
    let start = Instant::now();
    let deadline = start + Duration::from_millis(1_500);
    let result = h.client.await_ready(deadline).await;
    assert!(matches!(result, Err(ConnectionError::ReconnectDeadlineExceeded { .. })), "{result:?}");
    assert!(Instant::now() <= deadline, "the answer came {:?} late", Instant::now() - deadline);
    // The link did not give up: it redials once the network is back.
    h.group.down.store(false, Ordering::Release);
    h.client.network_changed();
    assert!(wait_state(&h.client, ConnectionState::Connected, Duration::from_secs(1)).await);
    assert!(h.client.await_ready(Instant::now() + Duration::from_secs(1)).await.is_ok());
}

/// After a burst fails the link parks; a network change wakes it at once instead of at the
/// end of its 5 s park.
#[tokio::test(start_paused = true)]
async fn a_parked_link_redials_on_a_network_change() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    let start = Instant::now();
    h.group.down.store(true, Ordering::Release);
    h.group.cut_all();
    // The burst (at once, then 150 ms and 600 ms later) has failed; the link is parked.
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(*h.client.subscribe_state().borrow(), ConnectionState::Disconnected);
    assert_eq!(h.group.dials_since(start), 3);
    h.group.down.store(false, Ordering::Release);
    let changed = Instant::now();
    h.client.network_changed();
    assert!(wait_state(&h.client, ConnectionState::Connected, Duration::from_secs(5)).await);
    let took = changed.elapsed();
    assert!(took < Duration::from_millis(100), "reconnected {took:?} after the network change");
}

/// A dial hung on the network that went away is dropped and dialed again when the network
/// changes, instead of waiting out its 15 s attempt timeout.
#[tokio::test(start_paused = true)]
async fn a_network_change_drops_a_hung_dial() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    h.group.hang.store(true, Ordering::Release);
    h.group.cut_all();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(*h.client.subscribe_state().borrow(), ConnectionState::Reconnecting);
    h.group.hang.store(false, Ordering::Release);
    let changed = Instant::now();
    h.client.network_changed();
    assert!(wait_state(&h.client, ConnectionState::Connected, Duration::from_secs(20)).await);
    let took = changed.elapsed();
    assert!(took < Duration::from_millis(100), "reconnected {took:?} after the network change");
}

/// A healthy link that dies is redialed at once, not after a backoff.
#[tokio::test(start_paused = true)]
async fn a_dead_link_redials_at_once() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(30)).await;
    let mut generation = h.client.subscribe_generation();
    let before = *generation.borrow_and_update();
    let start = Instant::now();
    h.group.cut_all();
    tokio::time::timeout(Duration::from_secs(5), generation.wait_for(|g| *g != before))
        .await
        .expect("the dead link was not reconnected")
        .unwrap();
    let first = h.group.first_dial_since(start).expect("no redial");
    assert!(first - start < Duration::from_millis(10), "first redial after {:?}", first - start);
}
