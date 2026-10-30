//! `_acpmux/peer_state_changed`: a watching connection hears each change of a peer link's
//! state once, from the code that made it (no timer, no polling): the first state when the
//! peer is added, connected only once the handshake finished, reconnecting when the WebSocket
//! drops (and no repeat while the retries fail or a reconnect replaces the instance), and a
//! last offline when it is removed.

// Unix only until the Windows port runs the daemon (cmux::local_socket).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::{Message, method};
use acpmux::server::{bind_ws, serve_connection, serve_ws};
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

fn hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// The reply to request `id`.
async fn reply(rx: &mut mpsc::Receiver<String>, id: i64) -> Value {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(10), rx.recv())
            .await
            .expect("an answer")
            .expect("the connection stays open");
        if let Ok(Message::Response { id: got, result, .. }) = Message::parse(&line)
            && got == json!(id)
        {
            return result.unwrap_or(Value::Null);
        }
    }
}

/// Every `_acpmux/peer_state_changed` for peer `name` until `done` accepts one, or for all of
/// `wait` when `done` is None.
async fn notes(
    rx: &mut mpsc::Receiver<String>,
    name: &str,
    wait: Duration,
    done: Option<&str>,
) -> Vec<Value> {
    let end = Instant::now() + wait;
    let mut seen = Vec::new();
    while let Some(left) = end.checked_duration_since(Instant::now()) {
        let Ok(Some(line)) = tokio::time::timeout(left, rx.recv()).await else { break };
        let Ok(Message::Notification { method: m, params }) = Message::parse(&line) else {
            continue;
        };
        let params = params.unwrap_or(Value::Null);
        if m != "_acpmux/peer_state_changed" || params["peer"] != name {
            continue;
        }
        let state = params["state"].as_str().unwrap_or_default().to_owned();
        seen.push(params);
        if done == Some(state.as_str()) {
            break;
        }
    }
    seen
}

fn states(notes: &[Value]) -> Vec<&str> {
    notes.iter().map(|n| n["state"].as_str().unwrap_or("?")).collect()
}

/// An unforced reconnect with `wait` (the app's pick or send) of a peer still in its handshake
/// waits for that handshake to finish: it neither answers at once (the caller would then send to
/// a peer that is not connected yet) nor replaces the link. The peer here answers `initialize`
/// only when the test lets it, and takes one connection: a replaced link would never connect.
#[tokio::test]
async fn an_unforced_waiting_reconnect_waits_for_the_handshake_in_progress() {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::tungstenite::Message as Ws;

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (answer_tx, answer_rx) = tokio::sync::oneshot::channel::<()>();
    tokio::spawn(async move {
        let (tcp, _) = listener.accept().await.unwrap();
        drop(listener);
        let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
        let mut answer_rx = Some(answer_rx);
        while let Some(Ok(frame)) = ws.next().await {
            let Ws::Text(text) = frame else { continue };
            let Ok(Message::Request { id, method: m, .. }) = Message::parse(&text) else {
                continue;
            };
            let reply = if m == method::INITIALIZE {
                if let Some(gate) = answer_rx.take() {
                    let _ = gate.await;
                }
                Message::ok(
                    id,
                    json!({"protocolVersion": 1, "_meta": {"acpmux": {
                        "version": "0", "build": "test", "origin": "peer", "features": []}}}),
                )
            } else {
                Message::ok(id, json!({}))
            };
            if ws.send(Ws::Text(reply.to_line().into())).await.is_err() {
                break;
            }
        }
    });

    let a = hub();
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(a.clone(), in_rx, out_tx));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "peer-state-test"}});
    tx.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    reply(&mut rx, 1).await;
    tx.send(Message::request(2, method::MUX_WATCH, json!({"enabled": true})).to_line())
        .await
        .unwrap();
    reply(&mut rx, 2).await;

    let url = format!("ws://127.0.0.1:{port}");
    a.add_peer("b", &url, Some("tok".into()), None, false).await.unwrap();
    // Degraded: the WebSocket is open and the peer has not answered `initialize`.
    let open = notes(&mut rx, "b", Duration::from_secs(20), Some("degraded")).await;
    assert_eq!(states(&open).last(), Some(&"degraded"), "{open:?}");

    let reconnecting = a.clone();
    let reconnect =
        tokio::spawn(async move { reconnecting.reconnect_peer_with("b", true, false).await });
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!reconnect.is_finished(), "an unforced waiting reconnect answered mid-handshake");

    answer_tx.send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(10), reconnect)
        .await
        .expect("the reconnect answers once the handshake finished")
        .unwrap()
        .unwrap();
    assert_eq!(a.peers()[0]["connected"], true, "the link it waited for is up, not replaced");
}

