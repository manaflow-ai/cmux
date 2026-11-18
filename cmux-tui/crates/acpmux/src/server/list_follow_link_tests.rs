//! A peer link that read a daemon's list reads only what changed when it links again: it
//! follows the list from its cursor (`hub/row_log.rs`). Over a real listener, served as a peer,
//! a reconnect after the daemon's listener restarts reads a follow of a few hundred bytes, not the
//! list, and the hub keeps the rows it held.

use super::ws_shutdown::WsShutdown;
use super::{WsAuth, bind_ws, peer_auth, serve_ws_until};
use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use serde_json::json;
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const TOKEN: &str = "0123456789abcdef";
const ROWS: usize = 3000;

/// A hub with `ROWS` chats of its own.
fn hub() -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    for i in 0..ROWS {
        let id = format!("own-{i:05}");
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": format!("chat {i}"),
            "harness": "fake", "cwd": format!("/work/{}", i % 40), "status": "idle",
            "createdAt": i + 1, "updatedAt": i + 1
        }))
        .unwrap();
        store.save(&meta).unwrap();
    }
    crate::hub::Hub::new(config, store)
}

/// What the link published before its `Listed`: a whole list, or a follow's rows and
/// gone ids.
#[derive(Debug)]
enum Listed {
    Whole(Vec<serde_json::Value>),
    Patch(Vec<serde_json::Value>, Vec<String>),
}

async fn linked(notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>) -> Listed {
    // A link after a far restart reads its list after it is ready: both, in either order.
    let (mut listed, mut connected, mut whole) = (None, false, false);
    while !connected || !whole {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(60), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => {
                listed = Some(Listed::Whole(crate::peer::parse_rows(&rows)))
            }
            PeerNotice::SessionsPatch { rows, gone } => {
                listed = Some(Listed::Patch(crate::peer::parse_rows(&rows), gone))
            }
            PeerNotice::Listed => whole = true,
            PeerNotice::Connected => connected = true,
            _ => {}
        }
    }
    listed.expect("a list before Listed")
}

fn whole(listed: Listed) -> Vec<serde_json::Value> {
    match listed {
        Listed::Whole(rows) => rows,
        other => panic!("a whole list, not {other:?}"),
    }
}

