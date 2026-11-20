//! The link's own attach of a peer's chat (`hidden_attach`) after a reconnect. One the peer
//! refuses is no longer marked attached, so the next prompt attaches it again; before, the
//! refusal went nowhere and the chat stayed marked, so it never streamed again on that link.
//! One that fails any other way (here an internal error) keeps its mark for the next link, and
//! so does one a client marked again while the attach was out.

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// A fake peer on `server` that answers every request with `{}`, `_acpmux/watch` with no rows,
/// refuses the attach of chat `refused` (not found) and fails that of `failing` (an internal
/// error). Sends each method it reads on `seen`. With `held`, it says on the first sender when
/// the refused attach came and refuses it only once the second fires.
fn fake_peer(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    refused: &'static str,
    failing: &'static str,
    seen: mpsc::UnboundedSender<String>,
    held: Option<(oneshot::Sender<()>, oneshot::Receiver<()>)>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut held = held;
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let m = msg["method"].as_str().unwrap_or_default().to_owned();
            let _ = seen.send(m.clone());
            let Some(id) = msg.get("id").cloned() else { continue };
            let reply = if m == method::MUX_WATCH {
                Message::ok(id, json!({"sessions": []}))
            } else if m == method::MUX_ATTACH && msg["params"]["sessionId"] == refused {
                if let Some((came, release)) = held.take() {
                    let _ = came.send(());
                    let _ = release.await;
                }
                Message::err(id, RpcError::not_found(format!("no session {refused}")))
            } else if m == method::MUX_ATTACH && msg["params"]["sessionId"] == failing {
                Message::err(id, RpcError::internal("the attach failed for now"))
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
    peer.mark_attached("later");
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (seen_tx, mut seen) = mpsc::unbounded_channel();
    let fake = fake_peer(server, "gone", "later", seen_tx, None);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

    // The handshake asks the peer's health only once every attach was answered.
    let mut methods = Vec::new();
    while !methods.iter().any(|m| m == "_acpmux/host_health") {
        let m = tokio::time::timeout(Duration::from_secs(5), seen.recv())
            .await
            .expect("the handshake reaches its health read")
            .expect("the fake peer runs");
        methods.push(m);
    }
    assert_eq!(methods.iter().filter(|m| *m == method::MUX_ATTACH).count(), 3, "{methods:?}");
    let marked = peer.attached.lock_or_recover().clone();
    assert!(marked.contains_key("kept"), "{marked:?}");
    assert!(
        marked.contains_key("later"),
        "an attach that failed for now lost its mark: {marked:?}"
    );
    assert!(!marked.contains_key("gone"), "a refused attach stayed marked: {marked:?}");
    serving.abort();
    fake.abort();
}

#[tokio::test]
async fn a_chat_marked_again_while_its_refused_attach_was_out_stays_marked() {
    let (tx, _notices) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    peer.mark_attached("relied");
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (seen_tx, mut seen) = mpsc::unbounded_channel();
    let (came_tx, came) = oneshot::channel();
    let (release, release_rx) = oneshot::channel();
    let fake = fake_peer(server, "relied", "none", seen_tx, Some((came_tx, release_rx)));
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });

    // The reconnect's attach is out; a prompt for the chat finds it marked and relies on it.
    tokio::time::timeout(Duration::from_secs(5), came).await.expect("the attach goes").unwrap();
    assert!(!peer.mark_attached("relied"), "the chat was marked already");
    release.send(()).unwrap();
    loop {
        let m = tokio::time::timeout(Duration::from_secs(5), seen.recv())
            .await
            .expect("the handshake reaches its health read")
            .expect("the fake peer runs");
        if m == "_acpmux/host_health" {
            break;
        }
    }
    let marked = peer.attached.lock_or_recover().clone();
    assert!(
        marked.contains_key("relied"),
        "a refusal took the mark a prompt relied on: {marked:?}"
    );
    serving.abort();
    fake.abort();
}
