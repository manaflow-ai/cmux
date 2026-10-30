//! The handshake's own failures: a watch list too large to send, and any step the peer
//! refuses. huge-blue's link to big-red (2026-10-30) sat 90 s on every try, `handshaking`
//! with no error, because big-red's `_acpmux/watch` reply (17 MB with tools, 5241 rows) was
//! over the 15 MiB message limit and came back as `message.too_large`.

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// A fake peer on `server` that answers `initialize` and every other request with `{}`, and
/// each `_acpmux/watch` with `watch(withTools)`. Sends each watch's `withTools` on `asked`.
fn fake_peer(
    server: WebSocketStream<tokio::io::DuplexStream>,
    watch: fn(bool) -> Result<Value, RpcError>,
    asked: mpsc::UnboundedSender<bool>,
) -> tokio::task::JoinHandle<()> {
    fake_peer_with(server, watch, |_| json!({}), asked)
}

/// [`fake_peer`], with each `_acpmux/sessions` answered by `sessions(params)`.
fn fake_peer_with(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    watch: fn(bool) -> Result<Value, RpcError>,
    sessions: fn(&Value) -> Value,
    asked: mpsc::UnboundedSender<bool>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let reply = if msg["method"] == method::MUX_WATCH {
                let tools = msg["params"]["withTools"] == true;
                let _ = asked.send(tools);
                watch(tools)
            } else if msg["method"] == method::MUX_SESSIONS {
                Ok(sessions(&msg["params"]))
            } else {
                Ok(json!({}))
            };
            let reply = match reply {
                Ok(result) => Message::ok(id, result),
                Err(error) => Message::err(id, error),
            };
            let line = reply.to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    })
}

/// A watch list too large to send with tools is asked for again without them: the link
/// connects, with the rows of that list, instead of timing out.
#[tokio::test]
async fn a_watch_list_too_large_with_tools_is_read_without_them() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("big", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, mut asked) = mpsc::unbounded_channel();
    let fake = fake_peer(
        server,
        |tools| {
            if tools {
                Err(RpcError::too_large(17_181_757))
            } else {
                Ok(json!({"sessions": [{"sessionId": "m1", "name": "lane", "updatedAt": 5}]}))
            }
        },
        asked_tx,
    );
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

    let mut listed = None;
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), notices.recv())
            .await
            .expect("the link connects instead of waiting out the handshake deadline")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => listed = Some(rows),
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    let rows = listed.expect("the list came before Connected");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["sessionId"], "m1");
    assert!(peer.link().is_ready());
    assert_eq!(asked.recv().await, Some(true));
    assert_eq!(asked.recv().await, Some(false));
    serving.abort();
    fake.abort();
}

/// A watch list too large for one message comes in pages (a peer served as Web gets the whole
/// list): the link reads every page before it connects, and the list it publishes last, right
/// before Connected, holds every row.
#[tokio::test]
async fn a_paged_watch_list_is_read_whole_before_the_link_connects() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, _asked) = mpsc::unbounded_channel();
    let fake = fake_peer_with(
        server,
        |_| Ok(json!({"sessions": [{"sessionId": "a", "updatedAt": 5}], "nextCursor": "h1"})),
        |params| match params["cursor"].as_str() {
            Some("h1") => {
                json!({"sessions": [{"sessionId": "b", "updatedAt": 4}], "nextCursor": "h2"})
            }
            _ => json!({"sessions": [{"sessionId": "c", "updatedAt": 3}]}),
        },
        asked_tx,
    );
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let mut listed = None;
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => listed = Some(rows),
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    let rows = listed.expect("the list came before Connected");
    let ids: Vec<&str> = rows.iter().map(|r| r["sessionId"].as_str().unwrap()).collect();
    assert_eq!(ids, ["a", "b", "c"]);
    serving.abort();
    fake.abort();
}

