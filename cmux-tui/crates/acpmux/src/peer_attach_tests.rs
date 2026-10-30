//! The link's own attach of a peer's chat (`hidden_attach`) after a reconnect. One the peer
//! refuses is no longer marked attached, so the next prompt attaches it again; before, the
//! refusal went nowhere and the chat stayed marked, so it never streamed again on that link.

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// A fake peer on `server` that answers every request with `{}`, `_acpmux/watch` with no rows,
/// and refuses the attach of chat `refused`. Sends each method it reads on `seen`.
fn fake_peer(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    refused: &'static str,
    seen: mpsc::UnboundedSender<String>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let m = msg["method"].as_str().unwrap_or_default().to_owned();
            let _ = seen.send(m.clone());
            let Some(id) = msg.get("id").cloned() else { continue };
            let reply = if m == method::MUX_WATCH {
                Message::ok(id, json!({"sessions": []}))
            } else if m == method::MUX_ATTACH && msg["params"]["sessionId"] == refused {
                Message::err(id, RpcError::not_found(format!("no session {refused}")))
            } else {
                Message::ok(id, json!({}))
            };
            let line = reply.to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    })
}

#[tokio::test]
async fn a_chat_the_peer_refuses_to_attach_after_a_reconnect_is_no_longer_marked() {
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    peer.mark_attached("kept");
    peer.mark_attached("gone");
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (seen_tx, mut seen) = mpsc::unbounded_channel();
    let fake = fake_peer(server, "gone", seen_tx);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

    // The handshake asks the peer's health only once both attaches were answered.
    let mut methods = Vec::new();
    while !methods.iter().any(|m| m == "_acpmux/host_health") {
        let m = tokio::time::timeout(Duration::from_secs(5), seen.recv())
            .await
            .expect("the handshake reaches its health read")
            .expect("the fake peer runs");
        methods.push(m);
    }
    assert_eq!(methods.iter().filter(|m| *m == method::MUX_ATTACH).count(), 2, "{methods:?}");
    let marked = peer.attached.lock_or_recover().clone();
    assert!(marked.contains("kept"), "{marked:?}");
    assert!(!marked.contains("gone"), "a refused attach stayed marked: {marked:?}");
    serving.abort();
    fake.abort();
}
