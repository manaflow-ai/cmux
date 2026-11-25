use super::*;
use tokio_tungstenite::{
    WebSocketStream,
    tungstenite::{Message as Frame, protocol::Role},
};

#[tokio::test]
async fn controls_resync_reopens_snapshot_and_retires_only_ask_keys_with_watch_kept() {
    const WATCH_METHOD: &str = concat!("_acpmux/", "watch");
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("owner", "ws://127.0.0.1:9", None, None, tx);
    let links = Arc::new(crate::link_v2::Shared::default());
    let (index, writer) = acpmux_core::hub::Hub::new(acpmux_book::index::SummaryIndex::new());
    links.install(Arc::new(acpmux_core::life::V2::with_surfaces(
        index,
        writer,
        ["list", "peers"].into_iter().map(str::to_owned).collect(),
    )));
    peer.set_mirror(links);
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client =
        WebSocketStream::from_raw_socket(ours, Role::Client, Some(crate::server::ws_config()))
            .await;
    let mut server =
        WebSocketStream::from_raw_socket(theirs, Role::Server, Some(crate::server::ws_config()))
            .await;
    let watches = Arc::new(AtomicU64::new(0));
    let opened = Arc::new(AtomicU64::new(0));
    let watch_count = watches.clone();
    let open_count = opened.clone();
    let fake = tokio::spawn(async move {
        while let Some(Ok(Frame::Text(text))) = server.next().await {
            let request: Value = serde_json::from_str(&text).unwrap();
            let Some(id) = request.get("id") else { continue };
            let method = request["method"].as_str().unwrap_or_default();
            let result = match method {
                method::INITIALIZE => json!({"_meta": {"acpmux": {
                    "origin": "peer", "personInstance": "owner-run", "features": [FEATURE]}}}),
                WATCH_METHOD => {
                    watch_count.fetch_add(1, Ordering::SeqCst);
                    json!({"sessions": []})
                }
                METHOD if request["params"]["kinds"].is_array() => {
                    let n = open_count.fetch_add(1, Ordering::SeqCst) + 1;
                    let entries = if n == 1 {
                        vec![json!({"kind": "asks", "key": ["s", "a"],
                        "value": {"sessionId": "s", "permissionId": "a", "personInstance": "owner-run",
                            "decisionNonce": "nonce", "label": "A", "handle": "worker", "request": {}}})]
                    } else {
                        vec![]
                    };
                    json!({"stream": n.to_string(), "phase": "snapshot", "page": 0, "next": null, "entries": entries})
                }
                METHOD => {
                    json!({"stream": request["params"]["stream"], "phase": "live", "ready": true})
                }
                _ => json!({}),
            };
            server
                .send(Frame::Text(Message::ok(id.clone(), result).to_line().into()))
                .await
                .unwrap();
            if method == METHOD
                && request["params"]["live"] == true
                && open_count.load(Ordering::SeqCst) == 1
            {
                server.send(Frame::Text(Message::notification(crate::server::controls::NOTICE,
                    json!({"stream": "1", "phase": "resync", "origin": "local", "reason": "overflow"})).to_line().into())).await.unwrap();
            }
        }
    });
    let mut output = peer.out_rx.lock().await.take().unwrap();
    let serving_peer = peer.clone();
    let serving = tokio::spawn(async move { serving_peer.serve(client, &mut output).await });
    let saw_notification = tokio::time::timeout(Duration::from_millis(300), async {
        while let Some((_, _, notice)) = notices.recv().await {
            if matches!(notice, PeerNotice::Notification { .. }) {
                return true;
            }
        }
        false
    })
    .await
    .unwrap_or(false);
    assert!(!saw_notification, "controls are state-only while the legacy watch runs");
    assert_eq!(watches.load(Ordering::SeqCst), 1, "the existing watch stays active");
    assert_eq!(opened.load(Ordering::SeqCst), 2);
    serving.abort();
    fake.abort();
    peer.stop_controls(peer.link_epoch());
}

#[test]
fn controls_keys_are_typed_and_bounded() {
    assert!(ask_key(&json!({"kind": "asks", "key": ["s", "a"]})).is_some());
    for entry in [
        json!({"kind": "asks", "key": ["s"]}),
        json!({"kind": "ready", "key": ["s", "a"]}),
        json!({"kind": "asks", "key": ["s".repeat(1025), "a"]}),
    ] {
        assert!(ask_key(&entry).is_none());
    }
}
