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
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    watch: fn(bool) -> Result<Value, RpcError>,
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
