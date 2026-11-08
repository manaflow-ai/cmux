//! A reconnect's round trips before its link is ready, against a peer one round trip away that
//! answers each request on its own, as a daemon does: the watch goes out with `initialize`
//! (`Peer::pipelined_watch`), and the chats the link had are replayed at once, not in turn.

use super::*;
use futures_util::StreamExt;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// The round trip to the fake peer, on the paused clock: the remote-reconnect probe's relay.
const RTT: Duration = Duration::from_millis(40);

/// What the fake peer's `initialize` says.
#[derive(Clone)]
struct Hello {
    origin: &'static str,
    features: Vec<&'static str>,
}

impl Hello {
    fn pipelines() -> Self {
        Self { origin: "peer", features: vec![HANDSHAKE_PIPELINE_FEATURE] }
    }
}

/// A fake peer [`RTT`] away: every request is answered `RTT` after it arrives, each on its own;
/// `initialize` as `hello()` says, the n-th `_acpmux/watch` with one row `w{n}`, a replay page
/// with no more events. Sends each request's method on `asked`, in arrival order.
fn distant_peer(
    server: WebSocketStream<tokio::io::DuplexStream>,
    hello: Hello,
    asked: mpsc::UnboundedSender<String>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let (mut sink, mut source) = server.split();
        let (out_tx, mut out_rx) = mpsc::unbounded_channel::<String>();
        let writer = tokio::spawn(async move {
            while let Some(line) = out_rx.recv().await {
                if sink.send(Frame::Text(line.into())).await.is_err() {
                    return;
                }
            }
        });
        let mut watches = 0;
        while let Some(Ok(frame)) = source.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let m = msg["method"].as_str().unwrap_or_default().to_owned();
            // The handshake's own requests (a health read may follow it).
            if matches!(m.as_str(), method::INITIALIZE | method::MUX_WATCH | method::MUX_ATTACH) {
                let _ = asked.send(m.clone());
            }
            let result = match m.as_str() {
                method::INITIALIZE => json!({"_meta": {"acpmux": {
                    "origin": hello.origin, "build": "b1", "features": hello.features}}}),
                method::MUX_WATCH => {
                    watches += 1;
                    json!({"sessions": [{"sessionId": format!("w{watches}"), "updatedAt": 5}]})
                }
                method::MUX_ATTACH => json!({"events": [], "hasMore": false}),
                _ => json!({}),
            };
            let line = Message::ok(id, result).to_line().trim_end().to_owned();
            let out = out_tx.clone();
            tokio::spawn(async move {
                tokio::time::sleep(RTT).await;
                let _ = out.send(line);
            });
        }
        drop(out_tx);
        let _ = writer.await;
    })
}

/// One link to a [`distant_peer`], until it is ready, then dropped as a dead link is: how long
/// it took, what it asked for in order, and the rows of every list it published.
async fn link_once(
    peer: &Arc<Peer>,
    out_rx: mpsc::Receiver<Outbound>,
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    hello: Hello,
) -> (Duration, Vec<String>, Vec<Vec<String>>, mpsc::Receiver<Outbound>) {
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, mut asked) = mpsc::unbounded_channel();
    let fake = distant_peer(server, hello, asked_tx);
    let started = tokio::time::Instant::now();
    let link = peer.clone();
    let serving = tokio::spawn(async move {
        let mut out_rx = out_rx;
        let _ = link.serve(client, &mut out_rx).await;
        out_rx
    });
    let mut lists = Vec::new();
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(30), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => lists.push(
                rows.iter()
                    .map(|r| r["sessionId"].as_str().unwrap_or_default().to_owned())
                    .collect(),
            ),
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    let took = started.elapsed();
    fake.abort();
    let out_rx = serving.await.unwrap();
    peer.finish_link(Err("dropped".to_owned()), &mut Backoff::default());
    let mut methods = Vec::new();
    while let Ok(m) = asked.try_recv() {
        methods.push(m);
    }
    (took, methods, lists, out_rx)
}

fn round_trips(took: Duration) -> f64 {
    took.as_secs_f64() / RTT.as_secs_f64()
}

