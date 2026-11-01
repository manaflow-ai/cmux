//! A peer link that read a daemon's list reads only what changed when it links again
//! (`watch_delta.rs`): over a real listener, served as a peer, a reconnect after the daemon's
//! listener restarts publishes the whole list again, every row once, from a reply of a few
//! hundred bytes per thousand rows instead of the list.

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

/// The rows of the list published before the next `Connected`.
async fn linked(notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>) -> Vec<serde_json::Value> {
    let mut listed = None;
    loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(60), notices.recv())
            .await
            .expect("the link connects")
            .expect("the link stays open");
        match notice {
            PeerNotice::Sessions(rows) => listed = Some(rows),
            PeerNotice::Connected => return listed.expect("a list before Connected"),
            _ => {}
        }
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
async fn a_reconnecting_peer_link_reads_a_delta_and_publishes_the_whole_list() {
    let hub = hub();
    let home = std::env::temp_dir().join(format!("acpmux-delta-{}", uuid::Uuid::now_v7()));
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
    let rows = linked(&mut notices).await;
    assert_eq!(peer.served_as().as_deref(), Some("peer"));
    assert_eq!(once(&rows), ROWS);
    let (_, whole) = peer.received().read();

    // The daemon's listener restarts (Close 1012): the link comes back at once, to a new one.
    first.restart();
    served.await.unwrap().unwrap();
    let second = serve(bind_ws(&address.to_string()).await.unwrap(), WsShutdown::default());
    let again = linked(&mut notices).await;
    assert_eq!(once(&again), ROWS, "the whole list again");
    assert_eq!(ids(&again), ids(&rows));
    let (_, delta) = peer.received().read();
    assert!(delta * 20 < whole, "a delta of {delta} bytes, not the list's {whole}");
    println!("PERF delta rows={ROWS} whole={whole} reconnect={delta}");
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

/// A daemon whose list needed pages of rows (too large to send whole) is asked for a
/// delta when the link comes back, as its list was read (without tools), and not for the
/// pages again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_that_read_row_pages_asks_a_delta_when_it_links_again() {
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
                        "build": "b1", "features": [crate::watch_delta::FEATURE]}}})),
                    Some(method::MUX_WATCH) => {
                        let _ = asked_tx.send(params.clone());
                        match params.get("known").and_then(serde_json::Value::as_object) {
                            Some(known) => {
                                let list = json!({"sessions": rows}).to_string();
                                Ok(serde_json::from_str(
                                    &crate::watch_delta::delta(&list, known).unwrap(),
                                )
                                .unwrap())
                            }
                            None if params.get("limit").is_some() => Ok(json!({"sessions": rows})),
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
    assert_eq!(once(&linked(&mut notices).await), 50);
    // The first link: the list without tools, then pages of rows.
    let mut first = Vec::new();
    while let Ok(params) = asked.try_recv() {
        first.push(params);
    }
    assert_eq!(first.len(), 2, "{first:?}");
    assert!(first[1].get("limit").is_some(), "{first:?}");

    close_tx.send(()).unwrap();
    assert_eq!(once(&linked(&mut notices).await), 50, "the whole list again");
    let again = asked.recv().await.unwrap();
    assert!(again["known"].as_object().is_some_and(|k| k.len() == 50), "{again}");
    assert_eq!(again["withTools"], false, "asked as the list was read: {again}");
    assert!(asked.try_recv().is_err(), "one request: the delta");
    peer.stop();
    link.abort();
    server.abort();
}
