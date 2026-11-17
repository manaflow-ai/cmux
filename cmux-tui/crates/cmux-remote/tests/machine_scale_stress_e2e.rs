#![cfg(unix)]
//! Many machine links at once: what one link costs must not grow with how many there are.
//!
//! N = 10, 200 and 1000 simulated machines, each its own `RemoteDaemon` reached by a real
//! `ClientConnection` over an in-memory link (the `Pipe`/`MemLink`/`TestGroup` pattern of
//! `redial_budget_e2e.rs`). The tokio clock is paused, so heartbeats, backoff and the redial
//! budget run on one deterministic schedule; what a step costs is read off the wall clock
//! (`std::time::Instant`). The contract:
//!
//! - connecting one more machine costs the same with 1000 links up as with 10: the per-link
//!   connect p95 at N = 1000 is within max(3x, +2 ms) of N = 10's;
//! - redialing one cut link costs the same with 1000 links up as with 10 (same bound);
//! - a flap storm (every link cut every 250 ms, then every link dying 50 ms after each
//!   reconnect) costs the same per redial at 1000 links as at 10 (same bound), and no link
//!   dials more than its token bucket allows: `capacity + elapsed / refill_interval`
//!   (`RedialBudget::default()`, read from the policy, not restated here), checked after every
//!   round;
//! - a network change seen by all N at once (one `NetworkWatch` forwarded to every link)
//!   probes the live links without one redial, and brings N parked links back within 100 ms
//!   of tokio time at a per-link cost within the same bound.
//!
//! Each scenario prints `N | p50 | p95` per N. A relay registration renewal storm is not here:
//! `relay_registration_renewal_e2e.rs` needs a real relay, real TCP and real ticket expiries
//! (6 s each), so N registrations cannot run in seconds.
//!
//! Run (from `cmux-tui/`):
//! `cargo test -p cmux-remote --test machine_scale_stress_e2e -- --nocapture`.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant as WallInstant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_remote::connection::{
    ClientConnection, ClientConnectionConfig, ReconnectPolicy, RedialBudget,
};
use cmux_remote::crypto::{ClientAuthMode, NetworkPeer, StaticIdentity};
use cmux_remote::daemon::{DaemonSessionPolicy, InboundLink, RemoteDaemon};
use cmux_remote::identity::AuthDatabase;
use cmux_remote::link::{FrameLink, LinkError};
use cmux_remote::network_watch::{self, NetworkWatch};
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
/// The link counts every scenario runs; the first is the baseline the last is held to.
const SCALES: [usize; 3] = [10, 200, 1000];
/// Isolated redials sampled per N: a fixed count, so the sample's own cost does not grow.
const REDIAL_SAMPLES: usize = 100;
/// Cut-every-link rounds in the flap storm, one per [`ROUND_EVERY`] of tokio time.
const STORM_ROUNDS: usize = 8;
const ROUND_EVERY: Duration = Duration::from_millis(250);
/// Then every link dies this long after each reconnect, for [`FLAP_FOR`].
const FLAP_AFTER: Duration = Duration::from_millis(50);
const FLAP_FOR: Duration = Duration::from_secs(6);

/// The scenarios measure wall time, so they run one at a time, not on the harness's threads
/// side by side.
static SERIAL: Mutex<()> = Mutex::new(());

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
            s.queue.push_back(frame);
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

/// One machine's carrier: each dial is logged, and the test can refuse, cut or flap links.
struct TestGroup {
    daemon: Arc<RemoteDaemon>,
    evidence: CarrierEvidence,
    /// New dials fail at once (no route).
    down: AtomicBool,
    /// Every link opened from now on is cut this long after it opens.
    flap_after: Mutex<Option<Duration>>,
    links: Mutex<Vec<(Arc<Pipe>, Arc<Pipe>)>>,
    dials: Mutex<Vec<Instant>>,
}

