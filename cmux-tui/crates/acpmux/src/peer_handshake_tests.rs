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

/// A link's watch list is asked for without tools from the start: an inventory is read per
/// session (`_acpmux/info`, an attachment's notices), and with them one host's list was 23 MB,
/// past the message limit (2026-10-31). The link connects on one watch, with every row, from a
/// peer that would refuse the list with tools as too large.
#[tokio::test]
async fn a_watch_list_is_asked_for_without_tools_from_the_start() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("big", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client =
        WebSocketStream::from_raw_socket(ours, Role::Client, Some(crate::server::ws_config()))
            .await;
    let server =
        WebSocketStream::from_raw_socket(theirs, Role::Server, Some(crate::server::ws_config()))
            .await;
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
    assert_eq!(asked.recv().await, Some(false));
    assert!(asked.try_recv().is_err(), "one watch, never one with tools");
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

/// A peer from before #28182 (cosmic-gray's NIGHTLY on 2026-10-30): a list with no `limit` is
/// sent whole or refused as too large (`message.too_large`), with or without tools, and a list
/// with `limit` is a keyset page of that many rows, newest first. Its first page request is
/// paced once (`list.paced`). Each row is `bytes` long.
fn old_peer(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    rows: usize,
    bytes: usize,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let pad = "x".repeat(bytes);
        let list: Vec<Value> = (0..rows)
            .map(|n| json!({"sessionId": format!("s{n:04}"), "updatedAt": rows - n, "title": pad}))
            .collect();
        let mut paced = false;
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let params = &msg["params"];
            let result = match msg["method"].as_str() {
                Some(method::MUX_WATCH | method::MUX_SESSIONS) => match params["limit"].as_u64() {
                    None => Ok(json!({"sessions": list})),
                    Some(_) if !paced => {
                        paced = true;
                        Err(RpcError::new(-32000, "session lists are paced".to_owned())
                            .with_data(json!({"reason": "list.paced", "retryAfterMs": 5})))
                    }
                    Some(limit) => {
                        let start = params["cursor"]
                            .as_str()
                            .map_or(0, |c| c.trim_start_matches('k').parse::<usize>().unwrap());
                        let end = (start + limit as usize).min(rows);
                        let next = (end < rows).then(|| format!("k{end}"));
                        Ok(json!({"sessions": list[start..end], "nextCursor": next}))
                    }
                },
                _ => Ok(json!({})),
            };
            let mut line = match result {
                Ok(result) => Message::ok(id.clone(), result),
                Err(error) => Message::err(id.clone(), error),
            }
            .to_line();
            if line.len() > crate::rpc::MAX_MESSAGE_BYTES {
                line = Message::err(id, RpcError::too_large(line.len())).to_line();
            }
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    })
}

/// A peer from before #28182 whose list is too large for one message even without tools is
/// read in pages of a count of rows, which it serves: the link connects with every row once.
/// A page too large is asked for again with half the rows, and a paced one after its wait.
#[tokio::test]
async fn a_watch_list_too_large_from_an_old_peer_is_read_in_pages_of_rows() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("cosmic", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client =
        WebSocketStream::from_raw_socket(ours, Role::Client, Some(crate::server::ws_config()))
            .await;
    let server =
        WebSocketStream::from_raw_socket(theirs, Role::Server, Some(crate::server::ws_config()))
            .await;
    // 500 rows of 70 KB: 35 MB whole, over the limit; a page of 512 is too, one of 256 is not.
    let (rows, bytes) = (500, 70_000);
    assert!(rows * bytes > crate::rpc::MAX_MESSAGE_BYTES);
    let fake = old_peer(server, rows, bytes);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let mut lists = Vec::new();
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(20), notices.recv())
            .await
            .expect("the link connects instead of failing on a list too large")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => lists.push(rows),
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    assert_eq!(lists.len(), 1, "the list is published once, whole");
    let ids: Vec<&str> = lists[0].iter().map(|r| r["sessionId"].as_str().unwrap()).collect();
    let unique: HashSet<&str> = ids.iter().copied().collect();
    assert_eq!((ids.len(), unique.len()), (rows, rows), "every row once");
    assert!(peer.link().is_ready());
    serving.abort();
    fake.abort();
}

/// What a [`paced_old_peer`] was asked: whole lists (no `limit`) and pages (a `limit`).
#[derive(Default)]
struct Asked {
    whole: std::sync::atomic::AtomicUsize,
    pages: std::sync::atomic::AtomicUsize,
}

/// c230bb58a's `Pacer` (`hub/list_guard.rs`): `wait` is how long a request waits with
/// `allowance` of credit, `spend` takes `cost` from `at`.
#[derive(Clone, Copy)]
struct OldPacer {
    free: tokio::time::Instant,
}

impl OldPacer {
    fn wait(&self, now: tokio::time::Instant, allowance: Duration) -> Duration {
        self.free.saturating_duration_since(now + allowance)
    }