/// The first link learns the peer pipelines; every reconnect after it sends its watch with
/// `initialize` and is ready one round trip after the link opened, not two.
#[tokio::test(start_paused = true)]
async fn a_reconnect_sends_its_watch_with_initialize() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("far", "ws://127.0.0.1:9", None, None, tx);
    let out_rx = peer.out_rx.lock().await.take().unwrap();
    let (first, asked, _, out_rx) =
        link_once(&peer, out_rx, &mut notices, Hello::pipelines()).await;
    assert_eq!(asked, [method::INITIALIZE, method::MUX_WATCH]);
    let (again, asked, lists, _) = link_once(&peer, out_rx, &mut notices, Hello::pipelines()).await;
    eprintln!("first link {:.1} RTT, reconnect {:.1} RTT", round_trips(first), round_trips(again));
    assert_eq!(asked, [method::INITIALIZE, method::MUX_WATCH], "one watch, sent with initialize");
    assert_eq!(lists, [vec!["w1".to_owned()]], "the pipelined watch's list is published");
    assert!(again < RTT * 2, "a reconnect waits one round trip for its handshake, took {again:?}");
}

/// A peer that does not list the feature may set what its `initialize` sets after a watch sent
/// with it runs: it is asked in turn.
#[tokio::test(start_paused = true)]
async fn a_peer_that_does_not_pipeline_is_asked_in_turn() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("old", "ws://127.0.0.1:9", None, None, tx);
    let older = Hello { origin: "peer", features: vec![] };
    let out_rx = peer.out_rx.lock().await.take().unwrap();
    let (_, _, _, out_rx) = link_once(&peer, out_rx, &mut notices, older.clone()).await;
    let (again, asked, _, _) = link_once(&peer, out_rx, &mut notices, older).await;
    assert_eq!(asked, [method::INITIALIZE, method::MUX_WATCH]);
    assert!(again >= RTT * 2, "{again:?}");
}

/// A watch sent with `initialize` whose reply says it was not the one to ask (the peer serves
/// this daemon as Web now) is never published: the link asks again, and only that list is.
#[tokio::test(start_paused = true)]
async fn a_pipelined_watch_the_initialize_reply_rules_out_is_not_published() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("moved", "ws://127.0.0.1:9", None, None, tx);
    let out_rx = peer.out_rx.lock().await.take().unwrap();
    let (_, _, _, out_rx) = link_once(&peer, out_rx, &mut notices, Hello::pipelines()).await;
    let web = Hello { origin: "remote", features: vec![HANDSHAKE_PIPELINE_FEATURE] };
    let (_, asked, lists, _) = link_once(&peer, out_rx, &mut notices, web).await;
    assert_eq!(asked, [method::INITIALIZE, method::MUX_WATCH, method::MUX_WATCH]);
    assert_eq!(lists, [vec!["w2".to_owned()]], "only the list asked for after initialize");
}

/// A link that had several chats replays them at once: its handshake waits one round trip for
/// the replay, not one per chat.
#[tokio::test(start_paused = true)]
async fn a_reconnect_replays_its_chats_at_once() {
    let (tx, mut notices) = mpsc::channel(256);
    let peer = Peer::new("busy", "ws://127.0.0.1:9", None, None, tx);
    let out_rx = peer.out_rx.lock().await.take().unwrap();
    let (_, _, _, out_rx) = link_once(&peer, out_rx, &mut notices, Hello::pipelines()).await;
    for n in 0..8 {
        let sid = format!("chat-{n}");
        peer.mark_attached(&sid);
        peer.note_hidden_attach_page(&sid, &json!({"events": [], "pageThrough": 10}));
    }
    let (again, asked, _, _) = link_once(&peer, out_rx, &mut notices, Hello::pipelines()).await;
    eprintln!("reconnect with 8 chats {:.1} RTT", round_trips(again));
    assert_eq!(asked.iter().filter(|m| *m == method::MUX_ATTACH).count(), 8);
    assert!(
        again < RTT * 3,
        "the watch goes with initialize and the 8 replays take one round trip, took {again:?}"
    );
}
