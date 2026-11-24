//! One warm standby route: a reconnect that finds one takes it without a dial, and falls back
//! to the (raced) pass when there is none or it is stale. Virtual (paused) time.

use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;
use crate::remote_runtime::warm_standby::{
    ATTEMPT_FLOOR, ATTEMPT_UNKNOWN_RTT, Armed, MAX_AGE, REFRESH, REFRESH_LEAD, WarmStandby,
    arm_standby, attempt_timeout, next_warm_route, standby_route, take_standby, trusted_for,
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

/// Arms against a far end with no hold (an older daemon).
async fn arm(
    standby: &WarmStandby<(usize, usize)>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    attempt: &CountingDials,
) -> Result<Armed<(usize, usize)>, ProviderError> {
    arm_with_hold(standby, next, routes, attempt, None, &AtomicUsize::new(0)).await
}

/// Arms against a far end that answers a hold with `lease`, counting the asks in `asked`.
async fn arm_with_hold(
    standby: &WarmStandby<(usize, usize)>,
    next: &AtomicUsize,
    routes: &[ResolvedRouteCandidate],
    attempt: &CountingDials,
    lease: Option<Duration>,
    asked: &AtomicUsize,
) -> Result<Armed<(usize, usize)>, ProviderError> {
    arm_standby(
        standby,
        next,
        routes,
        SESSION,
        LanePolicy::Single,
        AuthKind::Enrolled,
        attempt,
        |_: &(usize, usize)| true,
        |_| {
            asked.fetch_add(1, Ordering::Relaxed);
            std::future::ready(lease)
        },
    )
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
        |_: &(usize, usize)| true,
    )
    .await
}

/// The standby is the route the pass would try first after the active one.
#[tokio::test(start_paused = true)]
async fn the_standby_goes_on_the_next_route_that_is_not_the_active_one() {
    let mut routes = three_routes();
    assert_eq!(standby_route(&routes, 1, 0, None, AuthKind::Enrolled), Some(1));
    assert_eq!(standby_route(&routes, 0, 2, None, AuthKind::Enrolled), Some(0));
    // A relay route keeps its own standby; the next one is the standby.
    routes[1] = test_route("relay+wss://relay.example/v1/relay");
    assert_eq!(standby_route(&routes, 1, 0, None, AuthKind::Enrolled), Some(2));
    // One route has none; routes that cannot carry the auth are not standbys (wss is
    // device-only, so under carrier auth nothing is).
    assert_eq!(standby_route(&routes[..1], 1, 0, None, AuthKind::Enrolled), None);
    assert_eq!(standby_route(&three_routes(), 1, 0, None, AuthKind::Carrier), None);
    assert_eq!(standby_route(&[], 0, 0, None, AuthKind::Enrolled), None);
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
    assert!(matches!(armed, Armed::Dialed { retired: None }));
    assert_eq!(standby.held_index(), Some(1));
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
    assert!(matches!(armed, Armed::Dialed { retired: None }));
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

/// A standby whose group closed (the daemon closes a connection that opened no stream) is
/// never used: not by the redial, not by the pass, and the keeper dials its replacement.
#[tokio::test(start_paused = true)]
async fn a_closed_standby_is_never_used() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    let closed = |_: &(usize, usize)| false;

    // The redial's take hands it back to be closed, and the rotation does not move to it.
    let taken = take_standby(&standby, &next, closed).expect("a standby was held");
    assert!(matches!(taken, Err((1, 1))), "a closed standby was handed to the redial");
    assert_eq!(next.load(Ordering::Relaxed), 1);

    // The pass's take dials instead.
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    let (group, stale) = next_warm_route(
        &standby,
        &next,
        &routes,
        Some(RouteRace::after(None)),
        SESSION,
        LanePolicy::Single,
        AuthKind::Enrolled,
        &attempt,
        closed,
    )
    .await
    .unwrap();
    assert_eq!(stale, Some((1, 2)), "the closed standby is returned to close");
    assert_eq!(group, (1, 3), "a new dial, not the closed group");

    // The keeper's look re-arms over a closed one at once, however young it is.
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    let rearmed = arm_standby(
        &standby,
        &next,
        &routes,
        SESSION,
        LanePolicy::Single,
        AuthKind::Enrolled,
        &attempt,
        closed,
        |_| std::future::ready(None),
    )
    .await
    .unwrap();
    assert!(matches!(rearmed, Armed::Dialed { retired: Some(_) }));
}

