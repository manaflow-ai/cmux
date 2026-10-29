//! Accepted prompt waits survive transport loss; recovery never submits another prompt.
use super::*;

async fn asking()
-> (Arc<Peer>, mpsc::Receiver<Outbound>, tokio::task::JoinHandle<Result<Value, RpcError>>, String) {
    let (notices, _) = mpsc::channel(16);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, notices);
    let mut outbound = peer.out_rx.lock().await.take().unwrap();
    let caller = peer.clone();
    let ask = tokio::spawn(async move {
        caller
            .link_request_on(
                method::SESSION_PROMPT,
                json!({
                    "sessionId": "s", "prompt": [{"type": "text", "text": "run once"}],
                    "_meta": {"acpmux": {"promptId": "p"}},
                }),
                None,
            )
            .await
    });
    let sent =
        tokio::time::timeout(Duration::from_secs(2), outbound.recv()).await.unwrap().unwrap();
    (peer, outbound, ask, sent.key.unwrap())
}

fn accepted(peer: &Peer, key: &str) {
    peer.prompts.lock_or_recover().get_mut(key).unwrap().accepted = true;
    peer.on_wire.lock_or_recover().insert(key.to_owned());
}

#[tokio::test]
async fn accepted_prompt_survives_drop_and_recovers_only_its_original_outcome() {
    let (peer, mut outbound, ask, key) = asking().await;
    accepted(&peer, &key);
    peer.fail_link_requests(&mut outbound).await;
    assert_eq!(peer.pending_requests().await, 1);
    assert!(!ask.is_finished(), "accepted prompt failed with its transport");
    peer.link_ended();
    peer.recover_prompts(peer.link_epoch()).await.unwrap();
    let recovery = outbound.recv().await.unwrap();
    assert_eq!(recovery.epoch, peer.link_epoch());
    assert_eq!(recovery.key.as_deref(), Some(key.as_str()));
    let message: Value = serde_json::from_str(&recovery.line).unwrap();
    assert_eq!(message["method"], method::MUX_WAIT);
    assert_eq!(message["id"].to_string(), key);
    assert_eq!(
        message["params"],
        json!({"sessionId": "s", "promptId": "p", "until": ["promptOutcome"]})
    );
    assert!(outbound.try_recv().is_err(), "recovery sent an extra request");
    // Even another drop before recovery answers retains the same waiter.
    peer.fail_link_requests(&mut outbound).await;
    let result = json!({"stopReason": "end_turn", "_meta": {"acpmux": {"promptId": "p"}}});
    peer.pending.lock().await.remove(&key).unwrap().send(Ok(result.clone())).unwrap();
    assert_eq!(ask.await.unwrap().unwrap(), result);
    assert!(peer.prompts.lock_or_recover().is_empty());
}

#[tokio::test]
async fn unaccepted_prompt_distinguishes_sent_from_unsent_on_drop() {
    for on_wire in [false, true] {
        let (peer, mut outbound, ask, key) = asking().await;
        if on_wire {
            peer.on_wire.lock_or_recover().insert(key);
        }
        peer.fail_link_requests(&mut outbound).await;
        let error =
            tokio::time::timeout(Duration::from_secs(2), ask).await.unwrap().unwrap().unwrap_err();
        let reason = if on_wire { "peer_disconnected" } else { "peer_unreachable" };
        assert_eq!(error.data.unwrap()["reason"], reason);
        assert_eq!(peer.pending_requests().await, 0);
        assert!(peer.prompts.lock_or_recover().is_empty());
    }
}

#[tokio::test]
async fn stopping_a_peer_finishes_an_accepted_wait_retained_after_a_drop() {
    let (peer, mut outbound, ask, key) = asking().await;
    accepted(&peer, &key);
    peer.fail_link_requests(&mut outbound).await;
    *peer.out_rx.lock().await = Some(outbound);
    peer.stop();
    peer.clone().run().await;
    assert!(tokio::time::timeout(Duration::from_secs(2), ask).await.unwrap().unwrap().is_err());
    assert_eq!(peer.pending_requests().await, 0);
    assert!(peer.prompts.lock_or_recover().is_empty());
}

#[tokio::test]
async fn dropping_an_accepted_prompt_wait_cleans_recovery_metadata() {
    let (peer, mut outbound, ask, key) = asking().await;
    accepted(&peer, &key);
    peer.fail_link_requests(&mut outbound).await;
    ask.abort();
    assert!(ask.await.unwrap_err().is_cancelled());
    assert_eq!(peer.pending_requests().await, 0);
    assert!(peer.prompts.lock_or_recover().is_empty());
    assert!(peer.on_wire.lock_or_recover().is_empty());
    peer.recover_prompts(peer.link_epoch()).await.unwrap();
    assert!(outbound.try_recv().is_err(), "an abandoned waiter was recovered");
}

