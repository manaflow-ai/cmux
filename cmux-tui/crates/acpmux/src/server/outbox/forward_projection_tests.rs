use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::{EventFilter, NewRequest};

fn config(mode: StoreMode) -> Config {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    }))
    .unwrap();
    config.store.mode = mode;
    config
}

#[tokio::test]
async fn forward_intent_requires_successful_persistence_even_on_retry() {
    let dir = std::env::temp_dir().join(format!("forward-write-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    // A regular file in the parent path injects a deterministic write failure,
    // including when the tests run as a user that can bypass file permissions.
    let blocked_parent = dir.join("blocked");
    std::fs::write(&blocked_parent, b"block").unwrap();
    let path = blocked_parent.join("outbox.json");
    let config = config(StoreMode::Memory);
    let hub = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
    hub.outbox.open(&path);
    let request = json!({"sessionId": "receiver", "text": "hello", "_meta": {"acpmux": {
        "promptId": "write-failure", "messageId": "message-write-failure",
        "messageSender": {"name": "sender", "sessionId": "sender"}
    }}});
    let error = remember_forward(&hub, "remote", "receiver", "sender", &request)
        .await
        .expect_err("a peer request must not proceed without its durable intent");
    assert!(error.message.contains("cannot persist peer message intent"));
    assert!(
        remember_forward(&hub, "remote", "receiver", "sender", &request).await.is_err(),
        "an existing in-memory intent must not bypass the failed write"
    );
    std::fs::remove_file(&blocked_parent).unwrap();
    std::fs::create_dir(&blocked_parent).unwrap();
    let id = remember_forward(&hub, "remote", "receiver", "sender", &request)
        .await
        .expect("retry succeeds once the intent can be persisted");
    let reopened = crate::hub::outbox::Outbox::default();
    let pending = reopened.open(&path);
    assert_eq!(pending.len(), 1, "retries preserve one durable intent");
    assert_eq!(pending[0].id, id);
    assert_eq!(pending[0].prompt_id(), "write-failure");
    assert!(pending[0].projection_only());
    std::fs::remove_dir_all(dir).unwrap();
}

/// A refusal that came back before its acceptance notice: the receiver's journal says
/// whether the message was taken, also when its copy lands only later (a repair after a
/// failed append). Until then the intent stays open, reading on the retry schedule.
#[tokio::test]
async fn a_refused_forward_reads_the_receiver_journal_once() {
    let dir = std::env::temp_dir().join(format!("forward-refused-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let config = config(StoreMode::Memory);
    let local = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
    let remote = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
    let new = |name: &str| NewRequest {
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        ..NewRequest::default()
    };
    let sender = local.new_session(new("sender")).await.unwrap();
    let receiver = remote.new_session(new("receiver")).await.unwrap();
    let auth_dir = dir.join("peer-auth");
    let auth = crate::server::peer_auth::PeerAuth::create(&auth_dir).unwrap();
    let token = std::fs::read_to_string(crate::server::peer_auth::token_path(&auth_dir)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        remote.clone(),
        listener,
        "test".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    local
        .add_peer(
            "remote",
            &format!("ws://127.0.0.1:{port}"),
            Some("test".into()),
            Some(token),
            true,
        )
        .await
        .unwrap();
    let sender_meta = json!({"name": "sender", "sessionId": sender.id, "host": "local"});
    let intent = async |prompt_id: &str| {
        let request = json!({"sessionId": receiver.id,
            "prompt": [{"type": "text", "text": "steer only"}], "_meta": {"acpmux": {
            "promptId": prompt_id, "messageSender": sender_meta
        }}});
        remember_forward(&local, "remote", &receiver.id, &sender.id, &request).await.unwrap()
    };
    let refusal = RpcError::invalid_params("no turn to steer");
    assert_eq!(next(&refusal), Next::Fail);

    let taken = intent("p-taken").await;
    assert!(remote.append_message_event(
        &receiver,
        sender_meta.clone(),
        "steer only".into(),
        "p-taken".into(),
        1234
    ));
    forward_refused(&local, &taken, &refusal);
    let done = outbox_status(&local, &taken, &json!({"waitMs": 10_000})).await.unwrap();
    assert_eq!(done["status"], "delivered", "{done}");

    // The receiver's copy is not there at the first read: the intent stays open, and the
    // copy a repair appends later still gains the sender's.
    let repaired = intent("p-repaired").await;
    forward_refused(&local, &repaired, &refusal);
    let open = outbox_status(&local, &repaired, &json!({"waitMs": 1_000})).await.unwrap();
    assert_eq!(open["status"], "held", "{open}");
    assert!(remote.append_message_event(
        &receiver,
        sender_meta.clone(),
        "steer only".into(),
        "p-repaired".into(),
        1234
    ));
    let done = outbox_status(&local, &repaired, &json!({"waitMs": 10_000})).await.unwrap();
    assert_eq!(done["status"], "delivered", "{done}");

    let page = local
        .events_page(&sender.id, 0, None, 500, None, false, &EventFilter::parse(None).unwrap())
        .unwrap();
    let ids: Vec<_> = page
        .events
        .iter()
        .filter(|r| r.kind == "_acpmux/message")
        .map(|r| r.msg["messageId"].clone())
        .collect();
    assert_eq!(ids, vec![json!("p-taken"), json!("p-repaired")]);
    std::fs::remove_dir_all(&dir).ok();
}

#[tokio::test]
async fn restarted_forward_recovers_sender_projection_without_resending_prompt() {
    let dir = std::env::temp_dir().join(format!("forward-projection-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let config = config(StoreMode::Local);
    let make_hub = || {
        let store = crate::store::open(&config.store, &dir).unwrap();
        Hub::new(config.clone(), store)
    };
    let original = make_hub();
    let outbox_path = dir.join("outbox.json");
    original.outbox.open(&outbox_path);
    let sender = original
        .new_session(NewRequest {
            name: Some("sender".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let remote_config = self::config(StoreMode::Memory);
    let remote =
        Hub::new(remote_config.clone(), crate::store::open(&remote_config.store, &dir).unwrap());
    let receiver = remote
        .new_session(NewRequest {
            name: Some("receiver".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .unwrap();
    let sender_meta = json!({"name": "sender", "sessionId": sender.id, "host": "local"});
    let request = json!({"sessionId": receiver.id,
        "prompt": [{"type": "text", "text": "already accepted"}], "_meta": {"acpmux": {
        "promptId": "p-restart", "messageId": "d-restart", "messageSender": sender_meta
    }}});
    let intent_id =
        remember_forward(&original, "remote", &receiver.id, &sender.id, &request).await.unwrap();
    // The receiver accepted before the source recorded its outgoing projection.
    // Fill a first page to ensure recovery advances beyond the first 256 records.
    for n in 0..257 {
        assert!(remote.append_message_event(
            &receiver,
            json!({"name": "other", "sessionId": "other"}),
            "earlier".into(),
            format!("prior-{n}"),
            1
        ));
    }
    assert!(remote.append_message_event(
        &receiver,
        sender_meta.clone(),
        "already accepted".into(),
        "d-restart".into(),
        1234
    ));
    let before = receiver.meta().event_count;
    original.detach_child(&sender).await;
    original.store.flush().unwrap();
    // The first daemon's shutdown seal: the journal's lock passes to the restarted one.
    original.seal();
    // Reopen the source state as daemon startup does: the outbox resumes before the saved
    // sessions load (`daemon.rs`). No original callback survives.
    let restarted = Hub::new_loading(
        config.clone(),
        crate::store::open(&config.store, &dir).unwrap(),
        crate::mailbox::Mailbox::open(dir.join("mailbox")).unwrap(),
    );
    let pending = restarted.outbox.open(&outbox_path);
    assert_eq!(pending.len(), 1);
    assert_eq!(pending[0].state, State::Held, "older daemons must never execute the lookup");
    assert!(pending[0].request.get("prompt").is_none(), "lookup keeps no executable prompt");
    let auth_dir = dir.join("peer-auth");
    let auth = crate::server::peer_auth::PeerAuth::create(&auth_dir).unwrap();
    let token = std::fs::read_to_string(crate::server::peer_auth::token_path(&auth_dir)).unwrap();
    let listener = bind_ws("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(serve_ws_with(
        remote.clone(),
        listener,
        "test".into(),
        WsAuth { local_app: None, peer: Some(Arc::new(auth)) },
    ));
    restarted
        .add_peer(
            "remote",
            &format!("ws://127.0.0.1:{port}"),
            Some("test".into()),
            Some(token),
            true,
        )
        .await
        .unwrap();
    resume(&restarted, pending);
    let loading = restarted.clone();
    tokio::spawn(async move { loading.load_store_async().await });
    let done = outbox_status(&restarted, &intent_id, &json!({"waitMs": 10_000})).await.unwrap();
    assert_eq!(done["status"], "delivered", "{done}");
    let page = restarted
        .events_page(&sender.id, 0, None, 500, None, false, &EventFilter::parse(None).unwrap())
        .unwrap();
    let messages: Vec<_> = page.events.iter().filter(|r| r.kind == "_acpmux/message").collect();
    assert_eq!(messages.len(), 1);
    assert_eq!(
        messages[0].msg,
        json!({"sessionId": sender.id, "sender": sender_meta,
            "text": "already accepted", "messageId": "d-restart", "at": 1234,
            "_acpmuxTarget": receiver.id, "_acpmuxTargetPeer": "remote"})
    );
    assert_eq!(receiver.meta().event_count, before, "recovery must never send the prompt again");
    std::fs::remove_dir_all(&dir).unwrap();
}
