//! A dead link is found in seconds, and a slow one that still sends bytes is not cut
//! (`Peer::serve_heard`, `peer_link::Heard`, `Peer::ssh_connect_secs`).

use super::*;
use crate::peer_link::Heard;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
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

/// A network change checks a live link at once: one whose route went (the peer silent from
/// then on) is dropped `NETWORK_PROBE` after the change, not at the end of the silence budget,
/// and its redial starts then.
#[tokio::test(start_paused = true)]
async fn a_network_change_drops_a_dead_link_at_once() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let started = tokio::time::Instant::now();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::sleep(Duration::from_millis(500)).await;
    peer.network_changed();
    let ended = tokio::time::timeout(Duration::from_secs(10), serving).await.unwrap();
    let error = ended.unwrap().expect_err("the link ends with why");
    let took = started.elapsed();
    eprintln!(
        "dead link dropped {:.1}s after it opened (network change at 0.5s)",
        took.as_secs_f64()
    );
    assert!(error.contains("network changed"), "{error}");
    assert!(took < peer.timings.silence_budget(), "{took:?}");
    assert!(
        took <= Duration::from_millis(500) + NETWORK_PROBE + Duration::from_millis(50),
        "{took:?}"
    );
}

/// Bytes of a frame still coming in count as an answer, so a large frame on a slow link is
/// not cut by the short silence budget.
#[tokio::test(start_paused = true)]
async fn heard_counts_bytes_as_they_arrive() {
    let heard = Heard::default();
    let (ours, mut theirs) = tokio::io::duplex(64);
    let mut ours = heard.wrap(ours);
    tokio::time::advance(Duration::from_secs(5)).await;
    assert!(heard.silent() >= Duration::from_secs(5));
    theirs.write_all(b"x").await.unwrap();
    let mut byte = [0u8; 1];
    ours.read_exact(&mut byte).await.unwrap();
    assert_eq!(heard.silent(), Duration::ZERO);
}

#[tokio::test(start_paused = true)]
async fn ssh_gives_up_on_a_dead_network_in_seconds_unless_the_host_is_slow_or_waking() {
    let connect = |argv: Vec<String>| argv.iter().any(|a| a == "ConnectTimeout=3");
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ssh://box", None, None, tx.clone());
    assert_eq!(peer.ssh_connect_secs(), SSH_CONNECT_SECS);
    assert!(connect(tunnel_argv("box", 1, peer.ssh_connect_secs())));
    assert!(connect(read_config_argv("box", peer.ssh_connect_secs())));
    peer.note_ssh_failure(Some("SSH connection timed out"));
    assert_eq!(peer.ssh_connect_secs(), SSH_CONNECT_SECS, "a dead network keeps it short");
    peer.note_ssh_failure(Some(ssh_errors::BANNER_TIMEOUT));
    assert_eq!(peer.ssh_connect_secs(), SSH_CONNECT_SLOW_SECS, "a slow host gets the long one");
    let waking = Peer::new("w", "ssh://box", None, None, tx);
    waking.wake();
    assert_eq!(waking.ssh_connect_secs(), SSH_CONNECT_SLOW_SECS, "a route may resume the host");
    assert_eq!(
        ssh_errors::reason(b"Connection timed out during banner exchange"),
        Some(ssh_errors::BANNER_TIMEOUT)
    );
}
