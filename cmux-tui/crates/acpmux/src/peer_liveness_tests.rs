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

/// A loaded peer (load far past its cores) answers each ping 7 to 10 s late. With a fixed 6 s
/// budget its link dropped before each answer, and every redial sent the loaded host the whole
/// watch again, so the link flapped for good. A link dropped for silence that opens straight
/// back finds a live peer, slow and not gone: from then on its late answers keep the link.
#[tokio::test(start_paused = true)]
async fn a_peer_that_answers_7_to_10_s_late_keeps_its_link_after_the_first_late_answer() {
    use futures_util::SinkExt;
    use tokio_tungstenite::tungstenite::Message as Frame;
    let (tx, _rx) = mpsc::channel(8);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    // No handshake here: the stand-in only answers late.
    Arc::get_mut(&mut peer).expect("only this test holds it").timings.handshake =
        Duration::from_secs(3_600);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let mut answered = Vec::new();
    for link in 0..2 {
        let (ours, theirs) = tokio::io::duplex(1 << 16);
        let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
        let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
        let answering = tokio::spawn(async move {
            for gap in [7u64, 10, 8, 9, 10, 7, 10, 9, 8, 10] {
                tokio::time::sleep(Duration::from_secs(gap)).await;
                if server.send(Frame::Pong(Vec::new().into())).await.is_err() {
                    return None;
                }
            }
            // Kept open: a dropped end would read as a reset on the link.
            Some(server)
        });
        let serving = peer.serve(client, &mut out_rx);
        tokio::pin!(serving);
        let kept = tokio::select! {
            biased;
            done = answering => done.unwrap().is_some(),
            ended = &mut serving => {
                answered.push(format!("link {link} ended: {ended:?}"));
                false
            }
        };
        if link == 1 {
            assert!(kept, "the redialed link to a live but slow peer is kept: {answered:?}");
        }
    }
}

/// A peer that says nothing at all is still let go within 8 s: the fast find of a dead link
/// (a dropped network, a computer that slept) stays.
#[tokio::test(start_paused = true)]
async fn a_silent_peer_still_loses_the_link_within_8_s() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let (ours, _theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let started = tokio::time::Instant::now();
    let ended = peer.serve(client, &mut out_rx).await;
    assert!(ended.expect_err("the link ends").contains("stopped answering"));
    assert!(started.elapsed() <= Duration::from_secs(8), "{:?}", started.elapsed());
}