/// A fake peer on `server` that answers each request with the frames `answer(request)` gives
/// (notifications, then its reply), or drops the link when it gives none.
fn fake_peer_frames(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    answer: fn(&Value) -> Vec<Value>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let frames = match msg["method"].as_str() {
                Some(method::MUX_WATCH | method::MUX_SESSIONS) => answer(&msg),
                _ => vec![json!({"result": {}})],
            };
            if frames.is_empty() {
                return;
            }
            for mut frame in frames {
                frame["jsonrpc"] = json!("2.0");
                if frame.get("method").is_none() {
                    frame["id"] = id.clone();
                }
                if server.send(Frame::Text(frame.to_string().into())).await.is_err() {
                    return;
                }
            }
        }
    })
}

/// Serves `peer` against `answer` until its link ends (or connects), and returns how it ended
/// with every notice it sent; `None` when it was still up after 5 s.
async fn serve_until_end(
    peer: &Arc<Peer>,
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    answer: fn(&Value) -> Vec<Value>,
) -> (Option<Result<LinkEnd, String>>, Vec<PeerNotice>) {
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let fake = fake_peer_frames(server, answer);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let ended =
        tokio::time::timeout(Duration::from_secs(5), peer.serve(client, &mut out_rx)).await.ok();
    fake.abort();
    let mut seen = Vec::new();
    while let Ok((_, _, notice)) = notices.try_recv() {
        seen.push(notice);
    }
    (ended, seen)
}

/// The first page of a watch list, with more after it.
fn first_page() -> Vec<Value> {
    vec![json!({"result": {"sessions": [{"sessionId": "a", "updatedAt": 5}], "nextCursor": "h1"}})]
}

/// A link that drops while its watch list comes in pages publishes no part of that list: the
/// hub keeps the last whole list it had, instead of a first page that lacks every later row.
#[tokio::test]
async fn a_paged_watch_list_that_drops_midway_publishes_none_of_it() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ended, seen) = serve_until_end(&peer, &mut notices, |msg| {
        if msg["method"] == method::MUX_WATCH { first_page() } else { vec![] }
    })
    .await;
    assert!(ended.expect("the link ends when it drops").is_err());
    assert!(!seen.iter().any(|n| matches!(n, PeerNotice::Sessions(_))), "{seen:?}");
    assert!(!peer.link().is_ready());
}

/// A change the peer sends while its watch list comes in pages reaches the hub after the whole
/// list, never before it, so that list never overwrites the newer change.
#[tokio::test]
async fn a_change_during_a_paged_watch_list_comes_after_the_whole_list() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let fake = fake_peer_frames(server, |msg| {
        if msg["method"] == method::MUX_WATCH {
            return first_page();
        }
        let changed = json!({"sessionId": "a", "updatedAt": 9, "title": "newer"});
        vec![
            json!({"method": method::MUX_SESSION_CHANGED,
                   "params": {"session": changed, "kind": "updated", "seq": 1}}),
            json!({"result": {"sessions": [{"sessionId": "b", "updatedAt": 4}]}}),
        ]
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let mut seen = Vec::new();
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        let connected = matches!(notice, PeerNotice::Connected);
        seen.push(notice);
        if connected {
            break;
        }
    }
    let lists: Vec<_> = seen
        .iter()
        .enumerate()
        .filter_map(|(at, n)| match n {
            PeerNotice::Sessions(rows) => Some((at, rows)),
            _ => None,
        })
        .collect();
    assert_eq!(lists.len(), 1, "one list, published whole: {seen:?}");
    let (list_at, rows) = lists[0];
    let ids: Vec<&str> = rows.iter().map(|r| r["sessionId"].as_str().unwrap()).collect();
    assert_eq!(ids, ["a", "b"]);
    let changed_at = seen
        .iter()
        .position(|n| matches!(n, PeerNotice::SessionChanged { .. }))
        .expect("the change is published");
    assert!(list_at < changed_at, "the change comes after the list: {seen:?}");
    serving.abort();
    fake.abort();
}