    fn spend(&mut self, at: tokio::time::Instant, cost: Duration) {
        self.free = self.free.max(at) + cost;
    }
}

/// A pre-#28182 peer (as [`old_peer`]) that paces its lists like c230bb58a's
/// `hub/list_guard.rs` while its sessions change. Per connection: two lists back to back, then
/// each waits its share of a `window` (a page its rows' share, at least a sixteenth). And every
/// list request builds the list again: [`OLD_BURST`] builds back to back, then one per window.
/// Its `initialize` names its build.
fn paced_old_peer(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    rows: usize,
    bytes: usize,
    window: Duration,
    asked: Arc<Asked>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let pad = "x".repeat(bytes);
        let list: Vec<Value> = (0..rows)
            .map(|n| json!({"sessionId": format!("s{n:04}"), "updatedAt": rows - n, "title": pad}))
            .collect();
        let start = tokio::time::Instant::now();
        let (mut conn, mut builds) = (OldPacer { free: start }, OldPacer { free: start });
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let params = &msg["params"];
            let result = match msg["method"].as_str() {
                Some(method::INITIALIZE) => json!({"_meta": {"acpmux": {"build": "c230bb58a"}}}),
                Some(method::MUX_WATCH | method::MUX_SESSIONS) => {
                    let share = params["limit"]
                        .as_u64()
                        .map_or(1.0, |limit| (limit as f64 / rows as f64).clamp(1.0 / 16.0, 1.0));
                    let now = tokio::time::Instant::now();
                    let wait = conn.wait(now, window);
                    conn.spend(now + wait, window.mul_f64(share));
                    tokio::time::sleep(wait).await;
                    let now = tokio::time::Instant::now();
                    let build = builds.wait(now, window * (OLD_BURST - 1));
                    tokio::time::sleep(build).await;
                    builds.spend(tokio::time::Instant::now(), window);
                    match params["limit"].as_u64() {
                        None => {
                            asked.whole.fetch_add(1, Ordering::SeqCst);
                            json!({"sessions": list})
                        }
                        Some(limit) => {
                            asked.pages.fetch_add(1, Ordering::SeqCst);
                            let start = params["cursor"]
                                .as_str()
                                .map_or(0, |c| c.trim_start_matches('k').parse::<usize>().unwrap());
                            let end = (start + limit as usize).min(rows);
                            let next = (end < rows).then(|| format!("k{end}"));
                            json!({"sessions": list[start..end], "nextCursor": next})
                        }
                    }
                }
                _ => json!({}),
            };
            let mut line = Message::ok(id.clone(), result).to_line();
            if line.len() > crate::rpc::MAX_MESSAGE_BYTES {
                line = Message::err(id, RpcError::too_large(line.len())).to_line();
            }
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    })
}

/// Builds c230bb58a's list guard runs back to back (`BURST`) before its pace holds.
const OLD_BURST: u32 = 4;

/// One fleet Mac's list on 2026-10-30, as an old-style peer: about 3,700 rows, 33 MB without
/// tools; the pace window at its cap.
const OLD_ROWS: usize = 3700;
const OLD_ROW_BYTES: usize = 9000;
const OLD_WINDOW: Duration = Duration::from_secs(15);

/// Serves `peer` against a [`paced_old_peer`] until it connects: the time it took (on the
/// paused clock) and every row of the list it published, or the link's error.
async fn link_to_paced_old_peer(
    peer: &Arc<Peer>,
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    asked: Arc<Asked>,
) -> Result<(Duration, Vec<Value>), String> {
    let (ours, theirs) = tokio::io::duplex(1 << 20);
    let client =
        WebSocketStream::from_raw_socket(ours, Role::Client, Some(crate::server::ws_config()))
            .await;
    let server =
        WebSocketStream::from_raw_socket(theirs, Role::Server, Some(crate::server::ws_config()))
            .await;
    let fake = paced_old_peer(server, OLD_ROWS, OLD_ROW_BYTES, OLD_WINDOW, asked);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let started = tokio::time::Instant::now();
    let link = peer.clone();
    let mut serving = tokio::spawn(async move {
        let end = link.serve(client, &mut out_rx).await;
        (end, out_rx)
    });
    let mut listed = None;
    let outcome = loop {
        tokio::select! {
            notice = notices.recv() => match notice.expect("the link stays open").2 {
                PeerNotice::Sessions(rows) => listed = Some(rows),
                PeerNotice::Connected => break Ok((started.elapsed(), listed.take().unwrap_or_default())),
                _ => {}
            },
            ended = &mut serving => {
                let (end, out_rx) = ended.unwrap();
                *peer.out_rx.lock().await = Some(out_rx);
                break Err(end.err().unwrap_or_else(|| "the link ended".to_owned()));
            }
        }
    };
    fake.abort();
    // The peer's end closed: the link ends and hands its queue back for the next one.
    if outcome.is_ok() {
        let (_, out_rx) = serving.await.unwrap();
        *peer.out_rx.lock().await = Some(out_rx);
    }
    peer.link_ended();
    outcome
}