#[test]
fn hidden_attach_uses_its_snapshot_without_overwriting_newer_live_events() {
    let (notices, _) = mpsc::channel(16);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, notices);
    peer.mark_attached("s");
    peer.note_hidden_attach_page("s", &json!({"events": [], "pageThrough": 40, "lastSeq": 50}));
    assert_eq!(peer.attached.lock_or_recover()["s"], 40, "use the snapshot, not later history");
    peer.note_live(&json!({"sessionId": "s", "_meta": {"acpmux": {"seq": 42}}}));
    peer.note_hidden_attach_page("s", &json!({"events": [], "pageThrough": 40}));
    assert_eq!(
        peer.attached.lock_or_recover()["s"],
        42,
        "a delayed response cannot rewind live events"
    );
    assert!(!peer.mark_attached("s"), "another prompt retains the same stream baseline");
    peer.mark_attached("old-peer");
    peer.note_hidden_attach_page("old-peer", &json!({"events": [], "lastSeq": 9}));
    assert_eq!(
        peer.attached.lock_or_recover()["old-peer"],
        0,
        "an unbounded lastSeq is not a safe snapshot"
    );
}

#[tokio::test]
async fn reconnect_replays_before_admitting_a_concurrent_attach() {
    replay_during_handshake(false).await;
}

#[tokio::test]
async fn an_attachment_registered_during_handshake_is_gated_during_replay() {
    replay_during_handshake(true).await;
}

async fn replay_during_handshake(late_attach: bool) {
    use tokio_tungstenite::WebSocketStream;
    use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};
    async fn request(ws: &mut WebSocketStream<tokio::io::DuplexStream>) -> Value {
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(2), ws.next())
                .await
                .unwrap()
                .unwrap()
                .unwrap();
            if let Frame::Text(text) = frame {
                return serde_json::from_str(&text).unwrap();
            }
        }
    }
    async fn reply(ws: &mut WebSocketStream<tokio::io::DuplexStream>, req: &Value, result: Value) {
        ws.send(Frame::Text(
            json!({"jsonrpc": "2.0", "id": req["id"], "result": result}).to_string().into(),
        ))
        .await
        .unwrap();
    }
    let event = |seq| json!({"sessionId": "s", "seq": seq, "at": 1, "dir": "mux", "kind": "turn_end", "msg": {}});
    let (tx, mut notices) = mpsc::channel(64);
    let peer = Peer::new("box", "ws://127.0.0.1:9", None, None, tx);
    let cursor = if late_attach { 0 } else { 10 };
    if !late_attach {
        peer.mark_attached("s");
        peer.note_hidden_attach_page("s", &json!({"events": [], "pageThrough": cursor}));
    }
    let (ours, theirs) = tokio::io::duplex(1 << 16);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let mut server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move { link.serve(client, &mut out_rx).await });
    let init = request(&mut server).await;
    assert_eq!(init["method"], method::INITIALIZE);
    reply(&mut server, &init, json!({})).await;
    let watch = request(&mut server).await;
    assert_eq!(watch["method"], method::MUX_WATCH);
    if late_attach {
        // A forwarder registers interest before discovering that the link is
        // still handshaking. This was absent from serve's initial gate snapshot.
        peer.mark_attached("s");
    } else {
        // Traffic triggered by watch/recovery cannot advance the cursor past the gap.
        server
            .send(Frame::Text(
                Message::notification(method::MUX_EVENT, event(cursor + 2))
                    .to_value()
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
    }
    reply(&mut server, &watch, json!({"sessions": [{"sessionId": "s"}]})).await;
    let replay = request(&mut server).await;
    assert_eq!(replay["method"], method::MUX_ATTACH);
    assert_eq!(replay["params"]["afterSeq"], cursor, "do not skip history or the replay gap");
    if late_attach {
        // Live notification and page contain the same event. The wire order
        // ensures the reader consumes the live frame before the replay answer.
        server
            .send(Frame::Text(
                Message::notification(method::MUX_EVENT, event(cursor + 2))
                    .to_value()
                    .to_string()
                    .into(),
            ))
            .await
            .unwrap();
    }
    assert!(!peer.connected.load(Ordering::SeqCst), "replay has not reached subscribers yet");
    let concurrent = tokio::time::timeout(
        Duration::from_secs(2),
        peer.request(method::MUX_ATTACH, json!({"sessionId": "s"})),
    )
    .await
    .expect("attach must be refused immediately during replay")
    .unwrap_err();
    assert_eq!(concurrent.data.unwrap()["reason"], "peer_unreachable");
    reply(
        &mut server,
        &replay,
        json!({"events": [event(cursor + 1), event(cursor + 2)], "hasMore": true}),
    )
    .await;
    let next = request(&mut server).await;
    assert_eq!(next["params"]["afterSeq"], cursor + 2);
    assert!(!peer.connected.load(Ordering::SeqCst), "all bounded pages must finish");
    reply(&mut server, &next, json!({"events": [event(cursor + 3)], "hasMore": false})).await;
    let mut seqs = Vec::new();
    loop {
        let (_, _, notice) =
            tokio::time::timeout(Duration::from_secs(2), notices.recv()).await.unwrap().unwrap();
        match notice {
            PeerNotice::Notification { method: m, params, .. } if m == method::MUX_EVENT => {
                seqs.push(params["seq"].as_u64().unwrap())
            }
            PeerNotice::Connected => break,
            _ => {}
        }
    }
    assert_eq!(
        seqs,
        vec![cursor + 1, cursor + 2, cursor + 3],
        "subscribers receive each gap event once, before readiness"
    );
    assert!(peer.connected.load(Ordering::SeqCst));
    peer.stop();
    tokio::time::timeout(Duration::from_secs(2), serving).await.unwrap().unwrap().unwrap();
}
