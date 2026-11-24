//! One warm standby route: a reconnect that finds one takes it without a dial, and falls back
//! to the (raced) pass when there is none or it is stale. Virtual (paused) time.

use std::sync::atomic::AtomicUsize;

use super::*;
use crate::remote_runtime::warm_standby::{
    Armed, MAX_AGE, WarmStandby, arm_standby, next_warm_route, standby_route,
};

/// Route `index` answers after `delay` with `(index, dial number)`, or fails when `down`.
struct CountingDials {
    delay: Duration,
    down: Vec<usize>,
    dials: std::sync::Mutex<Vec<usize>>,
}

impl CountingDials {
    fn new(delay: Duration, down: Vec<usize>) -> Self {
        Self { delay, down, dials: Default::default() }
    }

    fn dials(&self) -> Vec<usize> {
        self.dials.lock().unwrap().clone()
    }
}

#[async_trait]
impl ReconnectRouteAttempt<(usize, usize)> for CountingDials {
    async fn connect(
        &self,
        index: usize,
        _request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<(usize, usize), ProviderError> {
        let serial = {
            let mut dials = self.dials.lock().unwrap();
            dials.push(index);
            dials.len()
        };
        tokio::time::sleep(self.delay).await;
        if self.down.contains(&index) {
            Err(ProviderError::Transport(format!("route {index} is down")))
        } else {
            Ok((index, serial))
        }
    }
}

fn three_routes() -> Vec<ResolvedRouteCandidate> {
    vec![
        test_route("wss://a.example/v1/link"),
        test_route("wss://b.example/v1/link"),
        test_route("wss://c.example/v1/link"),
    ]
}

const SESSION: SessionId = SessionId([31; 16]);

async fn arm(
    standby: &WarmStandby<(usize, usize)>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    attempt: &CountingDials,
) -> Result<Armed<(usize, usize)>, ProviderError> {
    arm_standby(standby, next, routes, SESSION, LanePolicy::Single, AuthKind::Enrolled, attempt)
        .await
}

async fn reconnect(
    standby: &WarmStandby<(usize, usize)>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    attempt: &CountingDials,
) -> Result<((usize, usize), Option<(usize, usize)>), ProviderError> {
    next_warm_route(
        standby,
        next,
        routes,
        Some(RouteRace::after(None)),
        SESSION,
        LanePolicy::Single,
        AuthKind::Enrolled,
        attempt,
    )
    .await
}

/// The standby is the route the pass would try first after the active one.
#[tokio::test(start_paused = true)]
async fn the_standby_goes_on_the_next_route_that_is_not_the_active_one() {
    let mut routes = three_routes();
    assert_eq!(standby_route(&routes, 1, 0, AuthKind::Enrolled), Some(1));
    assert_eq!(standby_route(&routes, 0, 2, AuthKind::Enrolled), Some(0));
    // A relay route keeps its own standby; the next one is the standby.
    routes[1] = test_route("relay+wss://relay.example/v1/relay");
    assert_eq!(standby_route(&routes, 1, 0, AuthKind::Enrolled), Some(2));
    // One route has none; routes that cannot carry the auth are not standbys (wss is
    // device-only, so under carrier auth nothing is).
    assert_eq!(standby_route(&routes[..1], 1, 0, AuthKind::Enrolled), None);
    assert_eq!(standby_route(&three_routes(), 1, 0, AuthKind::Carrier), None);
    assert_eq!(standby_route(&[], 0, 0, AuthKind::Enrolled), None);
}

/// The point: a reconnect that finds a standby dials nothing and takes no time; without one it
/// pays the dial.
#[tokio::test(start_paused = true)]
async fn a_reconnect_with_a_standby_skips_the_dial() {
    let routes = three_routes();
    let rtt = Duration::from_millis(120);
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(rtt, vec![0]);

    // Armed beside the active link (route 0): the dial happens here, off the reconnect.
    let armed = arm(&standby, &next, &routes, &attempt).await.unwrap();
    assert!(matches!(armed, Armed::Dialed { index: 1, retired: None }));
    assert_eq!(attempt.dials(), [1]);

    // Route 0 dies: the reconnect takes route 1's group, already dialed.
    let started = tokio::time::Instant::now();
    let (group, stale) = reconnect(&standby, &next, &routes, &attempt).await.unwrap();
    let warm = started.elapsed();
    assert_eq!((group, stale), ((1, 1), None), "the group armed earlier, not a new one");
    assert_eq!(attempt.dials(), [1], "no dial during the reconnect");
    assert_eq!(next.load(Ordering::Relaxed), 2, "the rotation moved past the standby's route");
    assert_eq!(standby.held_index(), None, "used: the keeper re-arms it");

    // The same reconnect without a standby dials the next route.
    let cold_standby = WarmStandby::new(0);
    let cold_next = AtomicUsize::new(1);
    let cold_attempt = CountingDials::new(rtt, vec![0]);
    let started = tokio::time::Instant::now();
    let (group, _) = reconnect(&cold_standby, &cold_next, &routes, &cold_attempt).await.unwrap();
    let cold = started.elapsed();
    assert_eq!(group.0, 1);
    assert_eq!(cold_attempt.dials(), [1]);
    eprintln!("reconnect: warm standby {warm:?}, cold dial {cold:?}");
    assert_eq!(warm, Duration::ZERO);
    assert_eq!(cold, rtt);
}

/// After use the standby re-arms on the next route that is not the new active one.
#[tokio::test(start_paused = true)]
async fn the_standby_rearms_beside_the_new_active_route() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    reconnect(&standby, &next, &routes, &attempt).await.unwrap();
    let armed = arm(&standby, &next, &routes, &attempt).await.unwrap();
    assert!(matches!(armed, Armed::Dialed { index: 2, retired: None }));
    assert_eq!(standby.held_index(), Some(2));
    // A fresh one is not dialed again.
    assert!(matches!(arm(&standby, &next, &routes, &attempt).await.unwrap(), Armed::Held(_)));
    assert_eq!(attempt.dials(), [1, 2]);
}

/// A standby older than the trust limit is not used: the pass dials, and the old one is handed
/// back to be closed.
#[tokio::test(start_paused = true)]
async fn a_stale_standby_is_not_used() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    tokio::time::advance(MAX_AGE + Duration::from_secs(1)).await;
    let (group, stale) = reconnect(&standby, &next, &routes, &attempt).await.unwrap();
    assert_eq!(group, (1, 2), "a new dial, not the held group");
    assert_eq!(stale, Some((1, 1)));
    assert_eq!(attempt.dials(), [1, 1]);
}

/// A standby that cannot be dialed leaves the slot empty, and the reconnect races as before:
/// route 1 down, so the pass moves on to route 2.
#[tokio::test(start_paused = true)]
async fn a_failed_standby_leaves_the_race_as_it_was() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![1]);
    assert!(arm(&standby, &next, &routes, &attempt).await.is_err());
    assert_eq!(standby.held_index(), None);
    let (group, stale) = reconnect(&standby, &next, &routes, &attempt).await.unwrap();
    assert_eq!((group.0, stale), (2, None));
}

/// A single route has nothing to keep warm.
#[tokio::test(start_paused = true)]
async fn one_route_has_no_standby() {
    let routes = vec![test_route("wss://a.example/v1/link")];
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    assert!(matches!(arm(&standby, &next, &routes, &attempt).await.unwrap(), Armed::NoRoute));
    assert!(attempt.dials().is_empty());
}
