//! Compression negotiated on a WebSocket (`frame_compress.rs`): a fleet-sized list (20,000
//! rows, past 50 MB of JSON) reaches a peer link whole, every row once, in far fewer bytes than
//! its text, and whole from a server that does not compress; a client that does not ask the
//! daemon's listener gets Text frames only.

use super::{WsAuth, bind_ws, serve_ws_with};
use crate::config::{Config, StoreMode};
use crate::peer::{Peer, PeerNotice};
use crate::rpc::method;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as Frame;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

const TOKEN: &str = "0123456789abcdef";

/// A row with the text of a real one: a preview and a last message that differ per chat.
fn row(peer: usize, i: usize) -> Value {
    let words = ["fix", "the", "watch", "list", "page", "link", "peer", "cursor", "review", "ship"];
    let text: Vec<&str> = (0..300).map(|w| words[(w * 7 + i * 13 + peer) % words.len()]).collect();
    let text = format!("{i} {}", text.join(" "));
    json!({"sessionId": format!("peer-{peer}-chat-{i:05}"), "name": format!("chat-{i}"),
        "harness": "claude", "cwd": format!("/work/{}", i % 40), "status": "idle",
        "updatedAt": (peer * 100_000 + i + 1) as u64, "preview": text,
        "lastMessage": {"role": "agent", "text": text}})
}

/// A hub mirroring `rows` chats from each of `peers` peers, behind a WebSocket listener.
async fn listening_fleet(peers: usize, rows: usize) -> u16 {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(config, store);
    for p in 0..peers {
        let name = format!("peer-{p}");
        let (tx, _rx) = mpsc::channel(8);
        let peer = Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
        hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
        let list = (0..rows).map(|i| row(p, i)).collect();
        let mut settled = peer.settled();
        for notice in [PeerNotice::Sessions(list), PeerNotice::Connected] {
            hub.peer_notices.send((name.clone(), peer.generation, notice)).await.unwrap();
        }
        tokio::time::timeout(Duration::from_secs(30), settled.wait_for(|n| *n >= 1))
            .await
            .expect("the hub applies the notices")
            .unwrap();
    }
    assert_eq!(hub.remote_sessions().len(), peers * rows);
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(hub, listener, TOKEN.into(), WsAuth::default()));
    port
}

/// A server on `listener` that serves `pages` pages of `per_page` rows of its own through the
/// listener's writer (`ws_shutdown::write`): with zlib frames when `compress` and its client
/// asks, else Text only, as a server from before them (which ignores the field) does.
async fn paging_server(
    listener: tokio::net::TcpListener,
    pages: usize,
    per_page: usize,
    compress: bool,
) {
    let (stream, _) = listener.accept().await.unwrap();
    let ws = tokio_tungstenite::accept_async(stream).await.unwrap();
    let (sink, mut source) = ws.split();
    let (out, outbound) = mpsc::channel::<String>(64);
    let (_stop, stopped) = tokio::sync::oneshot::channel();
    let wire = Arc::new(crate::frame_compress::Wire::default());
    let writer =
        super::ws_shutdown::write(sink, outbound, stopped, Default::default(), wire.clone());
    tokio::spawn(writer);
    let page = |n: usize| {
        let rows: Vec<Value> = (0..per_page).map(|i| row(n, i)).collect();
        let mut page = json!({"sessions": rows});
        if n + 1 < pages {
            page["nextCursor"] = json!(format!("h{}", n + 1));
        }
        page
    };
    while let Some(Ok(frame)) = source.next().await {
        let Frame::Text(text) = frame else { continue };
        let msg: Value = serde_json::from_str(&text).unwrap();
        let Some(id) = msg.get("id").cloned() else { continue };
        let result = match msg["method"].as_str() {
            Some(method::INITIALIZE) => {
                if compress && crate::frame_compress::offered(msg.get("params")) {
                    wire.enable();
                }
                json!({"protocolVersion": 1})
            }
            Some(method::MUX_WATCH) => page(0),
            Some(method::MUX_SESSIONS) => {
                let cursor = msg["params"]["cursor"].as_str().unwrap_or("h0");
                page(cursor[1..].parse().unwrap())
            }
            _ => json!({}),
        };
        let line = crate::rpc::Message::ok(id, result).bounded_line().unwrap();
        assert!(line.len() <= crate::rpc::MAX_MESSAGE_BYTES);
        if out.send(line).await.is_err() {
            return;
        }
    }
}

