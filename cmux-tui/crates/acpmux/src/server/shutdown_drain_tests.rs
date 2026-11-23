//! The requests in flight at the daemon's stop (`shutdown_drain.rs`, cmuxterm-hq #19255 section
//! 2): held requests on a served connection, then the stop's close, with and without the drain
//! before it. Without it every one is aborted unanswered (the base's 479 cut requests); with it
//! each is answered once as restarting and none is aborted.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::RequestStage;
use std::time::Duration;
use tokio::sync::Semaphore;

const WAIT: Duration = Duration::from_secs(10);
/// The held requests' ids start here.
const FIRST: i64 = 100;
const HELD_METHOD: &str = "_acpmux/unknown";

/// A hub that holds every [`HELD_METHOD`] request from [`FIRST`] on for good, counting each that
/// reached its hold in `reached`.
fn hub(reached: Arc<Semaphore>) -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    hub.hold_requests_for_tests(Arc::new(move |stage, m: &str, id: &Value| {
        let reached = reached.clone();
        let ours = stage == RequestStage::Dispatch
            && m == HELD_METHOD
            && id.as_i64().is_some_and(|id| id >= FIRST);
        let held: std::pin::Pin<Box<dyn Future<Output = ()> + Send>> = Box::pin(async move {
            if ours {
                reached.add_permits(1);
                std::future::pending::<()>().await;
            }
        });
        held
    }));
    hub
}

/// What one stop did.
#[derive(Debug)]
struct Stop {
    /// `conn-request` tasks the close aborted at its deadline.
    aborted: usize,
    /// Held requests answered `daemon.restarting`, each counted once per answer.
    restarting: usize,
    /// Held requests with more than one answer.
    answered_twice: usize,
    /// The answer to a request sent after the drain, if one was sent.
    late: Option<Value>,
}

/// Holds `n` requests on one served connection, then stops: the drain (when `drain`) and the
/// hub's close, as `daemon.rs` runs them.
async fn stop_with_in_flight(n: usize, drain: bool) -> Stop {
    let reached = Arc::new(Semaphore::new(0));
    let hub = hub(reached.clone());
    let (in_tx, in_rx) = mpsc::channel(1024);
    let (out_tx, mut out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    for i in 0..n {
        let id = FIRST + i64::try_from(i).unwrap();
        in_tx.send(Message::request(id, HELD_METHOD, json!({})).to_line()).await.unwrap();
    }
    let all = u32::try_from(n).unwrap();
    tokio::time::timeout(WAIT, reached.acquire_many(all))
        .await
        .expect("every request reached its hold")
        .unwrap()
        .forget();
    assert_eq!(hub.requests_in_flight(), n);
    hub.begin_shutdown();
    let mut lines = Vec::new();
    let mut late = None;
    if drain {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(1);
        let drained = shutdown_drain::drain_in_flight(&hub, deadline).await;
        assert_eq!(drained.answered, n, "{drained:?}");
        assert_eq!(hub.requests_in_flight(), 0);
        // A request read after the drain is refused the same way, never left to the close.
        in_tx.send(Message::request(1, HELD_METHOD, json!({})).to_line()).await.unwrap();
        let deadline = tokio::time::Instant::now() + WAIT;
        while late.is_none() {
            let line = tokio::time::timeout_at(deadline, out_rx.recv())
                .await
                .expect("the late request was answered")
                .expect("the connection is open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v["id"] == json!(1) {
                late = Some(v);
            } else {
                lines.push(line);
            }
        }
    }
    let reports = hub.close_owned_tasks().await;
    while let Ok(Some(line)) = tokio::time::timeout(Duration::from_millis(100), out_rx.recv()).await
    {
        lines.push(line);
    }
    count(n, &reports, &lines, late)
}

fn count(
    n: usize,
    reports: &[cmux_scope::CloseReport],
    lines: &[String],
    late: Option<Value>,
) -> Stop {
    let aborted = reports
        .iter()
        .flat_map(|r| r.still_running.iter())
        .filter(|name| name.as_str() == "conn-request")
        .count();
    let answers: Vec<Value> = lines
        .iter()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|v| v.get("method").is_none() && v["id"].as_i64().is_some_and(|id| id >= FIRST))
        .collect();
    let restarting = answers
        .iter()
        .filter(|v| {
            v["error"]["data"]["errorKind"] == json!(crate::recovery::kind::DAEMON_RESTARTING)
                && v["error"]["data"]["retryable"] == json!(true)
        })
        .count();
    let answered_twice = (0..n)
        .filter(|i| {
            let id = FIRST + i64::try_from(*i).unwrap();
            answers.iter().filter(|v| v["id"] == json!(id)).count() > 1
        })
        .count();
    Stop { aborted, restarting, answered_twice, late }
}

/// The requests in flight at the stop get the retryable restart answer, each once, and the close
/// aborts none of them; one read after the drain is refused the same way.
#[tokio::test]
async fn shutdown_drain_answers_in_flight_requests_instead_of_aborting_them() {
    let stop = stop_with_in_flight(12, true).await;
    assert_eq!(stop.aborted, 0, "{stop:?}");
    assert_eq!(stop.restarting, 12, "{stop:?}");
    assert_eq!(stop.answered_twice, 0, "{stop:?}");
    let late = stop.late.expect("a late answer");
    assert_eq!(
        late["error"]["data"]["errorKind"],
        json!(crate::recovery::kind::DAEMON_RESTARTING),
        "{late}"
    );
}

/// Before/after over one harness: a stop with 43 requests in flight (the most the findings saw
/// at once), closed as the base does (no drain) and with the drain first.
#[tokio::test]
async fn shutdown_drain_before_and_after() {
    const N: usize = 43;
    let before = stop_with_in_flight(N, false).await;
    let after = stop_with_in_flight(N, true).await;
    eprintln!(
        "drain-bench: {N} in flight; before: aborted={} restarting={}; after: aborted={} restarting={}",
        before.aborted, before.restarting, after.aborted, after.restarting
    );
    assert_eq!((before.aborted, before.restarting), (N, 0), "{before:?}");
    assert_eq!((after.aborted, after.restarting, after.answered_twice), (0, N, 0), "{after:?}");
}