/// A live standby is replaced at REFRESH, before it is untrusted at MAX_AGE, and both come
/// before the daemon's 15 s close of a connection that opened no stream. Until the new one is
/// in, the old one is still taken.
#[tokio::test(start_paused = true)]
async fn the_standby_is_replaced_before_the_daemon_closes_it() {
    assert!(REFRESH < MAX_AGE && MAX_AGE < Duration::from_secs(15));
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    match arm(&standby, &next, &routes, &attempt).await.unwrap() {
        Armed::Held(left) => assert!(left <= REFRESH),
        _ => panic!("a fresh standby was redialed"),
    }
    tokio::time::advance(REFRESH).await;
    let refreshed = arm(&standby, &next, &routes, &attempt).await.unwrap();
    assert!(matches!(refreshed, Armed::Dialed { retired: Some((1, 1)) }));
    assert_eq!(attempt.dials(), [1, 1]);
    // Past REFRESH but inside MAX_AGE an unreplaced standby is still taken.
    let late = WarmStandby::new(0);
    arm(&late, &next, &routes, &attempt).await.unwrap();
    tokio::time::advance(REFRESH + (MAX_AGE - REFRESH) / 2).await;
    assert!(matches!(take_standby(&late, &next, |_: &(usize, usize)| true), Some(Ok((1, _)))));
}

/// The redial on a standby gets a few round trips, not the 15 s attempt timeout.
#[test]
fn a_standby_redial_is_bounded_by_its_round_trip() {
    assert_eq!(
        attempt_timeout(Some(Duration::from_millis(50))),
        ATTEMPT_FLOOR + Duration::from_millis(100)
    );
    assert_eq!(attempt_timeout(None), ATTEMPT_UNKNOWN_RTT);
    assert!(attempt_timeout(Some(Duration::from_millis(300))) < Duration::from_secs(15));
}

/// The redial takes a standby to the route it is on: the pass started behind it redials that
/// route cold first, and the next standby goes beside it.
#[tokio::test(start_paused = true)]
async fn a_taken_standby_moves_the_rotation_to_its_route() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    let taken = take_standby(&standby, &next, |_: &(usize, usize)| true);
    assert!(matches!(taken, Some(Ok((1, (1, 1))))));
    assert_eq!(next.load(Ordering::Relaxed), 1);
    assert_eq!(standby.held_index(), None);
    // Nothing held: no standby for the next redial.
    assert!(take_standby(&standby, &next, |_: &(usize, usize)| true).is_none());
    // The keeper's next standby is beside route 1.
    arm(&standby, &next, &routes, &attempt).await.unwrap();
    assert_eq!(standby.held_index(), Some(2));
}

/// A far end that holds the standby (`cmux-standby-hold/1`) keeps the same connection for its
/// lease: no redial every few seconds, and it is still taken minutes later.
#[tokio::test(start_paused = true)]
async fn a_held_standby_is_kept_for_its_lease_without_a_redial() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    let asked = AtomicUsize::new(0);
    let lease = Some(Duration::from_secs(300));
    arm_with_hold(&standby, &next, &routes, &attempt, lease, &asked).await.unwrap();
    tokio::time::advance(Duration::from_secs(240)).await;
    match arm_with_hold(&standby, &next, &routes, &attempt, lease, &asked).await.unwrap() {
        Armed::Held(left) => assert!(left > Duration::ZERO, "held for its lease"),
        _ => panic!("a held standby was redialed inside its lease"),
    }
    assert_eq!(attempt.dials(), [1], "one dial in four minutes");
    assert!(matches!(take_standby(&standby, &next, |_: &(usize, usize)| true), Some(Ok((1, _)))));
    // Near the lease's end it is replaced, and the hold is asked again.
    let standby = WarmStandby::new(0);
    arm_with_hold(&standby, &next, &routes, &attempt, lease, &asked).await.unwrap();
    tokio::time::advance(trusted_for(lease) - REFRESH_LEAD).await;
    let refreshed = arm_with_hold(&standby, &next, &routes, &attempt, lease, &asked).await.unwrap();
    assert!(matches!(refreshed, Armed::Dialed { retired: Some(_) }));
    assert_eq!(asked.load(Ordering::Relaxed), 3);
    assert!(trusted_for(lease) < Duration::from_secs(300));
}

/// A far end with no hold is asked once per peer; its standbys are redialed under its 15 s.
#[tokio::test(start_paused = true)]
async fn a_far_end_with_no_hold_is_asked_once_and_the_standby_is_redialed() {
    let routes = three_routes();
    let standby = WarmStandby::new(0);
    let next = AtomicUsize::new(1);
    let attempt = CountingDials::new(Duration::from_millis(5), vec![]);
    let asked = AtomicUsize::new(0);
    arm_with_hold(&standby, &next, &routes, &attempt, None, &asked).await.unwrap();
    tokio::time::advance(REFRESH).await;
    let refreshed = arm_with_hold(&standby, &next, &routes, &attempt, None, &asked).await.unwrap();
    assert!(matches!(refreshed, Armed::Dialed { retired: Some(_) }));
    assert_eq!(asked.load(Ordering::Relaxed), 1, "no second ask of a far end with no hold");
    assert_eq!(trusted_for(None), MAX_AGE);
}
