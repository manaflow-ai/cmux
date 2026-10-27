//! p01-process-206: a provider tab's bootstrap is a lane of the browser pool
//! that parks in the provider registry. It ends, and drops its registry
//! watcher, when its surface dies or the mux shuts down, and a failed attach
//! tries again at its backoff deadline with no registry change.

use std::collections::BTreeMap;
use std::net::TcpListener;
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

use serde_json::json;

use super::*;
use crate::browser_provider::{
    BrowserProviderAuthentication, BrowserProviderHosting, BrowserProviderRegistration,
};
use crate::{Surface, SurfaceOptions};

const WAIT: Duration = Duration::from_secs(10);

fn create_request(idempotency_key: &str) -> ParsedResourceRequest {
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"test-tab.create_browser",
        "operation":"tab.create_browser",
        "params":{"machine":"current","session":"current","url":"about:blank"},
        "idempotency_key":idempotency_key,
    });
    parse_resource_request(&serde_json::to_string(&envelope).unwrap()).unwrap()
}

/// Waits until `check` holds (test-only polling of the pool and registry).
fn eventually(check: impl Fn() -> bool) -> bool {
    let deadline = Instant::now() + WAIT;
    while Instant::now() < deadline {
        if check() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
    check()
}

/// A daemon-rendered browser tab made while the test provider is attached,
/// once its provider bootstrap parked in the registry.
fn parked_provider_tab(mux: &Arc<Mux>) -> Arc<Surface> {
    mux.attach_test_browser_provider(1);
    dispatch_resource_request(mux, create_request("create-1")).unwrap();
    let surface = mux
        .with_state(|state| state.surfaces.values().find(|s| s.as_browser().is_some()).cloned())
        .expect("the created browser tab");
    let providers = mux.browser_provider_registry();
    assert!(
        eventually(|| providers.watcher_count() == 1),
        "the provider bootstrap never parked in the registry"
    );
    surface
}

#[test]
fn a_parked_provider_bootstrap_lane_ends_when_its_surface_is_killed() {
    let mux = Mux::new_for_test("provider-bootstrap-kill", SurfaceOptions::default());
    let lanes = mux.browser_lanes();
    let before = lanes.lanes();
    let surface = parked_provider_tab(&mux);
    assert!(lanes.lanes() > before);
    surface.kill();
    let providers = mux.browser_provider_registry();
    assert!(
        eventually(|| lanes.lanes() == before),
        "{} lanes stayed after the kill (had {before})",
        lanes.lanes()
    );
    assert_eq!(providers.watcher_count(), 0, "the bootstrap left its registry watcher");
}

#[test]
fn a_parked_provider_bootstrap_lane_ends_when_the_mux_shuts_down() {
    let mux = Mux::new_for_test("provider-bootstrap-shutdown", SurfaceOptions::default());
    let lanes = mux.browser_lanes();
    let before = lanes.lanes();
    let surface = parked_provider_tab(&mux);
    let providers = mux.browser_provider_registry();
    mux.shutdown();
    assert!(
        eventually(|| lanes.lanes() == before),
        "{} lanes stayed after shutdown (had {before})",
        lanes.lanes()
    );
    assert_eq!(providers.watcher_count(), 0, "the bootstrap left its registry watcher");
    drop(surface);
}

/// A daemon shutdown request cancels the bootstrap while its surface lives
/// on for the next daemon: the lane ends on the mux's shutdown flag alone.
#[test]
fn a_parked_provider_bootstrap_lane_ends_on_a_daemon_shutdown_request() {
    let mux = Mux::new_for_test("provider-bootstrap-request", SurfaceOptions::default());
    let lanes = mux.browser_lanes();
    let surface = parked_provider_tab(&mux);
    let with_bootstrap = lanes.lanes();
    let providers = mux.browser_provider_registry();
    mux.request_daemon_shutdown();
    assert!(!surface.is_dead());
    assert!(
        eventually(|| lanes.lanes() == with_bootstrap - 1),
        "{} lanes after the shutdown request (had {with_bootstrap} with the bootstrap)",
        lanes.lanes()
    );
    assert_eq!(providers.watcher_count(), 0, "the bootstrap left its registry watcher");
    surface.kill();
}

/// A CDP endpoint that refuses every attach: it reports each connection
/// and closes it before the WebSocket handshake.
fn refusing_endpoint() -> (String, Receiver<Instant>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (accepted_tx, accepted) = channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            drop(stream);
            if accepted_tx.send(Instant::now()).is_err() {
                return;
            }
        }
    });
    (format!("ws://127.0.0.1:{port}/devtools/browser/test"), accepted)
}

#[test]
fn a_failed_provider_attach_tries_again_at_its_backoff_deadline() {
    let mux = Mux::new_for_test("provider-bootstrap-backoff", SurfaceOptions::default());
    let lanes = mux.browser_lanes();
    let before = lanes.lanes();
    let surface = parked_provider_tab(&mux);
    let tab_id = surface.resource_identity().unwrap().tab_id.clone();
    let (endpoint, attempts) = refusing_endpoint();
    mux.register_browser_provider(
        1,
        BrowserProviderRegistration {
            provider_id: "test-provider".to_string(),
            endpoint: endpoint.clone(),
            authentication: BrowserProviderAuthentication::None,
            hosting: BrowserProviderHosting::Daemon,
            targets: BTreeMap::from([(tab_id, "target-1".to_string())]),
        },
    )
    .unwrap();
    let first = attempts.recv_timeout(WAIT).expect("the published target was never attached");
    let browser = surface.as_browser().unwrap();
    assert!(
        eventually(|| matches!(browser.status(), crate::BrowserStatus::Failed(_))),
        "the refused attach did not fail the tab"
    );
    // No registry change from here on: only the backoff deadline retries.
    let second = attempts.recv_timeout(WAIT).expect("the failed attach was never tried again");
    assert!(
        second.duration_since(first) >= Duration::from_millis(200),
        "the retry did not wait for its backoff: {:?}",
        second.duration_since(first)
    );
    let third = attempts.recv_timeout(WAIT).expect("the retry was not tried again");
    assert!(
        third.duration_since(second) > second.duration_since(first),
        "the backoff did not grow"
    );
    surface.kill();
    assert!(
        eventually(|| lanes.lanes() == before),
        "{} lanes stayed after the kill (had {before})",
        lanes.lanes()
    );
    drop(attempts);
    // Unblocks the endpoint's accept so its thread sees the closed channel.
    let _ = std::net::TcpStream::connect(
        endpoint.trim_start_matches("ws://").split('/').next().unwrap(),
    );
}
