use super::*;

/// A prompt admitted on a link that went down before it was registered fails at once: the
/// next link drops its frame, and a prompt has no deadline, so it would wait for good.
#[tokio::test]
async fn a_prompt_admitted_on_a_link_that_went_down_fails_instead_of_waiting() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    let admitted_on = peer.link_epoch();
    // The link drops and the next one is up again before the request registers.
    peer.link_ended();
    let answer = tokio::time::timeout(
        Duration::from_secs(5),
        peer.link_request_on(method::SESSION_PROMPT, json!({}), Some(admitted_on)),
    )
    .await
    .expect("a prompt on a dead link must not wait");
    assert!(answer.is_err());
    assert_eq!(peer.pending_requests().await, 0, "no entry left behind");
}

/// A forwarded request its client cancels (`request_cancel.rs`): the peer hears
/// `$/cancel_request` for its id on the link it went out on, nothing waits on it any more,
/// and its id is kept so the late answer is dropped on purpose.
#[tokio::test]
async fn a_cancelled_request_tells_the_peer_and_waits_for_nothing() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    peer.open.store(true, Ordering::SeqCst);
    peer.features.lock_or_recover().push(crate::request_cancel::FEATURE.to_owned());
    let mut out = peer.out_rx.lock().await.take().unwrap();
    let (cancel, cancelled) = oneshot::channel();
    let asking = peer.clone();
    let task = tokio::spawn(async move {
        crate::request_cancel::until_cancelled(
            cancelled,
            asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
        )
        .await
    });
    let sent = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
    let request: Value = serde_json::from_str(&sent.line).unwrap();
    assert_eq!(peer.pending_requests().await, 1);
    cancel.send(()).unwrap();
    assert!(task.await.unwrap().is_none(), "the request gave up");
    let note = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
    let note: Value = serde_json::from_str(&note.line).unwrap();
    assert_eq!(note["method"], method::CANCEL_REQUEST);
    assert_eq!(note["params"]["requestId"], request["id"]);
    assert_eq!(peer.pending_requests().await, 0, "no entry left behind");
    let key = request["id"].to_string();
    assert!(peer.cancelled.lock_or_recover().take_late(&key, "peer"), "its answer is dropped");
}

/// Review F1 of #41285: the peer's answer comes between the cancel and the cleanup of its
/// entry (the pending map was busy as the request was dropped). It reaches a waiter that is
/// gone, so it is dropped and logged as late, never lost unlogged, and a peer that already
/// answered hears no cancel.
#[tokio::test]
async fn an_answer_between_the_cancel_and_the_cleanup_is_dropped_as_late() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    peer.open.store(true, Ordering::SeqCst);
    peer.features.lock_or_recover().push(crate::request_cancel::FEATURE.to_owned());
    let mut out = peer.out_rx.lock().await.take().unwrap();
    let (cancel, cancelled) = oneshot::channel();
    let asking = peer.clone();
    let task = tokio::spawn(async move {
        crate::request_cancel::until_cancelled(
            cancelled,
            asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
        )
        .await
    });
    let sent = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
    let request: Value = serde_json::from_str(&sent.line).unwrap();
    let key = request["id"].to_string();
    let mut busy = peer.pending.lock().await;
    cancel.send(()).unwrap();
    assert!(task.await.unwrap().is_none(), "the request gave up");
    // The link's reader takes the answer's entry while the cleanup waits for the map.
    let waiter = busy.remove(&key).expect("the entry is still there");
    assert!(waiter.send(Ok(json!({}))).is_err(), "its waiter is gone");
    drop(busy);
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while peer.cancelled.lock_or_recover().dropped == 0 && tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(peer.cancelled.lock_or_recover().dropped, 1, "dropped as late, and logged");
    assert!(peer.cancelled.lock_or_recover().is_empty(), "no id kept for an answer that came");
    assert_eq!(peer.pending_requests().await, 0);
    assert!(out.try_recv().is_err(), "a peer that answered hears no cancel");
}

/// Review F2 of #41285: a cancel to a peer whose outbound queue is full is never dropped:
/// it goes out once there is room (an awaited send).
#[tokio::test]
async fn a_cancel_to_a_peer_with_a_full_queue_still_goes_out() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    peer.open.store(true, Ordering::SeqCst);
    peer.features.lock_or_recover().push(crate::request_cancel::FEATURE.to_owned());
    let mut out = peer.out_rx.lock().await.take().unwrap();
    let (cancel, cancelled) = oneshot::channel();
    let asking = peer.clone();
    let task = tokio::spawn(async move {
        crate::request_cancel::until_cancelled(
            cancelled,
            asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
        )
        .await
    });
    let sent = tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
    let request: Value = serde_json::from_str(&sent.line).unwrap();
    let mut filler = 0;
    while peer.out.try_send(Outbound { epoch: sent.epoch, key: None, line: "{}".into() }).is_ok() {
        filler += 1;
    }
    assert!(filler > 0, "the queue was filled");
    cancel.send(()).unwrap();
    assert!(task.await.unwrap().is_none(), "the request gave up");
    for _ in 0..filler {
        let frame = out.recv().await.unwrap();
        assert_eq!(frame.line, "{}");
    }
    let note = tokio::time::timeout(Duration::from_secs(5), out.recv())
        .await
        .expect("the cancel went out once there was room")
        .unwrap();
    let note: Value = serde_json::from_str(&note.line).unwrap();
    assert_eq!(note["method"], method::CANCEL_REQUEST);
    assert_eq!(note["params"]["requestId"], request["id"]);
    assert_eq!(peer.pending_requests().await, 0);
}

