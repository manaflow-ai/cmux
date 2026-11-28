//! The ABI range on a peer link (hq RFD 0224, phase 2): a daemon's link to another daemon sends
//! `{abi, abiMin}` in its `initialize`, and ends, typed `version.incompatible`, only when the far
//! daemon's answer names a range that shares no revision with this build's. N-1, N+1 and a far
//! daemon from before the fields all connect.

use super::*;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

/// A fake far daemon on `server`: `initialize` is answered with `init`, a watch with an empty
/// list, anything else with `{}`. The `initialize` params it got go out on `hello`.
fn fake_daemon(
    mut server: WebSocketStream<tokio::io::DuplexStream>,
    init: Value,
    hello: mpsc::UnboundedSender<Value>,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        while let Some(Ok(frame)) = server.next().await {
            let Frame::Text(text) = frame else { continue };
            let msg: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = msg.get("id").cloned() else { continue };
            let result = if msg["method"] == method::INITIALIZE {
                let _ = hello.send(msg["params"].clone());
                init.clone()
            } else if msg["method"] == method::MUX_WATCH {
                json!({"sessions": []})
            } else {
                json!({})
            };
            let line = Message::ok(id, result).to_line();
            if server.send(Frame::Text(line.trim_end().to_owned().into())).await.is_err() {
                return;
            }
        }
    })
}

/// Serves one link against a far daemon answering `initialize` with `init`: whether it connected
/// (`Ok(())`) or how it ended, and the hello it sent.
async fn link_against(init: Value) -> (Result<(), String>, Value) {
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("far", "ws://127.0.0.1:9", None, None, tx);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let (hello_tx, mut hello_rx) = mpsc::unbounded_channel();
    let fake = fake_daemon(server, init, hello_tx);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let mut serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let outcome = loop {
        tokio::select! {
            ended = &mut serving => {
                break match ended.expect("serve does not panic") {
                    Ok(end) => Err(format!("ended: {end:?}")),
                    Err(e) => Err(e),
                };
            }
            notice = notices.recv() => {
                if matches!(notice, Some((_, _, PeerNotice::Connected))) {
                    break Ok(());
                }
            }
            _ = tokio::time::sleep(Duration::from_secs(5)) => break Err("timed out".to_owned()),
        }
    };
    serving.abort();
    fake.abort();
    let hello = hello_rx.try_recv().expect("the link sent its initialize");
    (outcome, hello)
}

fn answer(abi: u32, min: u32) -> Value {
    json!({"_meta": {"acpmux": {"version": "x", "build": "far", "abi": abi, "abiMin": min}}})
}

#[tokio::test]
async fn a_peer_link_hello_carries_the_range() {
    let (outcome, hello) = link_against(answer(crate::protocol::ABI, 0)).await;
    assert_eq!(outcome, Ok(()));
    assert_eq!(hello["_meta"]["acpmux"]["abi"], json!(crate::protocol::ABI));
    assert_eq!(
        hello["_meta"]["acpmux"][crate::protocol::range::ABI_MIN_FIELD],
        json!(crate::protocol::range::ABI_MIN)
    );
}

#[tokio::test]
async fn n_minus_1_and_n_plus_1_far_daemons_connect() {
    let n = crate::protocol::ABI;
    assert_eq!(link_against(answer(n - 1, 0)).await.0, Ok(()), "N-1");
    assert_eq!(link_against(answer(n + 1, n)).await.0, Ok(()), "N+1 that still serves N");
}

#[tokio::test]
async fn a_far_daemon_from_before_the_fields_connects() {
    let (outcome, _) = link_against(json!({"_meta": {"acpmux": {"version": "old"}}})).await;
    assert_eq!(outcome, Ok(()));
    let (outcome, _) = link_against(json!({})).await;
    assert_eq!(outcome, Ok(()));
}

#[tokio::test]
async fn a_far_daemon_with_no_overlap_ends_the_link_typed() {
    let n = crate::protocol::ABI;
    let (outcome, _) = link_against(answer(n + 3, n + 1)).await;
    let error = outcome.expect_err("no revision in common");
    assert!(error.contains("version.incompatible"), "{error}");
    assert!(error.contains("the peer daemon is newer"), "{error}");
    assert!(error.contains("acpmux host self-update"), "{error}");
}