fn once(rows: &[serde_json::Value]) -> usize {
    let mut seen = HashSet::new();
    for row in rows {
        let id = row["sessionId"].as_str().unwrap();
        assert!(seen.insert(id.to_owned()), "{id} came twice");
    }
    seen.len()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_reconnecting_peer_link_follows_from_its_cursor_and_reads_only_what_changed() {
    let hub = hub();
    let home = std::env::temp_dir().join(format!("acpmux-follow-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&home).unwrap();
    let auth = Arc::new(peer_auth::PeerAuth::create(&home).unwrap());
    let peer_token = std::fs::read_to_string(peer_auth::token_path(&home)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let serve = |listener, shutdown| {
        let ws = WsAuth { local_app: None, peer: Some(auth.clone()) };
        tokio::spawn(serve_ws_until(hub.clone(), listener, TOKEN.into(), ws, shutdown))
    };
    let first = WsShutdown::default();
    let served = serve(listener, first.clone());

    let (tx, mut notices) = mpsc::channel(64);
    let url = format!("ws://{address}");
    let peer = Peer::new("box", &url, Some(TOKEN.into()), Some(peer_token.trim().to_owned()), tx);
    let link = tokio::spawn(peer.clone().run());
    let rows = whole(linked(&mut notices).await);
    assert_eq!(peer.served_as().as_deref(), Some("peer"));
    assert_eq!(once(&rows), ROWS);
    let (_, list) = peer.received().read();

    // The daemon's listener restarts (Close 1012): the link comes back at once, to a new one.
    first.restart();
    served.await.unwrap().unwrap();
    // One chat changes while the link is down: after the first listener ended, so its notice
    // cannot reach the link and move its cursor past the change before the drop (#42091 F3).
    hub.row_changed_for_test("own-00007", "renamed");
    let second = serve(bind_ws(&address.to_string()).await.unwrap(), WsShutdown::default());
    let Listed::Patch(again, gone) = linked(&mut notices).await else {
        panic!("a follow, not the list")
    };
    assert_eq!(ids(&again), ["own-00007"], "only the chat that changed");
    assert!(gone.is_empty(), "{gone:?}");
    // This link's bytes only (`Peer::received` counts per link).
    let (_, follow) = peer.received().read();
    assert!(follow * 20 < list, "a follow of {follow} bytes, not the list's {list}");
    println!("PERF follow rows={ROWS} whole={list} reconnect={follow}");
    peer.stop();
    link.abort();
    second.abort();
    let _ = std::fs::remove_dir_all(&home);
}

fn ids(rows: &[serde_json::Value]) -> Vec<String> {
    let mut ids: Vec<String> =
        rows.iter().filter_map(|r| r["sessionId"].as_str()).map(str::to_owned).collect();
    ids.sort();
    ids
}

/// A daemon whose list needed pages of rows (too large to send whole) is asked to follow from
/// the list's cursor when the link comes back, as its list was read (without tools), and not
/// for the pages again; a follow it cannot answer (`reset`) is a whole list again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_that_read_row_pages_follows_from_its_cursor_when_it_links_again() {
    use crate::rpc::{Message, RpcError, method};
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    use tokio_tungstenite::tungstenite::protocol::{CloseFrame, frame::coding::CloseCode};

    let rows: Vec<serde_json::Value> = (0..50)
        .map(|i| json!({"sessionId": format!("big-{i:02}"), "status": "idle", "updatedAt": i}))
        .collect();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (asked_tx, mut asked) = mpsc::unbounded_channel::<serde_json::Value>();
    let (close_tx, close_rx) = tokio::sync::oneshot::channel::<()>();
    let server = tokio::spawn(async move {
        let mut close = Some(close_rx);
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            let mut closing = close.take();
            loop {
                let frame = match closing.as_mut() {
                    Some(rx) => tokio::select! {
                        _ = rx => {
                            let restart = CloseFrame { code: CloseCode::Restart, reason: "restarting".into() };
                            let _ = ws.send(Frame::Close(Some(restart))).await;
                            break;
                        }
                        frame = ws.next() => frame,
                    },
                    None => ws.next().await,
                };
                let Some(Ok(Frame::Text(text))) = frame else { break };
                let msg: serde_json::Value = serde_json::from_str(&text).unwrap();
                let Some(id) = msg.get("id").cloned() else { continue };
                let params = msg["params"].clone();
                let reply = match msg["method"].as_str() {
                    Some(method::INITIALIZE) => Ok(json!({"_meta": {"acpmux": {"origin": "peer",
                        "build": "b1", "capabilities": [crate::hub::row_log::CAPABILITY]}}})),
                    Some(method::MUX_WATCH) => {
                        let _ = asked_tx.send(params.clone());
                        let at = |seq: u64| json!({"listEpoch": "run-1", "listSeq": seq});
                        match params.get("afterSeq").and_then(serde_json::Value::as_u64) {
                            Some(9) => {
                                let mut follow = at(12);
                                follow["follow"] = json!(true);
                                follow["sessions"] = json!([{"sessionId": "big-03", "status": "running", "updatedAt": 99}]);
                                follow["gone"] = json!([{"sessionId": "big-04"}]);
                                Ok(follow)
                            }
                            Some(_) => Err(RpcError::internal("asked from the wrong cursor")),
                            None if params.get("limit").is_some() => {
                                let mut list = at(9);
                                list["sessions"] = json!(rows);
                                Ok(list)
                            }
                            None => Err(RpcError::too_large(16 << 20)),
                        }
                    }
                    _ => Ok(json!({})),
                };
                let reply = match reply {
                    Ok(result) => Message::ok(id, result),
                    Err(error) => Message::err(id, error),
                };
                if ws.send(Frame::Text(reply.to_line().trim_end().to_owned().into())).await.is_err()
                {
                    break;
                }
            }
        }
    });
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("big", &format!("ws://{address}"), Some(TOKEN.into()), None, tx);
    let link = tokio::spawn(peer.clone().run());
    assert_eq!(once(&whole(linked(&mut notices).await)), 50);
    // The first link: the list without tools, then pages of rows.
    let mut first = Vec::new();
    while let Ok(params) = asked.try_recv() {
        first.push(params);
    }
    assert_eq!(first.len(), 2, "{first:?}");
    assert!(first[1].get("limit").is_some(), "{first:?}");

    close_tx.send(()).unwrap();
    let Listed::Patch(changed, gone) = linked(&mut notices).await else { panic!("a follow") };
    assert_eq!(ids(&changed), ["big-03"]);
    assert_eq!(gone, ["big-04"]);
    let again = asked.recv().await.unwrap();
    assert_eq!((again["afterSeq"].as_u64(), again["listEpoch"].as_str()), (Some(9), Some("run-1")));
    assert_eq!(again["withTools"], false, "asked as the list was read: {again}");
    assert!(asked.try_recv().is_err(), "one request: the follow");
    peer.stop();
    link.abort();
    server.abort();
}

/// A peer that left out notices (`_acpmux/lagged`) is followed from where the hole began when
/// the link comes back: the cursor stays at the last change the hub got before the lag, never
/// moves past it on a later notice, and the next link asks for what changed since, not the whole
/// list (a 10K-session host sent its peers 323 whole lists in 7.7 min, 2026-11-18).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lagged_link_follows_from_where_the_hole_began_not_the_whole_list() {
    use crate::rpc::{Message, method};
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Frame;
    use tokio_tungstenite::tungstenite::protocol::{CloseFrame, frame::coding::CloseCode};

    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (asked_tx, mut asked) = mpsc::unbounded_channel::<serde_json::Value>();
    let server = tokio::spawn(async move {
        let mut first = true;
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
            let lagging = std::mem::take(&mut first);
            while let Some(Ok(Frame::Text(text))) = ws.next().await {
                let msg: serde_json::Value = serde_json::from_str(&text).unwrap();
                let Some(id) = msg.get("id").cloned() else { continue };
                let params = msg["params"].clone();
                let at = |seq: u64| json!({"listEpoch": "run-1", "listSeq": seq});
                let (result, watch) = match msg["method"].as_str() {
                    Some(method::INITIALIZE) => (
                        json!({"_meta": {"acpmux": {"origin": "peer", "build": "b1",
                            "capabilities": [crate::hub::row_log::CAPABILITY]}}}),
                        false,
                    ),
                    Some(method::MUX_WATCH) => {
                        let _ = asked_tx.send(params.clone());
                        let mut reply = at(9);
                        if params.get("afterSeq").is_some() {
                            reply = at(21);
                            reply["follow"] = json!(true);
                            reply["gone"] = json!([]);
                            reply["sessions"] =
                                json!([{"sessionId": "s-2", "status": "idle", "updatedAt": 21}]);
                        } else {
                            reply["sessions"] = json!((0..3)
                                .map(|i| json!({"sessionId": format!("s-{i}"), "status": "idle", "updatedAt": i}))
                                .collect::<Vec<_>>());
                        }
                        (reply, true)
                    }
                    _ => (json!({}), false),
                };
                let line = Message::ok(id, result).to_line().trim_end().to_owned();
                if ws.send(Frame::Text(line.into())).await.is_err() {
                    break;
                }
                if !(watch && lagging) {
                    continue;
                }
                let changed = |seq: u64| {
                    let session =
                        json!({"sessionId": "s-1", "status": "running", "updatedAt": seq});
                    let params =
                        json!({"session": session, "kind": "status", "seq": seq, "listSeq": seq});
                    Message::notification(method::MUX_SESSION_CHANGED, params)
                };
                let lagged = Message::notification("_acpmux/lagged", json!({"dropped": 4}));
                for notice in [changed(10), lagged, changed(20)] {
                    let line = notice.to_line().trim_end().to_owned();
                    ws.send(Frame::Text(line.into())).await.unwrap();
                }
                tokio::time::sleep(Duration::from_millis(300)).await;
                let restart = CloseFrame { code: CloseCode::Restart, reason: "restarting".into() };
                let _ = ws.send(Frame::Close(Some(restart))).await;
                break;
            }
        }
    });
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("lagger", &format!("ws://{address}"), Some(TOKEN.into()), None, tx);
    let link = tokio::spawn(peer.clone().run());
    assert_eq!(once(&whole(linked(&mut notices).await)), 3);
    let first = asked.recv().await.unwrap();
    assert!(first.get("afterSeq").is_none(), "a first link reads the list: {first}");
    let Listed::Patch(changed, _) = linked(&mut notices).await else {
        panic!("a lagged link follows from its cursor, not the whole list")
    };
    assert_eq!(ids(&changed), ["s-2"]);
    let again = asked.recv().await.unwrap();
    assert_eq!(
        (again["afterSeq"].as_u64(), again["listEpoch"].as_str()),
        (Some(10), Some("run-1")),
        "followed from the last change before the lag, not past it: {again}"
    );
    peer.stop();
    link.abort();
    server.abort();
}
