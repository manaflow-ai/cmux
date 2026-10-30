//! What a peer link reports and does around its handshake and its drops (`peer.rs`): connected
//! only once the handshake finished, a request queued on a link that drops fails as not sent
//! (and never goes out on the next), and a request's deadline counts its time in the queue.

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

fn reason(e: &RpcError) -> Option<&str> {
    e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str)
}

/// HQ #2894: the WebSocket opening is not the peer being connected. While the peer has not
/// answered `_acpmux/watch`, the peer reads not connected (`handshaking`), and a caller's
/// request is refused as not sent rather than racing the handshake; once the watch is answered
/// it reads connected.
#[tokio::test]
async fn a_peer_reads_connected_only_once_its_handshake_finished() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

    // The fake peer answers every request at once but holds its watch reply until released,
    // and reports each method it reads.
    let (seen_tx, mut seen) = mpsc::unbounded_channel::<String>();
    let (release_tx, release) = oneshot::channel::<()>();
    let fake = tokio::spawn(async move {
        let mut release = Some(release);
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let m = msg["method"].as_str().unwrap_or_default().to_owned();
            let _ = seen_tx.send(m.clone());
            let Some(id) = msg.get("id").cloned() else { continue };
            let result = if m == method::MUX_WATCH {
                if let Some(release) = release.take() {
                    let _ = release.await;
                }
                json!({"sessions": []})
            } else {
                json!({})
            };
            let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
            server.send(Frame::Text(reply.to_string().into())).await.unwrap();
        }
    });

    let mut methods = Vec::new();
    while !methods.iter().any(|m| m == method::MUX_WATCH) {
        let m = tokio::time::timeout(Duration::from_secs(5), seen.recv())
            .await
            .expect("the handshake reaches its watch")
            .expect("the fake peer runs");
        methods.push(m);
    }
    let summary = peer.summary();
    assert_eq!(summary["connected"], false, "connected before the handshake finished: {summary}");
    assert_eq!(summary["handshaking"], true, "{summary}");
    assert_eq!(summary["state"], "degraded", "{summary}");
    let early =
        tokio::time::timeout(Duration::from_secs(2), peer.request("_acpmux/early", json!({})))
            .await
            .expect("a request during the handshake is refused at once, not sent");
    let e = early.expect_err("a request during the handshake is refused");
    assert_eq!(reason(&e), Some("peer_unreachable"), "{e:?}");

    release_tx.send(()).unwrap();
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), notices.recv())
            .await
            .expect("the handshake settles")
            .expect("the link stays open");
        if matches!(notice, PeerNotice::Connected) {
            break;
        }
    }
    let summary = peer.summary();
    assert_eq!(summary["connected"], true, "{summary}");
    assert_eq!(summary["handshaking"], false, "{summary}");
    assert_eq!(summary["state"], "connected", "{summary}");
    // A request now goes out and is answered; the peer read no `early` before it.
    tokio::time::timeout(Duration::from_secs(5), peer.request("_acpmux/later", json!({})))
        .await
        .expect("answered")
        .expect("a request once connected goes out");
    while let Ok(m) = seen.try_recv() {
        methods.push(m);
    }
    assert!(methods.iter().any(|m| m == "_acpmux/later"), "{methods:?}");
    assert!(
        !methods.iter().any(|m| m == "_acpmux/early"),
        "sent during the handshake: {methods:?}"
    );
    serving.abort();
    fake.abort();
}

