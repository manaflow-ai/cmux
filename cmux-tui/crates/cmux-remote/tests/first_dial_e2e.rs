#![cfg(unix)]
//! A link's first dial runs like a recovery (cmuxterm-hq#7766): the same budget and bursts as a
//! later drop, a network change or a caller's wait dials at once, a permanent error ends it, and
//! the link's own socket answers from the start.
//!
//! Run (from `cmux-tui/`): `cargo test -p cmux-remote --test first_dial_e2e`.

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use cmux_remote::admin::{AdminRequest, LinkStatus, call_admin, serve_link_cell_admin};
use cmux_remote::connection::{ReconnectPolicy, RedialBudget};
use cmux_remote::first_dial::{DialOutcome, DialStop, LinkCell, LinkPhase, NotConnected};
use cmux_remote::network_watch::NetworkWatch;
use tempfile::TempDir;
use tokio::time::Instant;

#[derive(Debug, Clone, PartialEq, Eq)]
struct Refused(&'static str);

impl From<DialStop> for Refused {
    fn from(stop: DialStop) -> Self {
        match stop {
            DialStop::NetworkChanged => Refused("network changed"),
            DialStop::DeadlineExceeded { .. } => Refused("deadline"),
        }
    }
}

impl fmt::Display for Refused {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.0)
    }
}

fn policy() -> ReconnectPolicy {
    ReconnectPolicy { full_jitter: false, ..ReconnectPolicy::default() }
}

/// A first dial whose every attempt fails with `outcome`, counting attempts.
fn spawn_dial(
    cell: &Arc<LinkCell>,
    policy: ReconnectPolicy,
    watch: &NetworkWatch,
    fatal: bool,
) -> (Arc<AtomicUsize>, tokio::task::JoinHandle<Result<(), Refused>>) {
    let attempts = Arc::new(AtomicUsize::new(0));
    let counted = attempts.clone();
    let cell = cell.clone();
    let network = watch.subscribe();
    let task = tokio::spawn(async move {
        cell.dial(policy, network, || {
            counted.fetch_add(1, Ordering::AcqRel);
            async move {
                if fatal {
                    DialOutcome::<(), _>::Fatal(Refused("authorization failed"))
                } else {
                    DialOutcome::Retry(Refused("nothing listens"))
                }
            }
        })
        .await
    });
    (attempts, task)
}

/// After its burst the first dial parks for `maximum_delay`; a network change dials at once.
#[tokio::test(start_paused = true)]
async fn a_parked_first_dial_dials_at_once_on_a_network_change() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (attempts, _task) = spawn_dial(
        &cell,
        ReconnectPolicy { maximum_delay: Duration::from_secs(30), ..policy() },
        &watch,
        false,
    );
    // The burst: at once, then 150 ms and 600 ms later.
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(attempts.load(Ordering::Acquire), 3);
    assert!(
        matches!(cell.phase(), LinkPhase::Disconnected { reason: Some(_) }),
        "{:?}",
        cell.phase()
    );
    tokio::time::sleep(Duration::from_secs(10)).await;
    assert_eq!(attempts.load(Ordering::Acquire), 3, "the parked dial did not wait");

    watch.signal();
    tokio::time::sleep(Duration::from_millis(1)).await;
    assert_eq!(attempts.load(Ordering::Acquire), 4, "the network change did not dial at once");
}

/// A network change abandons an attempt hung on the old network and dials again at once.
#[tokio::test(start_paused = true)]
async fn a_network_change_abandons_a_hung_first_dial() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let attempts = Arc::new(AtomicUsize::new(0));
    let counted = attempts.clone();
    let dialing = cell.clone();
    let network = watch.subscribe();
    let _task = tokio::spawn(async move {
        dialing
            .dial(policy(), network, || {
                counted.fetch_add(1, Ordering::AcqRel);
                std::future::pending::<DialOutcome<(), Refused>>()
            })
            .await
    });
    tokio::time::sleep(Duration::from_secs(5)).await;
    assert_eq!(attempts.load(Ordering::Acquire), 1);
    watch.signal();
    tokio::time::sleep(Duration::from_millis(1)).await;
    assert_eq!(attempts.load(Ordering::Acquire), 2, "the hung dial was not dropped");
    assert!(
        matches!(&cell.phase(), LinkPhase::Connecting { reason: Some(reason) } if reason.contains("network")),
        "{:?}",
        cell.phase()
    );
}