impl TestGroup {
    fn dials_since(&self, since: Instant) -> usize {
        lock(&self.dials).iter().filter(|at| **at >= since).count()
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
        let client = MemLink { out: up.clone(), inc: down.clone() };
        let server = MemLink { out: down, inc: up };
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

/// A machine whose daemon is up and not yet dialed.
struct Machine {
    group: Arc<TestGroup>,
    expected: [u8; 32],
}

/// A machine with its link up and an application reader on it, as the service multiplexer
/// keeps.
struct Linked {
    group: Arc<TestGroup>,
    client: Arc<ClientConnection>,
}

fn policy() -> ReconnectPolicy {
    // Jitter off so every run is one schedule.
    ReconnectPolicy { full_jitter: false, ..ReconnectPolicy::default() }
}

fn machine(root: &TempDir, index: usize) -> Machine {
    let dir = root.path().join(format!("machine-{index}"));
    std::fs::create_dir(&dir).unwrap();
    let auth = AuthDatabase::load_or_create(&dir, "machine-scale", false).unwrap();
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
        flap_after: Mutex::new(None),
        links: Mutex::new(Vec::new()),
        dials: Mutex::new(Vec::new()),
    });
    Machine { group, expected }
}

fn session(index: usize) -> SessionId {
    let mut id = [7_u8; 16];
    id[..8].copy_from_slice(&(index as u64).to_le_bytes());
    SessionId(id)
}

async fn link(machine: Machine, index: usize) -> Linked {
    let client = ClientConnection::connect(
        machine.group.clone(),
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(machine.expected),
            auth: ClientAuthMode::Carrier,
            device_name: "machine-scale".into(),
            session: session(index),
            lane_policy: LanePolicy::Single,
            limits: SessionLimits::default(),
            reconnect: policy(),
        },
    )
    .await
    .unwrap();
    let reader = client.clone();
    tokio::spawn(async move { while let Ok(Some(_)) = reader.receive().await {} });
    Linked { group: machine.group, client }
}

/// Bring up `n` machines and link each in turn, the other links already up; answers the
/// links and each connect's wall time. The daemon's setup (its identity on disk) is not part
/// of a connect.
async fn fleet(root: &TempDir, n: usize) -> (Vec<Linked>, Vec<Duration>) {
    let mut links = Vec::with_capacity(n);
    let mut costs = Vec::with_capacity(n);
    for index in 0..n {
        let machine = machine(root, index);
        let started = WallInstant::now();
        links.push(link(machine, index).await);
        costs.push(started.elapsed());
    }
    (links, costs)
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().start_paused(true).build().unwrap()
}

/// Nearest-rank percentile of `samples` (sorted here).
fn percentile(samples: &mut [Duration], p: f64) -> Duration {
    assert!(!samples.is_empty());
    samples.sort_unstable();
    let rank = ((p / 100.0) * samples.len() as f64).ceil() as usize;
    samples[rank.clamp(1, samples.len()) - 1]
}

#[derive(Clone, Copy)]
struct Row {
    n: usize,
    p50: Duration,
    p95: Duration,
}

impl Row {
    fn of(n: usize, samples: &mut [Duration]) -> Self {
        Self { n, p50: percentile(samples, 50.0), p95: percentile(samples, 95.0) }
    }
}

fn print_table(what: &str, rows: &[Row]) {
    println!("{what}: N | p50 | p95");
    for row in rows {
        println!("{what}: {} | {:?} | {:?}", row.n, row.p50, row.p95);
    }
}

/// The largest N's p95 within max(3x, +2 ms) of the smallest N's.
fn assert_flat(what: &str, rows: &[Row]) {
    let (small, large) = (rows[0], rows[rows.len() - 1]);
    let bound = (small.p95 * 3).max(small.p95 + Duration::from_millis(2));
    assert!(
        large.p95 <= bound,
        "{what}: p95 at N={} is {:?}, past {bound:?} (N={} p95 {:?}); per-link cost grows with N",
        large.n,
        large.p95,
        small.n,
        small.p95,
    );
}