/// HQ #2892: a request still queued when its link drops never went out. Its caller is told so
/// (`peer_unreachable`, retryable, not sent) rather than `peer disconnected`, and the frame is
/// gone from the queue, so the next link never sends it.
#[tokio::test]
async fn a_request_queued_when_its_link_drops_fails_as_not_sent() {
    // A port nothing listens on: every connect fails at once.
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("box", &format!("ws://127.0.0.1:{port}"), None, None, tx);
    let asking = peer.clone();
    let ask =
        tokio::spawn(async move { asking.link_request_on("_acpmux/probe", json!({}), None).await });
    tokio::time::timeout(Duration::from_secs(5), async {
        while peer.out.capacity() == peer.out.max_capacity() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the request is queued");

    // The link loop's attempt fails: the queued request's link is gone.
    let running = tokio::spawn(peer.clone().run());
    let answer = tokio::time::timeout(Duration::from_secs(10), ask)
        .await
        .expect("the queued request is failed when its link ends")
        .unwrap();
    let e = answer.expect_err("a request on a link that dropped fails");
    assert_eq!(reason(&e), Some("peer_unreachable"), "{e:?}");
    let data = e.data.clone().unwrap();
    assert_eq!(data["detail"], "the request was not sent", "{e:?}");
    assert_eq!(data["retryable"], true, "{e:?}");
    assert_eq!(peer.pending_requests().await, 0);
    peer.stop();
    let _ = tokio::time::timeout(Duration::from_secs(10), running).await;
}

/// When a link drops, a request that went out on it fails as `peer_disconnected` (the peer may
/// have run it), and one still queued as `peer_unreachable` (not sent, safe to retry).
#[tokio::test]
async fn a_drop_fails_what_went_out_as_disconnected_and_what_did_not_as_not_sent() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move {
        let ended = link.serve(client, &mut out_rx).await;
        (ended, out_rx)
    });
    // The fake peer answers the handshake, reads `_acpmux/slow` and closes the link unanswered.
    let fake = tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            if msg["method"] == "_acpmux/slow" {
                let _ = server.close(None).await;
                return;
            }
            let Some(id) = msg.get("id").cloned() else { continue };
            let result = if msg["method"] == method::MUX_WATCH {
                json!({"sessions": []})
            } else {
                json!({})
            };
            let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
            server.send(Frame::Text(reply.to_string().into())).await.unwrap();
        }
    });
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), notices.recv())
            .await
            .expect("the handshake settles")
            .expect("the link stays open");
        if matches!(notice, PeerNotice::Connected) {
            break;
        }
    }
    let asking = peer.clone();
    let sent = tokio::spawn(async move { asking.request("_acpmux/slow", json!({})).await });
    let (_ended, mut out_rx) = tokio::time::timeout(Duration::from_secs(5), serving)
        .await
        .expect("the link drops")
        .unwrap();
    // What `run` does when a link ends, with one request still in the queue.
    peer.link_ended();
    let asking = peer.clone();
    let queued =
        tokio::spawn(
            async move { asking.link_request_on("_acpmux/queued", json!({}), None).await },
        );
    tokio::time::timeout(Duration::from_secs(5), async {
        while peer.out.capacity() == peer.out.max_capacity() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the second request is queued");
    peer.fail_link_requests(&mut out_rx).await;

    let sent = sent.await.unwrap().expect_err("the link dropped");
    assert_eq!(reason(&sent), Some("peer_disconnected"), "{sent:?}");
    let queued = queued.await.unwrap().expect_err("the link dropped");
    assert_eq!(reason(&queued), Some("peer_unreachable"), "{queued:?}");
    assert!(out_rx.try_recv().is_err(), "a stale frame stayed queued for the next link");
    fake.abort();
}

type Notices = mpsc::Receiver<(String, u64, PeerNotice)>;

/// A peer whose queue is full and that nothing reads: a stalled link. The notices channel is
/// returned so it stays open for the test.
async fn stalled_peer(request: Duration) -> (Arc<Peer>, Notices) {
    let (tx, notices) = mpsc::channel(8);
    let mut peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    Arc::get_mut(&mut peer).unwrap().timings.request = request;
    peer.connected.store(true, Ordering::SeqCst);
    for _ in 0..1024 {
        peer.notify("_acpmux/filler", json!({})).await.unwrap();
    }
    (peer, notices)
}

/// HQ #2900: a request that waits for room in the queue of a stalled link times out on its
/// deadline, and is told it was not sent, instead of waiting for room with no deadline at all.
#[tokio::test(start_paused = true)]
async fn a_request_that_never_gets_into_the_queue_times_out_on_schedule() {
    let (peer, _notices) = stalled_peer(Duration::from_secs(60)).await;
    let started = tokio::time::Instant::now();
    let answer = tokio::time::timeout(
        Duration::from_secs(600),
        peer.link_request_on("_acpmux/probe", json!({}), None),
    )
    .await
    .expect("a request on a stalled link must time out on its own deadline");
    let e = answer.expect_err("it times out");
    assert_eq!(reason(&e), Some("peer_unreachable"), "{e:?}");
    assert_eq!(e.data.as_ref().unwrap()["detail"], "the request was not sent");
    assert_eq!(started.elapsed(), Duration::from_secs(60));
    assert_eq!(peer.pending_requests().await, 0);
}

/// HQ #2900: the time a request spent queued counts toward its deadline: queued 40 s of a 60 s
/// deadline, it has 20 s left for the answer, not another 60 s.
#[tokio::test(start_paused = true)]
async fn the_time_a_request_waits_in_the_queue_counts_toward_its_deadline() {
    let (peer, _notices) = stalled_peer(Duration::from_secs(60)).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    // The link takes one frame after 40 s, which makes room for the request, and never answers.
    let taker = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(40)).await;
        let _ = out_rx.recv().await;
        out_rx
    });
    let started = tokio::time::Instant::now();
    let answer = tokio::time::timeout(
        Duration::from_secs(600),
        peer.link_request_on("_acpmux/probe", json!({}), None),
    )
    .await
    .expect("the request times out");
    assert!(answer.is_err(), "{answer:?}");
    assert_eq!(started.elapsed(), Duration::from_secs(60), "queue time not counted");
    let _keep = taker.await.unwrap();
}