/// A caller's wait wakes a parked first dial, and answers by its deadline with the reason.
#[tokio::test(start_paused = true)]
async fn a_callers_wait_wakes_a_parked_first_dial() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (attempts, _task) = spawn_dial(
        &cell,
        ReconnectPolicy { maximum_delay: Duration::from_secs(30), ..policy() },
        &watch,
        false,
    );
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert_eq!(attempts.load(Ordering::Acquire), 3);

    let asked = Instant::now();
    let answer = cell.wait_connected(asked + Duration::from_millis(500)).await;
    assert_eq!(
        answer.err(),
        Some(NotConnected::TimedOut { reason: Some("nothing listens".into()) })
    );
    assert_eq!(asked.elapsed(), Duration::from_millis(500));
    assert!(attempts.load(Ordering::Acquire) >= 4, "the wait did not wake the parked dial");
}

/// Every first-dial attempt spends from the redial budget: over 20 s a bucket of 2 refilled
/// every 2 s allows at most 12 attempts, however short the delays.
#[tokio::test(start_paused = true)]
async fn the_first_dial_spends_the_redial_budget() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (attempts, _task) = spawn_dial(
        &cell,
        ReconnectPolicy {
            initial_delay: Duration::from_millis(1),
            maximum_delay: Duration::from_millis(1),
            redial_budget: RedialBudget { capacity: 2, refill_interval: Duration::from_secs(2) },
            ..policy()
        },
        &watch,
        false,
    );
    tokio::time::sleep(Duration::from_secs(20)).await;
    let made = attempts.load(Ordering::Acquire);
    assert!((10..=12).contains(&made), "{made} attempts in 20 s");
}

/// A permanent error ends the first dial at once, and the cell says why.
#[tokio::test(start_paused = true)]
async fn a_permanent_error_ends_the_first_dial() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (attempts, task) = spawn_dial(&cell, policy(), &watch, true);
    assert_eq!(task.await.unwrap(), Err(Refused("authorization failed")));
    assert_eq!(attempts.load(Ordering::Acquire), 1);
    assert!(
        matches!(&cell.phase(), LinkPhase::Failed { reason } if reason == "authorization failed"),
        "{:?}",
        cell.phase()
    );
}

/// An explicit attempt bound ends the first dial with the last error.
#[tokio::test(start_paused = true)]
async fn a_bounded_first_dial_ends_after_its_attempts() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (attempts, task) =
        spawn_dial(&cell, ReconnectPolicy { maximum_attempts: Some(5), ..policy() }, &watch, false);
    assert_eq!(task.await.unwrap(), Err(Refused("nothing listens")));
    assert_eq!(attempts.load(Ordering::Acquire), 5);
    assert!(matches!(cell.phase(), LinkPhase::Failed { .. }), "{:?}", cell.phase());
}

async fn link_call(path: &std::path::Path, request: AdminRequest) -> LinkStatus {
    let response = call_admin(path, &request).await.unwrap();
    assert!(response.ok, "{:?}", response.error);
    serde_json::from_value(response.result.unwrap()).unwrap()
}