/// A peer that does not list the feature hears nothing more: an older daemon.
#[tokio::test]
async fn an_older_peer_gets_no_cancel_frame() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    peer.open.store(true, Ordering::SeqCst);
    let mut out = peer.out_rx.lock().await.take().unwrap();
    let (cancel, cancelled) = oneshot::channel();
    let asking = peer.clone();
    let task = tokio::spawn(async move {
        crate::request_cancel::until_cancelled(
            cancelled,
            asking.request(method::MUX_INFO, json!({"sessionId": "s"})),
        )
        .await
    });
    tokio::time::timeout(Duration::from_secs(5), out.recv()).await.unwrap().unwrap();
    cancel.send(()).unwrap();
    assert!(task.await.unwrap().is_none());
    assert!(tokio::time::timeout(Duration::from_millis(200), out.recv()).await.is_err());
    assert_eq!(peer.pending_requests().await, 0);
}

/// Review of #24797 at 45ab6b1: lending was on for a plain `ws://` peer on another host, so
/// anything on the path could answer the handshake as that peer and ask as it.
#[test]
fn github_is_lent_only_over_ssh_tls_or_loopback() {
    let (tx, _rx) = mpsc::channel(8);
    for (url, lends) in [
        ("ws://10.0.0.5:7777", false),
        ("ws://box.example:7777", false),
        ("ws://127.0.0.1:7777", true),
        ("ws://localhost:7777", true),
        ("ws://[::1]:7777", true),
        ("ws://127.0.0.2:7777", true),
        ("ws://[::2]:7777", false),
        ("wss://box.example", true),
        ("ssh://leo@box.example", true),
    ] {
        let peer = Peer::new("p", url, None, None, tx.clone());
        peer.set_github_broker(true);
        assert_eq!(peer.github_broker(), lends, "{url}");
    }
}

/// Review of #24797 at ee07ea5: an action admitted just before the peer stopped took the
/// epoch after the stop as its own, so it still ran.
#[tokio::test]
async fn an_action_admitted_before_a_stop_never_runs() {
    let (tx, _rx) = mpsc::channel(8);
    let peer = Peer::new("stopped-mid-admit", "ws://127.0.0.1:9", None, None, tx);
    peer.set_github_broker(true);
    let link = peer.link_epoch();
    peer.github_link.store(link + 1, Ordering::SeqCst);
    let slot =
        crate::github_broker::admit_owner(&peer.name, peer.github_ready(link), &peer.github_slots)
            .unwrap();
    peer.stop();
    let mut out = peer.out_rx.lock().await.take().unwrap();
    peer.serve_github_action(json!(1), json!({"action": "read", "repo": "o/r"}), slot, link);
    let sent = tokio::time::timeout(Duration::from_secs(1), out.recv()).await;
    assert!(sent.is_err(), "nothing ran or answered: {:?}", sent.ok().flatten().map(|f| f.line));
    assert_eq!(peer.github_slots.available_permits(), crate::github_broker::OWNER_SLOTS);
}

/// Review of #24797 at 30e24d1: each reconnect's new peer had slots of its own while the
/// old one's GitHub actions still ran, so reconnects started more than `OWNER_SLOTS` `gh`s.
#[tokio::test]
async fn a_reconnect_shares_its_github_slots_with_the_actions_still_running() {
    let (tx, _rx) = mpsc::channel(8);
    let old = Peer::new("slots-across-reconnects", "ws://127.0.0.1:9", None, None, tx.clone());
    let running: Vec<_> = (0..crate::github_broker::OWNER_SLOTS)
        .map(|_| crate::github_broker::admit_owner(&old.name, true, &old.github_slots).unwrap())
        .collect();
    old.stop();
    let new = Peer::new("slots-across-reconnects", "ws://127.0.0.1:9", None, None, tx);
    let e = crate::github_broker::admit_owner(&new.name, true, &new.github_slots).unwrap_err();
    assert_eq!(e.data.unwrap()["reason"], "github.busy");
    drop(running);
    assert!(crate::github_broker::admit_owner(&new.name, true, &new.github_slots).is_ok());
}
