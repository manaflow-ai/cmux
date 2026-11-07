//! A dead link is found in seconds, and a slow one that still sends bytes is not cut.

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::protocol::Role;

/// A network that drops every packet (a closed lid, a dead Wi-Fi): the peer's end stays open
/// and says nothing. The link used to wait out 4 pings 20 s apart, 80 s, before its redial.
#[tokio::test(start_paused = true)]
async fn a_silent_peer_loses_the_link_within_seconds() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let started = tokio::time::Instant::now();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let ended = tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("a silent peer loses the link within 10 s");
    let error = ended.unwrap().expect_err("the link ends with why");
    assert!(error.contains("stopped answering"), "{error}");
    assert!(started.elapsed() >= peer.timings.silence_budget(), "{:?}", started.elapsed());
}