/// A 20,000-row list in pages, over 50 MB of JSON, reaches a link to a server that
/// compresses and to one that does not (an older build): every row once, and from the first
/// in a fraction of the bytes.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_20k_row_list_reaches_a_peer_every_row_once_compressed_or_plain() {
    for compress in [true, false] {
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(paging_server(listener, 10, 2000, compress));
        let (tx, mut notices) = mpsc::channel(64);
        let url = format!("ws://127.0.0.1:{port}");
        let peer = Peer::new("fleet", &url, Some(TOKEN.into()), None, tx);
        let started = std::time::Instant::now();
        let link = tokio::spawn(peer.clone().run());
        let mut listed = None;
        loop {
            let (_, _, notice) = tokio::time::timeout(Duration::from_secs(60), notices.recv())
                .await
                .expect("the link connects")
                .expect("the link stays open");
            match notice {
                PeerNotice::Sessions(rows) => listed = Some(rows),
                PeerNotice::Connected => break,
                PeerNotice::Disconnected(why) => panic!("the link dropped: {why}"),
                _ => {}
            }
        }
        let took = started.elapsed();
        let rows = listed.expect("the list came before Connected");
        let mut seen = HashSet::new();
        for row in &rows {
            let id = row["sessionId"].as_str().unwrap();
            assert!(seen.insert(id.to_owned()), "{id} came twice");
        }
        assert_eq!(seen.len(), 20_000, "compress={compress}");
        let (frames, text) = peer.received().read();
        assert!(text > 50 << 20, "the list is past 50 MB: {text}");
        if compress {
            assert!(frames * 4 < text, "compressed: {frames} frame bytes for {text} text bytes");
        } else {
            assert_eq!(frames, text, "an older server's frames are its text");
        }
        println!(
            "PERF link compress={compress} rows={} text={text} frames={frames} ms={}",
            seen.len(),
            took.as_millis()
        );
        peer.stop();
        link.abort();
        server.abort();
    }
}

/// A client that never asks (every build before this one) reads Text frames only, and the
/// initialize reply says nothing of compression.
#[tokio::test]
async fn a_client_that_does_not_ask_gets_text_frames() {
    let port = listening_fleet(2, 200).await;
    for ask in [false, true] {
        let mut req = format!("ws://127.0.0.1:{port}").into_client_request().unwrap();
        req.headers_mut().insert("authorization", format!("Bearer {TOKEN}").parse().unwrap());
        let (mut ws, _) = tokio_tungstenite::connect_async(req).await.unwrap();
        let meta = if ask { json!({"acpmux": {"compression": ["zlib"]}}) } else { json!({}) };
        let init = json!({"jsonrpc": "2.0", "id": 1, "method": method::INITIALIZE,
            "params": {"protocolVersion": 1, "_meta": meta}});
        let watch = json!({"jsonrpc": "2.0", "id": 2, "method": method::MUX_WATCH,
            "params": {"enabled": true}});
        ws.send(Frame::Text(init.to_string().into())).await.unwrap();
        ws.send(Frame::Text(watch.to_string().into())).await.unwrap();
        let (mut binary, mut answered) = (0, HashSet::new());
        while answered.len() < 2 {
            let frame = tokio::time::timeout(Duration::from_secs(30), ws.next())
                .await
                .expect("a reply")
                .expect("open")
                .unwrap();
            let text = match frame {
                Frame::Text(t) => t.to_string(),
                Frame::Binary(b) => {
                    binary += 1;
                    crate::frame_compress::inflate(&b, 64 << 20).unwrap()
                }
                _ => continue,
            };
            let reply: Value = serde_json::from_str(&text).unwrap();
            match reply["id"].as_u64() {
                Some(1) => {
                    let said = &reply["result"]["_meta"]["acpmux"]["compression"];
                    assert_eq!(said.as_str() == Some("zlib"), ask, "{said}");
                    answered.insert(1);
                }
                Some(2) => {
                    assert_eq!(reply["result"]["sessions"].as_array().unwrap().len(), 400);
                    answered.insert(2);
                }
                _ => {}
            }
        }
        assert_eq!(binary > 0, ask, "binary frames when asked={ask}: {binary}");
    }
}

/// A compressed frame that inflates to no JSON-RPC message ends the link with why: it may have
/// been the reply a caller waits on (here the handshake's `initialize`).
#[tokio::test]
async fn a_compressed_frame_that_is_not_json_rpc_ends_the_link() {
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
        while let Some(Ok(frame)) = ws.next().await {
            if let Frame::Text(_) = frame {
                let bad = crate::frame_compress::deflate(b"{\"jsonrpc\": \"2.0\", \"id\": 1, ");
                let _ = ws.send(Frame::Binary(bad.into())).await;
            }
        }
    });
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("bad", &format!("ws://127.0.0.1:{port}"), Some(TOKEN.into()), None, tx);
    let link = tokio::spawn(peer.clone().run());
    let why = loop {
        let (_, _, notice) = tokio::time::timeout(Duration::from_secs(10), notices.recv())
            .await
            .expect("the link ends instead of waiting out the handshake")
            .expect("the link reports");
        match notice {
            PeerNotice::Disconnected(why) => break why,
            PeerNotice::Connected => panic!("connected on a bad reply"),
            _ => {}
        }
    };
    assert!(why.contains("not a JSON-RPC message"), "{why}");
    peer.stop();
    link.abort();
    server.abort();
}
