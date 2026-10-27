//! Frame demand of a natively hosted page: a failing screencast start or stop
//! is retried on the shared backoff, not on a fixed period.

use super::*;
use crate::browser_provider::{BrowserProviderAuthentication, BrowserProviderHosting};

/// A native-hosted provider whose first `failures` Page.stopScreencast calls
/// fail and whose next one succeeds; each reply is sent once the test asks.
fn native_runtime_failing_stops(
    failures: usize,
) -> (Arc<super::super::BrowserRuntime>, thread::JoinHandle<()>, mpsc::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (reply_tx, reply_rx) = mpsc::channel::<()>();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
        for attempt in 0..=failures {
            let stop = read_ws_json(&mut ws);
            assert_eq!(stop["method"], "Page.stopScreencast");
            if reply_rx.recv_timeout(BROWSER_TEST_SAFETY_BOUND).is_err() {
                return;
            }
            let reply = if attempt < failures {
                json!({"id": stop["id"], "error": {"message": "screencast refused"}})
            } else {
                json!({"id": stop["id"], "result": {}})
            };
            write_ws_json(&mut ws, reply);
        }
    });
    let runtime = super::super::BrowserRuntime::connect_provider(
        &format!("ws://{addr}/devtools/browser/fake"),
        &BrowserProviderAuthentication::None,
        BrowserProviderHosting::Native,
    )
    .unwrap();
    (runtime, server, reply_tx)
}

#[test]
fn failed_frame_demand_retries_back_off_and_a_success_resets_them() {
    let (runtime, server, reply) = native_runtime_failing_stops(2);
    let surface = test_surface();
    let browser = surface.as_browser().expect("browser surface");
    *browser.session.lock().unwrap() = Some(BrowserSession {
        runtime: runtime.clone(),
        target_id: "target-1".to_string(),
        session_id: "session-1".to_string(),
    });

    // No viewer: the page's screencast stops, and the stop fails.
    reply.send(()).unwrap();
    let first_call = Instant::now();
    browser.reconcile_frame_demand();
    let first_retry = browser.frame_demand_retry_at().expect("a failed stop is retried");
    let first_delay = first_retry.saturating_duration_since(first_call);

    // The retry is due: it fails again and waits longer than a fixed period.
    browser.state.lock().unwrap().frame_demand_retry_at = Some(Instant::now());
    reply.send(()).unwrap();
    let second_call = Instant::now();
    browser.reconcile_frame_demand();
    let second_retry = browser.frame_demand_retry_at().expect("a second failed stop is retried");
    let second_delay = second_retry.saturating_duration_since(second_call);
    assert!(
        second_delay > first_delay && second_delay >= Duration::from_millis(800),
        "the second retry backs off: first {first_delay:?}, second {second_delay:?}"
    );

    // A success clears the retry and the backoff.
    browser.state.lock().unwrap().frame_demand_retry_at = Some(Instant::now());
    reply.send(()).unwrap();
    browser.reconcile_frame_demand();
    assert_eq!(browser.frame_demand_retry_at(), None);
    assert!(browser.screencast_paused());
    assert_eq!(browser.state.lock().unwrap().frame_demand_backoff.attempts(), 0);

    drop(reply);
    server.join().unwrap();
}