/// No link dialed more than its bucket allows since `start`.
fn assert_within_budget(links: &[Linked], budget: RedialBudget, start: Instant, when: &str) {
    let elapsed = Instant::now() - start;
    let earned = u32::try_from(elapsed.as_nanos() / budget.refill_interval.as_nanos()).unwrap();
    let allowed = (budget.capacity + earned) as usize;
    for (index, linked) in links.iter().enumerate() {
        let dials = linked.group.dials_since(start);
        assert!(
            dials <= allowed,
            "{when}: link {index} dialed {dials} times in {elapsed:?}; the budget allows {allowed}",
        );
    }
}

/// A storm's running count: every round's wall time over the redials it made.
struct Storm {
    start: Instant,
    dialed: usize,
    per_redial: Vec<Duration>,
}

impl Storm {
    /// Let `wait` of tokio time pass (every redial it holds runs before the clock moves), then
    /// charge the wall time since `wall` to the redials made since the last round.
    async fn round(&mut self, links: &[Linked], wall: WallInstant, wait: Duration) {
        tokio::time::sleep(wait).await;
        let wall = wall.elapsed();
        let total: usize = links.iter().map(|l| l.group.dials_since(self.start)).sum();
        let round = total - self.dialed;
        self.dialed = total;
        if round > 0 {
            self.per_redial.push(wall / u32::try_from(round).unwrap());
        }
    }
}

async fn wait_all_connected(links: &[Linked], within: Duration) {
    for (index, linked) in links.iter().enumerate() {
        let mut state = linked.client.subscribe_state();
        let up = tokio::time::timeout(
            within,
            state.wait_for(|state| *state == ConnectionState::Connected),
        )
        .await;
        assert!(up.is_ok(), "link {index} is {:?}, not connected", *state.borrow());
    }
}

/// Connect, then redial one cut link at a time with every other link up.
#[test]
fn connect_and_redial_cost_stays_flat_with_n() {
    let _serial = lock(&SERIAL);
    let mut connects = Vec::new();
    let mut redials = Vec::new();
    for n in SCALES {
        let started = WallInstant::now();
        let (mut connect, mut redial) = runtime().block_on(async {
            let root = TempDir::new().unwrap();
            let (links, connect) = fleet(&root, n).await;
            // Let every link's first heartbeat pass, so the redials ride a settled fleet.
            tokio::time::sleep(Duration::from_secs(3)).await;
            let mut redial = Vec::new();
            let step = (n / REDIAL_SAMPLES).max(1);
            for linked in links.iter().step_by(step).take(REDIAL_SAMPLES) {
                let mut generation = linked.client.subscribe_generation();
                generation.borrow_and_update();
                let started = WallInstant::now();
                linked.group.cut_all();
                tokio::time::timeout(Duration::from_secs(1), generation.changed())
                    .await
                    .expect("a cut link was not redialed at once")
                    .unwrap();
                redial.push(started.elapsed());
            }
            (connect, redial)
        });
        connects.push(Row::of(n, &mut connect));
        redials.push(Row::of(n, &mut redial));
        println!("N={n}: connect + redial scenario took {:?}", started.elapsed());
    }
    print_table("connect", &connects);
    print_table("redial", &redials);
    assert_flat("connect", &connects);
    assert_flat("redial", &redials);
}

