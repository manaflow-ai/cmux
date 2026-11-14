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
//! - a dead link's first redial goes at once;
//! - a send's deadline holds while another send owns its lane through a recovery;
//! - `await_ready` does not wait out a replay that holds the session lock;
//! - a network change drops a transport discovery hung on the old network;
//! - a heartbeat probe reads its own answer when the reader it waited on is cancelled;
//! - a network change interrupts a write stuck on the old route;
//! - a network change made before the watch is forwarded still reaches the link;
//! - the link's own socket answers its state, and a wait by the caller's deadline;
//! - a network change while a heartbeat probe is already blocked shortens that probe;
//! - every failed redial, a gone session too, is the reason the link reports;
//! - a first connect whose link open never resolves fails at the attempt timeout.
//!
//! Run (from `cmux-tui/`): `cargo test -p cmux-remote --test redial_budget_e2e`.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::admin::{AdminRequest, LinkStatus, call_admin, serve_link_admin};
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ConnectionError, ReconnectGroupSource,
    ReconnectPolicy,
};
use cmux_remote::crypto::{ClientAuthMode, CryptoError, NetworkPeer, StaticIdentity};
use cmux_remote::daemon::{DaemonSessionPolicy, InboundLink, RemoteDaemon};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::network_watch::{self, NetworkWatch};
use cmux_remote::observability::ConnectionState;
use cmux_remote::provider::{
    CarrierEvidence, LinkGroup, LinkRequest, ProviderCapabilities, ProviderError,
};
use cmux_remote::session::SessionLimits;
use cmux_remote_protocol::{FrameFlags, Lane, LanePolicy, SessionId};
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
    /// While set this direction is frozen, as a dead route is: a send waits without failing,
    /// nothing arrives, and a close from the far end is not heard until it thaws.
    held: bool,
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

    fn hold(&self, held: bool) {
        lock(&self.state).held = held;
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
        let mut changed = self.out.changed.subscribe();
        loop {
            changed.borrow_and_update();
            {
                let mut s = lock(&self.out.state);
                if !s.held {
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
                    break;
                }
            }
            if changed.changed().await.is_err() {
                return Err(LinkError::Closed);
            }
        }
        self.out.poke();
        Ok(())
    }

    async fn receive(&self) -> Result<Option<Bytes>, LinkError> {
        let mut changed = self.inc.changed.subscribe();
        loop {
            // Seen before the state is read, so no poke between the two is lost.
            changed.borrow_and_update();
            {
                let mut s = lock(&self.inc.state);
                if !s.held {
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
            }
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

    /// Freeze or thaw every open link: `up` the client's sends, `down` the daemon's.
    fn freeze(&self, up: bool, down: bool) {
        for (to_daemon, to_client) in lock(&self.links).iter() {
            to_daemon.hold(up);
            to_client.hold(down);
        }
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

/// Transport discovery after a failed redial: hands back the same carrier, or hangs (a relay
/// or peer dial on a network that went away).
struct TestSource {
    group: Arc<TestGroup>,
    hang: AtomicBool,
    calls: AtomicUsize,
}

#[async_trait]
impl ReconnectGroupSource for TestSource {
    async fn next_group(&self) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        if self.hang.load(Ordering::Acquire) {
            std::future::pending::<()>().await;
        }
        Ok(self.group.clone())
    }
}

struct Harness {
    _dir: TempDir,
    group: Arc<TestGroup>,
    source: Option<Arc<TestSource>>,
    client: Arc<ClientConnection>,
}

async fn harness(reconnect: ReconnectPolicy) -> Harness {
    harness_with(reconnect, false, true).await
}

/// `discovery`: redials go through a [`TestSource`]. `reader`: an application reader always
/// wants the link, as the service multiplexer does.
async fn harness_with(reconnect: ReconnectPolicy, discovery: bool, reader: bool) -> Harness {
    harness_leased(reconnect, discovery, reader, Duration::from_secs(600)).await
}

/// `resume_lease`: how long the daemon keeps a disconnected session for a reconnect.
async fn harness_leased(
    reconnect: ReconnectPolicy,
    discovery: bool,
    reader: bool,
    resume_lease: Duration,
) -> Harness {
    let (dir, group, expected) = test_group(resume_lease);
    let source = discovery.then(|| {
        Arc::new(TestSource {
            group: group.clone(),
            hang: AtomicBool::new(false),
            calls: AtomicUsize::new(0),
        })
    });
    let client = ClientConnection::connect_with_reconnect_groups(
        group.clone(),
        client_config(expected, reconnect),
        source.clone().map(|source| source as Arc<dyn ReconnectGroupSource>),
    )
    .await
    .unwrap();
    if reader {
        let reader = client.clone();
        tokio::spawn(async move { while let Ok(Some(_)) = reader.receive().await {} });
    }
    Harness { _dir: dir, group, source, client }
}

/// The daemon, behind a carrier the test drives; `resume_lease` is how long the daemon keeps a
/// disconnected session for a reconnect.
fn test_group(resume_lease: Duration) -> (TempDir, Arc<TestGroup>, [u8; 32]) {
    let dir = TempDir::new().unwrap();
    let auth = AuthDatabase::load_or_create(dir.path(), "redial-budget", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::with_policy(
        auth,
        SessionLimits::default(),
        DaemonSessionPolicy { resume_lease },
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
    (dir, group, expected)
}

fn client_config(expected: [u8; 32], reconnect: ReconnectPolicy) -> ClientConnectionConfig {
    ClientConnectionConfig {
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: Some(expected),
        auth: ClientAuthMode::Carrier,
        device_name: "redial-budget".into(),
        session: SessionId([7; 16]),
        lane_policy: LanePolicy::Single,
        limits: SessionLimits::default(),
        reconnect,
    }
}

/// The link's states as they change, with the time of each, for a failure message.
fn trace_states(client: &ClientConnection) -> Arc<Mutex<Vec<String>>> {
    let trace = Arc::new(Mutex::new(Vec::new()));
    let mut state = client.subscribe_state();
    let start = Instant::now();
    let log = trace.clone();
    tokio::spawn(async move {
        while state.changed().await.is_ok() {
            let now = *state.borrow_and_update();
            lock(&log).push(format!("{:?} {now:?}", start.elapsed()));
        }
    });
    trace
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

/// A send with a deadline whose lane another send holds through a recovery (one with no
/// deadline, parked on a dead link) answers by its deadline. The old send waited for the lane
/// first and so waited out the other send's recovery, however long.
#[tokio::test(start_paused = true)]
async fn a_send_deadline_holds_while_another_send_owns_the_lane() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    h.group.down.store(true, Ordering::Release);
    h.group.cut_all();
    tokio::time::sleep(Duration::from_millis(1)).await;
    let plain = h.client.clone();
    tokio::spawn(async move {
        let _ = plain
            .send(Lane::Interactive, 1, Bytes::from_static(b"plain"), FrameFlags::empty())
            .await;
    });
    tokio::time::sleep(Duration::from_millis(1)).await;
    let deadline = Instant::now() + Duration::from_millis(1_500);
    let result = tokio::time::timeout(
        Duration::from_secs(30),
        h.client.send_by(
            deadline,
            Lane::Interactive,
            1,
            Bytes::from_static(b"by-deadline"),
            FrameFlags::empty(),
        ),
    )
    .await
    .expect("a send with a 1.5 s deadline was still waiting 30 s later");
    assert!(matches!(result, Err(ConnectionError::ReconnectDeadlineExceeded { .. })), "{result:?}");
    assert!(Instant::now() <= deadline, "the answer came {:?} late", Instant::now() - deadline);
}

/// A send whose deadline has already passed is refused even when the lane and the session are
/// free at once: the deadline wins over a wait that is ready, so nothing is sent late. The old
/// code polled the wait first and sent.
#[tokio::test(start_paused = true)]
async fn an_expired_deadline_wins_over_a_free_lane() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    let deadline = Instant::now();
    tokio::time::sleep(Duration::from_millis(1)).await;
    let result = h
        .client
        .send_by(deadline, Lane::Interactive, 1, Bytes::from_static(b"late"), FrameFlags::empty())
        .await;
    assert!(matches!(result, Err(ConnectionError::ReconnectDeadlineExceeded { .. })), "{result:?}");
}

/// `await_ready` answers by its deadline while a recovery is replaying: replay holds the
/// session lock (here until a send stuck on the old route lets go). The old code waited for
/// that lock first, past the deadline.
#[tokio::test(start_paused = true)]
async fn await_ready_does_not_wait_out_a_replay() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    let trace = trace_states(&h.client);
    // The route dies with no error: the heartbeat's probe goes unanswered and recovers by 6 s
    // later, and the replay on the new link waits on the send stuck on the old one.
    h.group.freeze(true, true);
    let plain = h.client.clone();
    tokio::spawn(async move {
        let _ = plain
            .send(Lane::Interactive, 1, Bytes::from_static(b"stuck"), FrameFlags::empty())
            .await;
    });
    tokio::time::sleep(Duration::from_secs(7)).await;
    let state = *h.client.subscribe_state().borrow();
    assert_eq!(state, ConnectionState::Reconnecting, "{:?}", lock(&trace));
    let deadline = Instant::now() + Duration::from_secs(1);
    let result = tokio::time::timeout(Duration::from_secs(30), h.client.await_ready(deadline))
        .await
        .expect("await_ready with a 1 s deadline was still waiting 30 s later");
    assert!(matches!(result, Err(ConnectionError::ReconnectDeadlineExceeded { .. })), "{result:?}");
    assert!(Instant::now() <= deadline, "the answer came {:?} late", Instant::now() - deadline);
    // Once the stuck send lets go the replay finishes and the link is back.
    h.group.freeze(false, false);
    assert!(wait_state(&h.client, ConnectionState::Connected, Duration::from_secs(20)).await);
    assert!(h.client.await_ready(Instant::now() + Duration::from_secs(1)).await.is_ok());
}

/// Transport discovery hung on the network that went away is dropped when the network
/// changes, and the link redials at once instead of after discovery's 15 s timeout.
#[tokio::test(start_paused = true)]
async fn a_network_change_drops_a_hung_discovery() {
    let h = harness_with(policy(), true, true).await;
    let source = h.source.clone().expect("discovery harness");
    tokio::time::sleep(Duration::from_secs(10)).await;
    h.group.down.store(true, Ordering::Release);
    source.hang.store(true, Ordering::Release);
    h.group.cut_all();
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(source.calls.load(Ordering::Acquire) >= 1, "discovery never started");
    h.group.down.store(false, Ordering::Release);
    source.hang.store(false, Ordering::Release);
    let changed = Instant::now();
    h.client.network_changed();
    assert!(wait_state(&h.client, ConnectionState::Connected, Duration::from_secs(20)).await);
    let took = changed.elapsed();
    assert!(took < Duration::from_millis(100), "reconnected {took:?} after the network change");
}

/// A heartbeat probe that finds an application reader on the receive side, which is then
/// cancelled before the answer comes, reads the answer itself. The old probe only waited for
/// a frame that reader would have seen, so a healthy link was declared dead and redialed.
#[tokio::test(start_paused = true)]
async fn a_probe_reads_its_answer_after_the_reader_is_cancelled() {
    let h = harness_with(policy(), false, false).await;
    let start = Instant::now();
    // On the paused clock the first connect's dial is at `start` too.
    let connected = h.group.dials_since(start);
    let trace = trace_states(&h.client);
    // From 1.9 s the daemon's frames are held back for 700 ms, well inside the 4 s probe
    // window, so the answer to the probe at 2 s comes at 2.6 s. A reader waits across the
    // probe and gives up at 2.4 s, before the answer.
    tokio::time::sleep_until(start + Duration::from_millis(1_900)).await;
    h.group.freeze(false, true);
    let _ = tokio::time::timeout(Duration::from_millis(500), h.client.receive()).await;
    tokio::time::sleep_until(start + Duration::from_millis(2_600)).await;
    h.group.freeze(false, false);
    tokio::time::sleep(Duration::from_secs(10)).await;
    let dials = h.group.dials_since(start) - connected;
    assert_eq!(dials, 0, "a healthy link was redialed {dials} times: {:?}", lock(&trace));
    assert_eq!(*h.client.subscribe_state().borrow(), ConnectionState::Connected);
}

/// A route that dies with a write stuck on it (the old network went away mid-send) is redialed
/// within 2 s of the network change. The probe the change sends queues behind the stuck write
/// and never goes out; the old code waited the full 4 s answer window for it (cmux#38303 F2).
#[tokio::test(start_paused = true)]
async fn a_network_change_interrupts_a_blocked_write() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_millis(10_100)).await;
    let trace = trace_states(&h.client);
    h.group.freeze(true, true);
    let plain = h.client.clone();
    tokio::spawn(async move {
        let _ = plain
            .send(Lane::Interactive, 1, Bytes::from_static(b"stuck"), FrameFlags::empty())
            .await;
    });
    tokio::time::sleep(Duration::from_millis(100)).await;
    let changed = Instant::now();
    h.client.network_changed();
    tokio::time::sleep(Duration::from_secs(10)).await;
    let first = h.group.first_dial_since(changed).expect("the blocked link was never redialed");
    let took = first - changed;
    assert!(
        took <= Duration::from_millis(2_100),
        "redialed {took:?} after the network change: {:?}",
        lock(&trace)
    );
}

/// A network change made before forwarding starts (while the link was dialing, in another
/// phase) still reaches the link: the receiver was taken first, so the change is not marked
/// seen. A parked link redials at once instead of at the end of its 5 s park (cmux#38303 F1).
#[tokio::test(start_paused = true)]
async fn a_network_change_before_forwarding_still_reaches_the_link() {
    let h = harness(policy()).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    h.group.down.store(true, Ordering::Release);
    h.group.cut_all();
    tokio::time::sleep(Duration::from_secs(1)).await;
    assert_eq!(*h.client.subscribe_state().borrow(), ConnectionState::Disconnected);
    let watch = NetworkWatch::manual();
    let changes = watch.subscribe();
    h.group.down.store(false, Ordering::Release);
    watch.signal();
    let changed = Instant::now();
    tokio::spawn(network_watch::forward(changes, Arc::downgrade(&h.client)));
    assert!(wait_state(&h.client, ConnectionState::Connected, Duration::from_secs(5)).await);
    let took = changed.elapsed();
    assert!(took < Duration::from_millis(100), "reconnected {took:?} after the network change");
}

async fn link_call(path: &std::path::Path, request: AdminRequest) -> LinkStatus {
    let response = call_admin(path, &request).await.unwrap();
    assert!(response.ok, "{:?}", response.error);
    serde_json::from_value(response.result.unwrap()).unwrap()
}

/// The link's own socket answers its state; a wait answers `down` with the reason by the
/// caller's deadline, and `connected` once the link is back. Other admin requests are refused.
#[tokio::test]
async fn the_link_socket_answers_state_and_waits_by_the_deadline() {
    let h = harness(policy()).await;
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("link.admin");
    let _server = serve_link_admin(&h.client, &path).await.unwrap();
    let status = link_call(&path, AdminRequest::LinkState).await;
    assert_eq!(status, LinkStatus { state: "connected".into(), reason: None });
    let refused = call_admin(&path, &AdminRequest::Status).await.unwrap();
    assert!(!refused.ok, "a link socket answered a daemon request");

    h.group.down.store(true, Ordering::Release);
    h.group.cut_all();
    let asked = std::time::Instant::now();
    let status = link_call(&path, AdminRequest::AwaitReady { within_ms: 800 }).await;
    let took = asked.elapsed();
    assert_eq!(status.state, "down", "{status:?}");
    assert!(status.reason.as_deref().is_some_and(|reason| !reason.is_empty()), "{status:?}");
    assert!(took < Duration::from_millis(1_500), "the wait answered after {took:?}");
    let status = link_call(&path, AdminRequest::LinkState).await;
    assert_ne!(status.state, "connected", "{status:?}");

    h.group.down.store(false, Ordering::Release);
    let status = link_call(&path, AdminRequest::AwaitReady { within_ms: 5_000 }).await;
    assert_eq!(status, LinkStatus { state: "connected".into(), reason: None });
}

/// A network change that comes while a heartbeat probe is already stuck behind a write on the
/// dead route shortens that probe to 2 s from the change. The old probe only took the short
/// window when the change started it, so this one waited out its 4 s (cmux#38850 review F1).
#[tokio::test(start_paused = true)]
async fn a_network_change_shortens_a_probe_already_blocked() {
    let h = harness(policy()).await;
    // Probes go out every 2 s from the connect; the one at 12 s queues behind the stuck write.
    tokio::time::sleep(Duration::from_millis(10_100)).await;
    let trace = trace_states(&h.client);
    h.group.freeze(true, true);
    let plain = h.client.clone();
    tokio::spawn(async move {
        let _ = plain
            .send(Lane::Interactive, 1, Bytes::from_static(b"stuck"), FrameFlags::empty())
            .await;
    });
    tokio::time::sleep(Duration::from_millis(2_900)).await;
    let changed = Instant::now();
    h.client.network_changed();
    tokio::time::sleep(Duration::from_secs(10)).await;
    let first = h.group.first_dial_since(changed).expect("the blocked link was never redialed");
    let took = first - changed;
    assert!(
        took <= Duration::from_millis(2_100),
        "redialed {took:?} after the network change: {:?}",
        lock(&trace)
    );
}

/// A redial that finds the session gone (past the daemon's resume lease) after transport
/// failures is the reason the link reports. The old code recorded only retryable failures, so
/// link-state and await-ready kept naming the old transport error (cmux#38850 review F2).
#[tokio::test(start_paused = true)]
async fn a_gone_session_replaces_the_last_transport_failure() {
    let h = harness_leased(policy(), false, true, Duration::from_secs(1)).await;
    tokio::time::sleep(Duration::from_secs(10)).await;
    h.group.down.store(true, Ordering::Release);
    h.group.cut_all();
    tokio::time::sleep(Duration::from_secs(1)).await;
    let transport = h.client.last_failure().expect("the failed burst left no reason");
    // Past the resume lease the daemon forgets the session; the next redial is refused.
    tokio::time::sleep(Duration::from_secs(2)).await;
    h.group.down.store(false, Ordering::Release);
    h.client.network_changed();
    tokio::time::timeout(Duration::from_secs(10), async {
        while !h.client.session_unavailable() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the redial never found the session gone");
    let reason = h.client.last_failure();
    assert!(
        reason.as_deref().is_some_and(|reason| reason.contains("no longer has")),
        "the link still reports {reason:?} (was {transport:?})"
    );
}

/// The first connect's link open counts toward the attempt deadline, as every later step of the
/// setup does: a carrier whose open never resolves (a TCP dial with no timeout of its own) fails
/// the connect after `attempt_timeout` instead of hanging it forever (cmux#38335 review F4).
#[tokio::test(start_paused = true)]
async fn a_first_connect_whose_open_hangs_fails_at_the_attempt_timeout() {
    let (_dir, group, expected) = test_group(Duration::from_secs(600));
    group.hang.store(true, Ordering::Release);
    let reconnect = policy();
    let start = Instant::now();
    let connect = ClientConnection::connect(group.clone(), client_config(expected, reconnect));
    let result = tokio::time::timeout(reconnect.attempt_timeout * 4, connect)
        .await
        .expect("the first connect hung on a link open that never resolves");
    let error = result.err().expect("a connect whose link never opened succeeded");
    let took = start.elapsed();
    assert!(
        matches!(error, ConnectionError::Crypto(CryptoError::HandshakeTimeout { .. })),
        "the connect failed with {error:?}, not the attempt timeout"
    );
    assert!(
        took <= reconnect.attempt_timeout + Duration::from_millis(100),
        "the connect failed after {took:?}, past its {:?} attempt timeout",
        reconnect.attempt_timeout
    );
    assert_eq!(group.dials_since(start), 1, "the first connect dials once");
}
