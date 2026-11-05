//! Close 1012 reconnect behavior, using only public APIs present on the unfixed base.

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::peer::Peer;
use acpmux::peer_link::Backoff;
use futures_util::SinkExt;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio::time::{Instant, timeout, timeout_at};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::CloseFrame};

#[tokio::test]
async fn close_1012_reports_restarting_retries_immediately_then_resumes_failure_backoff() {
    let _ = HERMETIC;
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}", listener.local_addr().unwrap());
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("restart-test", &url, None, None, tx);
    let running = tokio::spawn(peer.clone().run());
    let (first, _) = timeout(Duration::from_secs(5), listener.accept()).await.unwrap().unwrap();
    let mut server = timeout(Duration::from_secs(5), tokio_tungstenite::accept_async(first))
        .await
        .unwrap()
        .unwrap();

    // Close before answering initialize: no session-list/ready notices precede this outcome.
    let restarting_at = Instant::now();
    server
        .send(Frame::Close(Some(CloseFrame {
            code: CloseCode::Restart,
            reason: "service restarting".into(),
        })))
        .await
        .unwrap();
    timeout(Duration::from_secs(5), notices.recv()).await.unwrap().unwrap();
    let summary = peer.summary();
    assert_eq!(summary["state"], "restarting", "Close 1012 is a deliberate restart: {summary}");
    assert_eq!(summary["connected"], false);
    assert!(summary["error"].is_null(), "restart is not a transport error: {summary}");

    // Sooner than the shortest ordinary backoff step (half of `Backoff::BASE`), so this is the
    // restart's own immediate retry and not a backoff wait.
    let (retry, _) = timeout_at(restarting_at + Backoff::BASE / 2, listener.accept())
        .await
        .expect("Close 1012 must retry at once, without the ordinary backoff wait")
        .unwrap();
    assert!(restarting_at.elapsed() < Backoff::BASE / 2);

    // Reset the immediate retry during its WebSocket handshake. The restart exception is
    // consumed: an actual failure waits its ordinary first backoff step before it tries again
    // (at least half of `Backoff::BASE`, 250 ms since #28646 made the base 0.5 s), and still
    // retries.
    let failed_at = Instant::now();
    drop(retry);
    timeout(Duration::from_secs(5), notices.recv()).await.unwrap().unwrap();
    let summary = peer.summary();
    assert_eq!(
        summary["state"], "reconnecting",
        "a failed retry is an ordinary failure: {summary}"
    );
    assert!(summary["error"].is_string());
    let (_next, _) = timeout(Duration::from_secs(3), listener.accept())
        .await
        .expect("ordinary reconnect backoff still retries")
        .unwrap();
    // Measured from before the reset: the backoff wait starts only once the failure is seen.
    let waited = failed_at.elapsed();
    assert!(
        waited >= Backoff::BASE / 2,
        "the failed retry must not inherit the immediate-retry exception: it came after {waited:?}"
    );

    peer.stop();
    // End the unfinished handshake so run observes stop.
    drop(_next);
    timeout(Duration::from_secs(5), running).await.unwrap().unwrap();
}