/// Every link cut every 250 ms, then flapping 50 ms after every reconnect: the per-redial
/// cost stays flat and no link outruns its budget.
#[test]
fn a_flap_storm_costs_the_same_per_redial_and_keeps_the_budget() {
    let _serial = lock(&SERIAL);
    let budget = policy().redial_budget;
    let mut rows = Vec::new();
    for n in SCALES {
        let started = WallInstant::now();
        let (mut per_redial, dials) = runtime().block_on(async {
            let root = TempDir::new().unwrap();
            let (links, _) = fleet(&root, n).await;
            tokio::time::sleep(Duration::from_secs(3)).await;
            let mut storm = Storm { start: Instant::now(), dialed: 0, per_redial: Vec::new() };
            for round in 0..STORM_ROUNDS {
                let wall = WallInstant::now();
                for linked in &links {
                    linked.group.cut_all();
                }
                storm.round(&links, wall, ROUND_EVERY).await;
                assert_within_budget(&links, budget, storm.start, &format!("storm round {round}"));
            }
            for linked in &links {
                *lock(&linked.group.flap_after) = Some(FLAP_AFTER);
            }
            let flap_rounds = FLAP_FOR.as_millis() / ROUND_EVERY.as_millis();
            for round in 0..flap_rounds {
                storm.round(&links, WallInstant::now(), ROUND_EVERY).await;
                assert_within_budget(&links, budget, storm.start, &format!("flap round {round}"));
            }
            for linked in &links {
                *lock(&linked.group.flap_after) = None;
            }
            // Let the last flapped links come back (a parked link waits out its 5 s park).
            storm.round(&links, WallInstant::now(), Duration::from_secs(10)).await;
            wait_all_connected(&links, Duration::from_secs(10)).await;
            assert_within_budget(&links, budget, storm.start, "after the storm");
            (storm.per_redial, storm.dialed)
        });
        let row = Row::of(n, &mut per_redial);
        println!(
            "N={n}: flap storm took {:?}, {dials} redials ({:.1} per link)",
            started.elapsed(),
            dials as f64 / n as f64,
        );
        rows.push(row);
    }
    print_table("storm redial (amortized per round)", &rows);
    assert_flat("storm redial", &rows);
}

/// One network change reaches all N links at once: live links are probed and stay up with no
/// redial; parked links all come back within 100 ms.
#[test]
fn a_network_change_storm_reaches_every_link_at_flat_cost() {
    let _serial = lock(&SERIAL);
    let budget = policy().redial_budget;
    let mut live_rows = Vec::new();
    let mut parked_rows = Vec::new();
    for n in SCALES {
        let started = WallInstant::now();
        let (live, parked) = runtime().block_on(async {
            let root = TempDir::new().unwrap();
            let watch = NetworkWatch::manual();
            let (links, _) = fleet(&root, n).await;
            for linked in &links {
                let changes = watch.subscribe();
                tokio::spawn(network_watch::forward(changes, Arc::downgrade(&linked.client)));
            }
            tokio::time::sleep(Duration::from_secs(3)).await;

            // Live links: probed at once, none redialed.
            let start = Instant::now();
            let wall = WallInstant::now();
            watch.signal();
            tokio::time::sleep(Duration::from_millis(100)).await;
            let live = wall.elapsed() / u32::try_from(n).unwrap();
            for (index, linked) in links.iter().enumerate() {
                assert_eq!(linked.group.dials_since(start), 0, "live link {index} redialed");
                assert_eq!(
                    *linked.client.subscribe_state().borrow(),
                    ConnectionState::Connected,
                    "live link {index}",
                );
            }

            // Parked links: the route is gone, every burst fails and parks.
            let start = Instant::now();
            for linked in &links {
                linked.group.down.store(true, Ordering::Release);
                linked.group.cut_all();
            }
            tokio::time::sleep(Duration::from_secs(1)).await;
            for (index, linked) in links.iter().enumerate() {
                assert_eq!(
                    *linked.client.subscribe_state().borrow(),
                    ConnectionState::Disconnected,
                    "link {index} is not parked",
                );
                linked.group.down.store(false, Ordering::Release);
            }
            let changed = Instant::now();
            let wall = WallInstant::now();
            watch.signal();
            wait_all_connected(&links, Duration::from_millis(100)).await;
            let parked = wall.elapsed() / u32::try_from(n).unwrap();
            let took = changed.elapsed();
            assert!(took <= Duration::from_millis(100), "the fleet came back {took:?} after");
            assert_within_budget(&links, budget, start, "network change storm");
            (live, parked)
        });
        println!("N={n}: network change storm took {:?}", started.elapsed());
        live_rows.push(Row { n, p50: live, p95: live });
        parked_rows.push(Row { n, p50: parked, p95: parked });
    }
    print_table("network change, live (per link)", &live_rows);
    print_table("network change, parked (per link)", &parked_rows);
    assert_flat("network change, live", &live_rows);
    assert_flat("network change, parked", &parked_rows);
}
