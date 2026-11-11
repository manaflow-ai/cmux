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
    /// How long after it arrives `initialize` is answered.
    initialize_after: Duration,
    /// Set: right after its watch reply the peer asks for a GitHub action, as a machine this
    /// Mac lends GitHub does once its watch is answered (`hub/github_owner.rs`), and the answer
    /// it gets is sent here.
    github: Option<mpsc::UnboundedSender<Value>>,
    /// How many of its first `_acpmux/attach`es fail with an internal error, as one that timed
    /// out or found the queue full does (the peer never refuses them).
    attach_failures: usize,
}

impl Hello {
    fn pipelines() -> Self {
        Self {
            origin: "peer",
            features: vec![HANDSHAKE_PIPELINE_FEATURE],
            initialize_after: RTT,
            github: None,
            attach_failures: 0,
        }
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
        let mut attaches = 0;
        while let Some(Ok(frame)) = source.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            // An answer to the peer's own GitHub action.
            if msg.get("method").is_none() {
                if let Some(github) = &hello.github {
                    let _ = github.send(msg);
                }
                continue;
            }
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
            let failed = m == method::MUX_ATTACH && {
                attaches += 1;
                attaches <= hello.attach_failures
            };
            let reply = if failed {
                Message::err(id, RpcError::internal("peer request timed out"))
            } else {
                Message::ok(id, result)
            };
            let line = reply.to_line().trim_end().to_owned();
            let ask = (m == method::MUX_WATCH && hello.github.is_some()).then(|| {
                let ask = Message::request(json!("gh-1"), method::MUX_GITHUB_ACTION, json!({}));
                ask.to_line().trim_end().to_owned()
            });
            let after = if m == method::INITIALIZE { hello.initialize_after } else { RTT };
            let out = out_tx.clone();
            tokio::spawn(async move {
                tokio::time::sleep(after).await;
                let _ = out.send(line);
                if let Some(ask) = ask {
                    let _ = out.send(ask);
                }
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
    link_once_then(peer, out_rx, notices, hello, None).await.0
}

/// [`link_once`], and once the link is ready, before it is dropped, the first message `then`
/// receives.
async fn link_once_then(
    peer: &Arc<Peer>,
    out_rx: mpsc::Receiver<Outbound>,
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    hello: Hello,
    then: Option<&mut mpsc::UnboundedReceiver<Value>>,
) -> ((Duration, Vec<String>, Vec<Vec<String>>, mpsc::Receiver<Outbound>), Option<Value>) {
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
    let received = match then {
        Some(rx) => Some(
            tokio::time::timeout(Duration::from_secs(30), rx.recv())
                .await
                .expect("an answer comes")
                .expect("the peer stays open"),
        ),
        None => None,
    };
    fake.abort();
    let out_rx = serving.await.unwrap();
    peer.finish_link(Err("dropped".to_owned()), &mut Backoff::default());
    let mut methods = Vec::new();
    while let Ok(m) = asked.try_recv() {
        methods.push(m);
    }
    ((took, methods, lists, out_rx), received)
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
    let older = Hello { features: vec![], ..Hello::pipelines() };
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
    let web = Hello { origin: "remote", ..Hello::pipelines() };
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

/// Review of #38298 at 7d865c96 (F1): a machine this Mac lends GitHub asks for an action as soon
/// as it has sent its watch answer. Over a pipelined watch that answer is held until the
/// `initialize` reply settles it, and the action, read meanwhile, was refused with "this Mac
/// does not lend its GitHub login". It waits for the watch instead, and is let in.
#[tokio::test(start_paused = true)]
async fn a_github_action_asked_after_a_held_pipelined_watch_waits_for_it() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("lends", "ws://127.0.0.1:9", None, None, tx);
    peer.set_github_broker(true);
    let out_rx = peer.out_rx.lock().await.take().unwrap();
    let (_, _, _, out_rx) = link_once(&peer, out_rx, &mut notices, Hello::pipelines()).await;
    let (github_tx, mut github_rx) = mpsc::unbounded_channel();
    // The watch's reply, and the action after it, arrive before the `initialize` reply.
    let slow = Hello { initialize_after: RTT * 3, github: Some(github_tx), ..Hello::pipelines() };
    let ((_, asked, lists, _), answer) =
        link_once_then(&peer, out_rx, &mut notices, slow, Some(&mut github_rx)).await;
    assert_eq!(asked, [method::INITIALIZE, method::MUX_WATCH], "the watch went with initialize");
    assert_eq!(lists, [vec!["w1".to_owned()]], "the pipelined watch was kept");
    let answer = answer.unwrap();
    assert_eq!(answer["id"], "gh-1");
    assert_ne!(answer.pointer("/error/data/reason"), Some(&json!("github.denied")), "{answer}");
    // Let in: the broker read the (empty) action itself.
    let message = answer.pointer("/error/message").and_then(Value::as_str).unwrap_or_default();
    assert!(message.contains("invalid GitHub action"), "{answer}");
}

/// A reconnect attaches a chat it has no replay cursor for (its first attach never answered, a
/// replay page failed, an older peer gave no `pageThrough`) without history: what the peer sent
/// between the links never streams. The link says so for that chat once it is attached again,
/// so its clients read the hole themselves; a chat replayed from its cursor lost nothing and
/// gets no such notice.
#[tokio::test(start_paused = true)]
async fn a_chat_attached_again_without_history_is_reported_as_lagged() {
    let (tx, mut notices) = mpsc::channel(256);
    let peer = Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    peer.mark_attached("fresh");
    peer.mark_attached("known");
    peer.note_hidden_attach_page("known", &json!({"events": [], "pageThrough": 10}));

    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, _asked) = mpsc::unbounded_channel();
    let fake = distant_peer(server, Hello::pipelines(), asked_tx);
    let link = peer.clone();
    let serving = tokio::spawn(async move {
        let _ = link.serve(client, &mut out_rx).await;
    });
    let mut connected = false;
    let mut reattached = Vec::new();
    // Every notice of the handshake and the attaches after it, until the link goes quiet.
    while let Ok(Some((_, _, notice))) = tokio::time::timeout(RTT * 10, notices.recv()).await {
        match notice {
            PeerNotice::Connected => connected = true,
            PeerNotice::Notification { method: m, params, .. } if m == REATTACHED_NOTICE => {
                assert!(connected, "told before the link was ready");
                reattached.push(params["sessionId"].as_str().unwrap().to_owned());
            }
            _ => {}
        }
    }
    assert!(connected, "the link connects");
    assert_eq!(reattached, ["fresh"], "only the chat attached without history lagged");
    fake.abort();
    serving.abort();
    peer.stop();
}

/// A link to a [`distant_peer`] that stays up: the fake, the link's task, and the handshake
/// methods the peer was asked for, in order.
async fn open_link(
    peer: &Arc<Peer>,
    hello: Hello,
) -> (tokio::task::JoinHandle<()>, tokio::task::JoinHandle<()>, mpsc::UnboundedReceiver<String>) {
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, asked) = mpsc::unbounded_channel();
    let fake = distant_peer(server, hello, asked_tx);
    let link = peer.clone();
    let serving = tokio::spawn(async move {
        let _ = link.serve(client, &mut out_rx).await;
    });
    (fake, serving, asked)
}

/// The chats the link said it attached again without history ([`REATTACHED_NOTICE`]), until
/// `quiet` passes with no notice at all; and whether the link is connected (`connected`: it was
/// already), which it must be before any such notice.
async fn reattached_until_quiet(
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    quiet: Duration,
    connected: bool,
) -> (bool, Vec<String>) {
    let (mut connected, mut reattached) = (connected, Vec::new());
    while let Ok(Some((_, _, notice))) = tokio::time::timeout(quiet, notices.recv()).await {
        match notice {
            PeerNotice::Connected => connected = true,
            PeerNotice::Notification { method: m, params, .. } if m == REATTACHED_NOTICE => {
                assert!(connected, "told before the link was ready");
                reattached.push(params["sessionId"].as_str().unwrap().to_owned());
            }
            _ => {}
        }
    }
    (connected, reattached)
}

fn attaches(asked: &mut mpsc::UnboundedReceiver<String>) -> usize {
    let mut n = 0;
    while let Ok(m) = asked.try_recv() {
        n += usize::from(m == method::MUX_ATTACH);
    }
    n
}

/// A chat whose first attach read an empty page (a new Cloud chat with no records yet, or one
/// whose page held none of what was asked) has a baseline all the same: the page says it holds
/// everything through `pageThrough`. A reconnect replays it from there, so what the peer sent
/// between the links streams, instead of attaching it without history every time.
#[tokio::test(start_paused = true)]
async fn a_chat_first_attached_with_an_empty_page_is_replayed_after_a_reconnect() {
    let (tx, mut notices) = mpsc::channel(256);
    let peer = Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
    // A client's attach of a new chat, and the link's own attach of another.
    peer.mark_attached("new");
    peer.note_attached_page("new", &json!({"events": [], "lastSeq": 0, "pageThrough": 0}));
    peer.mark_attached("hidden");
    peer.note_hidden_attach_page("hidden", &json!({"events": [], "pageThrough": 0}));
    // A client's first page of an older chat whose records were all left out of it.
    peer.mark_attached("older");
    peer.note_attached_page("older", &json!({"events": [], "lastSeq": 7, "pageThrough": 7}));
    let (fake, serving, _asked) = open_link(&peer, Hello::pipelines()).await;
    let (connected, reattached) = reattached_until_quiet(&mut notices, RTT * 10, false).await;
    assert!(connected, "the link connects");
    assert!(reattached.is_empty(), "replayed from their baseline, not re-attached: {reattached:?}");
    let tail = peer.replay_tail.lock_or_recover().clone();
    for sid in ["new", "hidden", "older"] {
        assert!(tail.contains_key(sid), "{sid} was replayed: {tail:?}");
    }
    assert_eq!(tail["older"], 7, "replayed after the page's pageThrough");
    fake.abort();
    serving.abort();
    peer.stop();
}

/// A reconnect's attach of a chat without history that fails without the peer refusing it (it
/// timed out, the queue was full) left the chat marked and streaming nothing until the next
/// reconnect, and said nothing: a Cloud chat's live output just stopped. It is attached again on
/// the same link, and once it is, its clients are told to read the hole.
#[tokio::test(start_paused = true)]
async fn a_reattach_that_fails_is_retried_on_the_same_link_and_reported_as_lagged() {
    let (tx, mut notices) = mpsc::channel(256);
    let peer = Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
    peer.mark_attached("lost");
    let flaky = Hello { attach_failures: 2, ..Hello::pipelines() };
    let (fake, serving, mut asked) = open_link(&peer, flaky).await;
    let (connected, reattached) =
        reattached_until_quiet(&mut notices, Duration::from_secs(60), false).await;
    assert!(connected, "the link connects");
    assert_eq!(reattached, ["lost"], "streams again, and its clients read the hole");
    assert_eq!(attaches(&mut asked), 3, "two failed attaches and the one that took");
    assert!(peer.attached.lock_or_recover().contains_key("lost"), "still marked");
    fake.abort();
    serving.abort();
    peer.stop();
}

/// A chat's first attach (the link's own, before a prompt goes) that fails while the link stays
/// up streamed nothing until a reconnect. It is attached again on the same link, and its
/// clients are told to read what they missed meanwhile.
#[tokio::test(start_paused = true)]
async fn a_first_attach_that_fails_while_the_link_is_up_is_retried_and_reported() {
    let (tx, mut notices) = mpsc::channel(256);
    let peer = Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
    let flaky = Hello { attach_failures: 1, ..Hello::pipelines() };
    let (fake, serving, mut asked) = open_link(&peer, flaky).await;
    let (connected, _) = reattached_until_quiet(&mut notices, RTT * 10, false).await;
    assert!(connected, "the link connects");
    peer.mark_attached("chat");
    assert!(peer.attach_hidden("chat").await.is_err(), "the first attach fails");
    let (_, reattached) = reattached_until_quiet(&mut notices, Duration::from_secs(60), true).await;
    assert_eq!(reattached, ["chat"], "attached again, and its clients read the hole");
    assert_eq!(attaches(&mut asked), 2);
    fake.abort();
    serving.abort();
    peer.stop();
}

/// The retries stop: a peer that never takes the attach is asked a bounded number of times on
/// the link, the chat stays marked for the next link, and nothing claims it streams.
#[tokio::test(start_paused = true)]
async fn attach_retries_stop_after_their_cap() {
    let (tx, mut notices) = mpsc::channel(256);
    let peer = Peer::new("vm", "ws://127.0.0.1:9", None, None, tx);
    let broken = Hello { attach_failures: usize::MAX, ..Hello::pipelines() };
    let (fake, serving, mut asked) = open_link(&peer, broken).await;
    let (connected, _) = reattached_until_quiet(&mut notices, RTT * 10, false).await;
    assert!(connected, "the link connects");
    peer.mark_attached("chat");
    assert!(peer.attach_hidden("chat").await.is_err());
    let (_, reattached) =
        reattached_until_quiet(&mut notices, Duration::from_secs(600), true).await;
    assert!(reattached.is_empty(), "{reattached:?}");
    assert_eq!(attaches(&mut asked), 7, "the first and its six retries");
    assert!(peer.attached.lock_or_recover().contains_key("chat"), "marked for the next link");
    fake.abort();
    serving.abort();
    peer.stop();
}