/// An old-style peer whose list is over the message limit and that paces its list builds (one
/// per 15 s window after four) links inside the handshake's deadline, with every row once: its
/// pages are sized to the bytes, so they are few.
#[tokio::test(start_paused = true)]
async fn an_old_peer_that_paces_its_lists_links_inside_the_handshake_deadline() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("cosmic", "ws://127.0.0.1:9", None, None, tx);
    let asked = Arc::new(Asked::default());
    let (took, rows) = link_to_paced_old_peer(&peer, &mut notices, asked.clone())
        .await
        .expect("the link connects");
    let pages = asked.pages.load(Ordering::SeqCst);
    println!(
        "PERF handshake old-peer rows={OLD_ROWS} first_link_s={} whole={} pages={pages}",
        took.as_secs_f64(),
        asked.whole.load(Ordering::SeqCst)
    );
    let unique: HashSet<&str> = rows.iter().filter_map(|r| r["sessionId"].as_str()).collect();
    assert_eq!((rows.len(), unique.len()), (OLD_ROWS, OLD_ROWS), "every row once");
    assert!(took < peer.timings.handshake, "took {took:?}");
    assert!(pages <= 3, "{pages} pages");
}

/// A peer whose list the last handshake read in pages of rows is read so at once the next time
/// (the same build): no whole list is asked for, so none is built and refused.
#[tokio::test(start_paused = true)]
async fn a_peer_whose_list_needed_pages_of_rows_is_read_in_them_at_once_next_time() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("cosmic", "ws://127.0.0.1:9", None, None, tx);
    let first = Arc::new(Asked::default());
    link_to_paced_old_peer(&peer, &mut notices, first.clone()).await.expect("the first link");
    assert_eq!(first.whole.load(Ordering::SeqCst), 1, "one whole list, without tools");
    let again = Arc::new(Asked::default());
    let (took, rows) =
        link_to_paced_old_peer(&peer, &mut notices, again.clone()).await.expect("the next link");
    println!("PERF handshake old-peer rows={OLD_ROWS} next_link_s={}", took.as_secs_f64());
    assert_eq!(again.whole.load(Ordering::SeqCst), 0, "no whole list the next time");
    assert_eq!(rows.len(), OLD_ROWS);
}

/// A fake peer on `server` that answers `initialize` and every other request with `{}`, and
/// sends its watch list in `pages` pages of one row, each `gap` after it was asked for.
fn slow_pages_peer(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    pages: u64,
    gap: Duration,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let result = match msg["method"].as_str() {
                Some(method::MUX_WATCH | method::MUX_SESSIONS) => {
                    tokio::time::sleep(gap).await;
                    let at: u64 = msg["params"]["cursor"]
                        .as_str()
                        .map_or(0, |c| c.trim_start_matches('h').parse().unwrap());
                    let next = (at + 1 < pages).then(|| format!("h{}", at + 1));
                    json!({"sessions": [{"sessionId": format!("p{at}"), "updatedAt": 1000 - at}], "nextCursor": next})
                }
                _ => json!({}),
            };
            let line = Message::ok(id, result).to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    })
}

/// Each page of a watch list read in pages moves the handshake's deadline on: an old-style peer
/// slower than the deadline over the whole list, but answering each page within it, links.
#[tokio::test(start_paused = true)]
async fn a_paged_watch_list_slower_than_the_deadline_in_all_still_links() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    // Five pages, each 40 s apart: 200 s in all, past the 90 s deadline.
    let fake = slow_pages_peer(server, 5, Duration::from_secs(40));
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let mut listed = None;
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(600), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => listed = Some(rows),
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    assert_eq!(listed.expect("the whole list").len(), 5);
    serving.abort();
    fake.abort();
}

/// The pages move the deadline on only up to [`HANDSHAKE_MOST`] in all: a peer whose pages keep
/// coming in time, with the last one due right at that cap, is cut there and never connects.
#[tokio::test(start_paused = true)]
async fn a_paged_watch_list_is_cut_at_the_handshake_cap() {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("web", "ws://10.0.0.9:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let gap = Duration::from_secs(50);
    let pages = HANDSHAKE_MOST.as_secs().div_ceil(gap.as_secs());
    let fake = slow_pages_peer(server, pages, gap);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let started = tokio::time::Instant::now();
    let ended = peer.serve(client, &mut out_rx).await;
    let why = ended.expect_err("the handshake is cut");
    assert!(why.contains("handshake timed out after"), "{why}");
    assert!(started.elapsed() <= HANDSHAKE_MOST, "cut at the cap: {:?}", started.elapsed());
    while let Ok((_, _, notice)) = notices.try_recv() {
        assert!(!matches!(notice, PeerNotice::Connected), "never connects");
    }
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