#[tokio::test]
async fn a_watcher_hears_each_peer_state_change_once() {
    // B serves WebSocket; A reaches it through a TCP relay this test drops to cut the link.
    let b = hub();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let b_port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws(b, listener, "tok".into()));
    let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_port = relay.local_addr().unwrap().port();
    let relaying = tokio::spawn(async move {
        let (mut inbound, _) = relay.accept().await.unwrap();
        // One connection only: once it drops, the peer's retries are refused.
        drop(relay);
        let mut outbound = tokio::net::TcpStream::connect(("127.0.0.1", b_port)).await.unwrap();
        let _ = tokio::io::copy_bidirectional(&mut inbound, &mut outbound).await;
    });

    let a = hub();
    let (tx, in_rx) = mpsc::channel(64);
    let (out_tx, mut rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(a.clone(), in_rx, out_tx));
    let hello = json!({"protocolVersion": 1, "clientInfo": {"name": "peer-state-test"}});
    tx.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let init = reply(&mut rx, 1).await;
    tx.send(Message::request(2, method::MUX_WATCH, json!({"enabled": true})).to_line())
        .await
        .unwrap();
    reply(&mut rx, 2).await;

    let url = format!("ws://127.0.0.1:{relay_port}");
    a.add_peer("b", &url, Some("tok".into()), None, false).await.unwrap();
    let up = notes(&mut rx, "b", Duration::from_secs(20), Some("connected")).await;
    // Degraded is the handshake: the WebSocket is open and the peer has not answered yet.
    assert_eq!(states(&up), ["connecting", "degraded", "connected"], "{up:?}");
    let connected = &up[2];
    assert!(connected["lastSeen"].is_u64(), "{connected}");
    assert!(connected["error"].is_null(), "{connected}");
    assert!(connected["at"].is_u64(), "{connected}");
    assert_eq!(a.peers()[0]["connected"], true, "the note follows the peer row");

    // A reconnect that is not forced (the app's pick or send) leaves an open link alone: no new
    // attempt cuts it, so no note goes out.
    a.reconnect_peer_with("b", false, false).await.unwrap();
    let kept = notes(&mut rx, "b", Duration::from_secs(3), None).await;
    assert!(kept.is_empty(), "an unforced reconnect cut a live link: {kept:?}");
    assert_eq!(a.peers()[0]["connected"], true, "the link stayed up");

    // The WebSocket drops: reconnecting, once, however many retries fail after it.
    relaying.abort();
    let down = notes(&mut rx, "b", Duration::from_secs(20), Some("reconnecting")).await;
    assert_eq!(states(&down), ["reconnecting"], "{down:?}");
    assert!(down[0]["error"].is_string(), "a drop says why: {down:?}");
    // A reconnect replaces the instance; it is still reconnecting, so that is no news either.
    a.reconnect_peer("b", false).await.unwrap();
    let quiet = notes(&mut rx, "b", Duration::from_secs(6), None).await;
    assert!(quiet.is_empty(), "a repeat while the state stayed the same: {quiet:?}");
    assert!(
        a.peers()[0]["attempts"].as_u64().unwrap_or(0) >= 1,
        "the replacement's attempt failed in that window, so a repeat had a chance to go out"
    );

    // Removed: its last note.
    a.remove_peer("b").await.unwrap();
    let gone = notes(&mut rx, "b", Duration::from_secs(10), Some("offline")).await;
    assert_eq!(states(&gone), ["offline"], "{gone:?}");
    assert_eq!(gone[0]["error"], "removed", "{gone:?}");
    let after = notes(&mut rx, "b", Duration::from_secs(3), None).await;
    assert!(after.is_empty(), "a removed peer spoke again: {after:?}");

    // A client knows to listen for them from the feature list.
    let features = init.pointer("/_meta/acpmux/features").cloned().unwrap_or_default();
    assert!(
        features.as_array().is_some_and(|f| f.iter().any(|f| f == "peerStateEvents")),
        "{init}"
    );
}