/// A request of a link gone down that is still on its way out while the next link reads its
/// watch list in pages takes no page's place: the list is still published whole.
#[tokio::test]
async fn a_request_of_a_gone_link_takes_no_page_of_the_watch_list() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, asked) = tokio::sync::oneshot::channel::<()>();
    let (go_tx, go) = tokio::sync::oneshot::channel::<()>();
    // Answers the watch with a first page; holds the second until the test lets it go.
    let fake = tokio::spawn(async move {
        let (mut asked_tx, mut go) = (Some(asked_tx), Some(go));
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let result = if msg["method"] == method::MUX_WATCH {
                json!({"sessions": [{"sessionId": "a", "updatedAt": 5}], "nextCursor": "h1"})
            } else if msg["method"] == method::MUX_SESSIONS {
                let _ = asked_tx.take().map(|tx| tx.send(()));
                if let Some(go) = go.take() {
                    let _ = go.await;
                }
                json!({"sessions": [{"sessionId": "b", "updatedAt": 4}]})
            } else {
                json!({})
            };
            let line = Message::ok(id, result).to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::timeout(Duration::from_secs(5), asked).await.unwrap().unwrap();
    // A `_acpmux/sessions` admitted on an earlier link, sent now.
    let gone = peer.link_epoch().wrapping_sub(1);
    let stale = peer.link_request_on(method::MUX_SESSIONS, json!({}), Some(gone)).await;
    assert!(stale.is_err(), "{stale:?}");
    go_tx.send(()).unwrap();
    let mut listed = None;
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(5), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => listed = Some(rows),
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    let rows = listed.expect("the whole list came before Connected");
    let ids: Vec<&str> = rows.iter().map(|r| r["sessionId"].as_str().unwrap()).collect();
    assert_eq!(ids, ["a", "b"]);
    serving.abort();
    fake.abort();
}

/// A watch page cursor that is not a string ends the handshake with an error, instead of
/// connecting with the rows before it as if the list were whole.
#[tokio::test]
async fn a_watch_page_cursor_that_is_not_a_string_ends_the_handshake() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ended, seen) = serve_until_end(&peer, &mut notices, |_| {
        vec![json!({"result": {"sessions": [{"sessionId": "a", "updatedAt": 5}], "nextCursor": 7}})]
    })
    .await;
    let why = ended.expect("the link ends").expect_err("a bad cursor is an error");
    assert!(why.contains("page cursor 7"), "{why}");
    assert!(!seen.iter().any(|n| matches!(n, PeerNotice::Sessions(_))), "{seen:?}");
    assert!(!peer.link().is_ready());
}

/// A handshake step the peer refuses ends the link at once with the peer's error, not with
/// `handshake timed out after 90s` and no error in between.
#[tokio::test]
async fn a_refused_handshake_step_ends_the_link_with_its_error() {
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("big", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, _asked) = mpsc::unbounded_channel();
    let fake =
        fake_peer(server, |_| Err(RpcError::internal("the watch list broke".to_owned())), asked_tx);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(5), peer.serve(client, &mut out_rx))
        .await
        .expect("the link ends when its handshake fails");
    let why = ended.expect_err("a failed handshake is an error");
    assert!(why.contains("the watch list broke"), "{why}");
    assert!(!peer.link().is_ready());
    fake.abort();
}

/// A handshake whose link went down meanwhile (its epoch moved on) returns without making the
/// link ready: the link ends then, not at the deadline.
#[tokio::test]
async fn a_handshake_that_ends_without_a_ready_link_ends_the_link() {
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("big", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (asked_tx, asked) = tokio::sync::oneshot::channel::<()>();
    let (go_tx, go) = tokio::sync::oneshot::channel::<()>();
    // Answers `initialize` at once; holds the watch's answer until the test lets it go.
    let fake = tokio::spawn(async move {
        let (mut asked_tx, mut go) = (Some(asked_tx), Some(go));
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let result = if msg["method"] == method::MUX_WATCH {
                let _ = asked_tx.take().map(|tx| tx.send(()));
                if let Some(go) = go.take() {
                    let _ = go.await;
                }
                json!({"sessions": []})
            } else {
                json!({})
            };
            let line = Message::ok(id, result).to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    });
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    tokio::time::timeout(Duration::from_secs(5), asked).await.unwrap().unwrap();
    // The link's epoch moves on before the watch is answered.
    peer.link_ended();
    go_tx.send(()).unwrap();
    let ended = tokio::time::timeout(Duration::from_secs(5), serving)
        .await
        .expect("the link ends when its handshake ends without a ready link")
        .unwrap();
    assert!(ended.is_err(), "{ended:?}");
    assert!(!peer.link().is_ready());
    fake.abort();
}