/// The link's socket answers before the first connect: its state with the reason, a wait that
/// answers `down` by the deadline, `failed` after a permanent error, `closed` once its owner
/// lets it go. Other admin requests are refused.
#[tokio::test]
async fn the_link_socket_answers_before_the_first_connect() {
    let dir = TempDir::new().unwrap();
    let path = dir.path().join("link.admin");
    let cell = LinkCell::new();
    let server = serve_link_cell_admin(&cell, &path).await.unwrap();
    let status = link_call(&path, AdminRequest::LinkState).await;
    assert_eq!(status, LinkStatus { state: "connecting".into(), reason: None });
    let refused = call_admin(&path, &AdminRequest::Status).await.unwrap();
    assert!(!refused.ok, "a link socket answered a daemon request");

    let watch = NetworkWatch::manual();
    let (attempts, task) = spawn_dial(
        &cell,
        ReconnectPolicy {
            initial_delay: Duration::from_millis(10),
            maximum_delay: Duration::from_secs(60),
            ..policy()
        },
        &watch,
        false,
    );
    tokio::time::timeout(Duration::from_secs(10), async {
        while !matches!(cell.phase(), LinkPhase::Disconnected { .. }) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("the first dial never parked");
    let status = link_call(&path, AdminRequest::LinkState).await;
    assert_eq!(
        status,
        LinkStatus { state: "disconnected".into(), reason: Some("nothing listens".into()) }
    );

    let before = attempts.load(Ordering::Acquire);
    let asked = std::time::Instant::now();
    let status = link_call(&path, AdminRequest::AwaitReady { within_ms: 300 }).await;
    assert_eq!(status, LinkStatus { state: "down".into(), reason: Some("nothing listens".into()) });
    assert!(
        asked.elapsed() < Duration::from_secs(2),
        "the wait answered after {:?}",
        asked.elapsed()
    );
    assert!(attempts.load(Ordering::Acquire) > before, "await-ready did not wake the parked dial");
    task.abort();

    let failing = LinkCell::new();
    let failed_path = dir.path().join("failed.admin");
    let _failed_server = serve_link_cell_admin(&failing, &failed_path).await.unwrap();
    let (_, failed) = spawn_dial(&failing, policy(), &watch, true);
    let _ = failed.await;
    let status = link_call(&failed_path, AdminRequest::LinkState).await;
    assert_eq!(
        status,
        LinkStatus { state: "failed".into(), reason: Some("authorization failed".into()) }
    );
    let status = link_call(&failed_path, AdminRequest::AwaitReady { within_ms: 5_000 }).await;
    assert_eq!(status.state, "failed", "{status:?}");

    drop(cell);
    let status = link_call(&path, AdminRequest::LinkState).await;
    assert_eq!(status, LinkStatus { state: "closed".into(), reason: None });
    drop(server);
}

/// A first dial whose every attempt hangs until the network changes, counting attempts.
fn spawn_hung_dial(
    cell: &Arc<LinkCell>,
    policy: ReconnectPolicy,
    watch: &NetworkWatch,
) -> (Arc<AtomicUsize>, tokio::task::JoinHandle<Result<(), Refused>>) {
    let attempts = Arc::new(AtomicUsize::new(0));
    let counted = attempts.clone();
    let cell = cell.clone();
    let network = watch.subscribe();
    let task = tokio::spawn(async move {
        cell.dial(policy, network, || {
            counted.fetch_add(1, Ordering::AcqRel);
            std::future::pending::<DialOutcome<(), Refused>>()
        })
        .await
    });
    (attempts, task)
}

/// A network that keeps flapping cannot outlast an attempt bound: an attempt a network change
/// abandons counts toward it (#38972 F1). Each change still redials at once.
#[tokio::test(start_paused = true)]
async fn network_flapping_cannot_outlast_a_bounded_first_dial() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (attempts, task) =
        spawn_hung_dial(&cell, ReconnectPolicy { maximum_attempts: Some(3), ..policy() }, &watch);
    for change in 1..=10 {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if task.is_finished() {
            break;
        }
        watch.signal();
        tokio::time::sleep(Duration::from_millis(1)).await;
        if change < 3 {
            assert_eq!(attempts.load(Ordering::Acquire), change + 1, "no immediate redial");
        }
    }
    assert!(
        task.is_finished(),
        "{} attempts and the bound of 3 never ended the dial",
        attempts.load(Ordering::Acquire)
    );
    assert_eq!(task.await.unwrap(), Err(Refused("network changed")));
    assert_eq!(attempts.load(Ordering::Acquire), 3);
    assert!(matches!(cell.phase(), LinkPhase::Failed { .. }), "{:?}", cell.phase());
}

/// `maximum_duration` bounds the whole first dial, failing attempts and parks included
/// (#38972 F2).
#[tokio::test(start_paused = true)]
async fn the_first_dial_ends_at_its_maximum_duration() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let (_attempts, task) = spawn_dial(
        &cell,
        ReconnectPolicy { maximum_duration: Some(Duration::from_secs(10)), ..policy() },
        &watch,
        false,
    );
    tokio::time::sleep(Duration::from_secs(11)).await;
    assert!(task.is_finished(), "the dial outlived its maximum duration");
    assert_eq!(task.await.unwrap(), Err(Refused("deadline")));
    assert!(matches!(cell.phase(), LinkPhase::Failed { .. }), "{:?}", cell.phase());
}

/// An attempt still in flight when `maximum_duration` passes is dropped then, not at its own
/// timeout (#38972 F2).
#[tokio::test(start_paused = true)]
async fn a_hung_first_dial_ends_at_its_maximum_duration() {
    let cell = LinkCell::new();
    let watch = NetworkWatch::manual();
    let started = Instant::now();
    let (attempts, task) = spawn_hung_dial(
        &cell,
        ReconnectPolicy { maximum_duration: Some(Duration::from_secs(5)), ..policy() },
        &watch,
    );
    let result = tokio::time::timeout(Duration::from_secs(60), task)
        .await
        .expect("a hung attempt outlived the maximum duration")
        .unwrap();
    assert_eq!(result, Err(Refused("deadline")));
    assert_eq!(started.elapsed(), Duration::from_secs(5));
    assert_eq!(attempts.load(Ordering::Acquire), 1);
}
