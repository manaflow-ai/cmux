use super::*;
use crate::config::{Config, PermissionPolicy, StoreMode};
use crate::hub::NewRequest;
use serde_json::json;
use std::path::Path;

fn message_count(hub: &Hub, id: &str) -> usize {
    let filter = EventFilter::parse(None).expect("event filter");
    hub.events_page(id, 0, None, 500, None, false, &filter)
        .expect("event page")
        .events
        .into_iter()
        .filter(|record| record.kind == "_acpmux/message")
        .count()
}

/// A queued prompt can be durable before its acceptance callback runs. A
/// later log load reconstructs both projections and remains idempotent.
#[tokio::test]
async fn queued_message_recovery_rebuilds_both_journals_once() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(config, store);
    let make = |name: &str| NewRequest {
        harness: Some("fake".into()),
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        policy: Some(PermissionPolicy::ApproveAll),
        ..NewRequest::default()
    };
    let sender = hub.new_session(make("sender")).await.expect("sender");
    let receiver = hub.new_session(make("receiver")).await.expect("receiver");
    let sender_id = sender.id.clone();
    let receiver_id = receiver.id.clone();
    let provenance = json!({
        "kind": "session_message",
        "from": sender_id,
        "fromName": "sender",
        "to": receiver_id,
        "_acpmuxMessage": {
            "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
            "text": "queued hello",
            "messageId": "delivery-1",
            "at": 1234,
            "recordSenderCopy": true
        }
    });
    hub.append(
            &receiver,
            "mux",
            "queued",
            json!({"promptId": "p-1", "turnId": "t-1", "text": "queued hello", "_meta": {"provenance": provenance}}),
        );

    let sender_updated = sender.meta().updated_at;
    let receiver_updated = receiver.meta().updated_at;
    recover_message_events(&hub, &receiver);
    recover_message_events(&hub, &receiver);
    assert_eq!(message_count(&hub, &receiver_id), 1);
    assert_eq!(message_count(&hub, &sender_id), 1);
    assert!(sender.meta().updated_at >= sender_updated);
    assert!(receiver.meta().updated_at >= receiver_updated);
}

#[tokio::test]
async fn digest_message_recovery_rebuilds_nested_projection_once() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(config, store);
    let make = |name: &str| NewRequest {
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        policy: Some(PermissionPolicy::ApproveAll),
        ..NewRequest::default()
    };
    let sender = hub.new_session(make("sender")).await.expect("sender");
    let receiver = hub.new_session(make("receiver")).await.expect("receiver");
    let sender_id = sender.id.clone();
    let receiver_id = receiver.id.clone();
    let original = json!({
        "kind": "session_message",
        "from": sender_id,
        "fromName": "sender",
        "to": receiver_id,
        "_acpmuxMessage": {
            "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
            "text": "joined hello",
            "messageId": "digest-delivery-1",
            "at": 1234,
            "recordSenderCopy": true
        }
    });
    let digest = json!({
        "kind": "agent_digest",
        "messages": [{"promptId": "joined-prompt", "from": "sender", "provenance": original}]
    });
    // A started digest has no queued record; its user_message is the only durable recovery
    // source when the daemon stops before the acceptance callback writes projections.
    hub.append(
        &receiver,
        "mux",
        "user_message",
        json!({"promptId": "digest-prompt", "_meta": {"provenance": digest}}),
    );

    recover_message_events(&hub, &receiver);
    recover_message_events(&hub, &receiver);
    assert_eq!(message_count(&hub, &receiver_id), 1);
    assert_eq!(message_count(&hub, &sender_id), 1);
}

#[tokio::test]
async fn sender_copies_with_same_prompt_id_keep_distinct_targets_and_peers() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake", "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(config, store);
    let sender = hub
        .new_session(NewRequest {
            name: Some("sender".into()),
            cwd: Some(std::env::temp_dir()),
            ..NewRequest::default()
        })
        .await
        .expect("sender");
    let sender_id = sender.id.clone();
    let sender_meta = json!({"name": "sender", "sessionId": sender_id});
    assert!(hub.append_message_event_scoped(
        &sender,
        sender_meta.clone(),
        "to b".into(),
        "same-prompt".into(),
        1,
        Some("b"),
        None
    ));
    assert!(hub.append_message_event_scoped(
        &sender,
        sender_meta.clone(),
        "to c".into(),
        "same-prompt".into(),
        2,
        Some("c"),
        None
    ));
    assert_eq!(message_count(&hub, &sender.id), 2);
    // A peer's chat keeps the raw id of one here after an export and import: a send to each
    // is its own copy, and each copy is kept once.
    for (at, peer) in [(3, Some("remote")), (4, Some("remote")), (5, Some("other")), (6, None)] {
        assert!(hub.append_message_event_scoped(
            &sender,
            sender_meta.clone(),
            "to b".into(),
            "same-prompt".into(),
            at,
            Some("b"),
            peer
        ));
    }
    assert_eq!(message_count(&hub, &sender.id), 4);
    // The index a restart rebuilds from the journal keeps the peer apart too.
    *sender.message_ids.lock().unwrap() = None;
    for peer in [Some("remote"), Some("other"), None] {
        assert!(hub.append_message_event_scoped(
            &sender,
            sender_meta.clone(),
            "to b".into(),
            "same-prompt".into(),
            7,
            Some("b"),
            peer
        ));
    }
    assert_eq!(message_count(&hub, &sender.id), 4);
}

#[tokio::test]
async fn sender_projection_repairs_without_resending_after_a_transient_failure() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(config, store);
    let make = |name: &str| NewRequest {
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        policy: Some(PermissionPolicy::ApproveAll),
        ..NewRequest::default()
    };
    let sender = hub.new_session(make("sender")).await.expect("sender");
    let receiver = hub.new_session(make("receiver")).await.expect("receiver");
    let sender_id = sender.id.clone();
    let receiver_id = receiver.id.clone();
    let message = MessageContext {
        sender: json!({"name": "sender", "sessionId": sender_id, "host": "local"}),
        sender_session: sender.id.clone(),
        text: "repair me".into(),
        message_id: "repair-delivery-1".into(),
        at: 1234,
        record_sender_copy: true,
    };

    // Inject one sender-store failure. The bounded repair retries the same projection without
    // invoking prompt delivery.
    hub.message_projection_failures.lock().unwrap().insert(sender.id.clone());
    let mut events = hub.subscribe();
    record_message_context(&hub, &receiver_id, &message);
    assert_eq!(message_count(&hub, &receiver_id), 1);
    assert_eq!(message_count(&hub, &sender_id), 0);
    tokio::time::timeout(std::time::Duration::from_secs(4), async {
        loop {
            let event = events.recv().await.expect("hub event");
            if event.session_id == sender_id
                && event.record.kind == "_acpmux/message"
                && event.record.msg["messageId"] == "repair-delivery-1"
                && message_count(&hub, &sender_id) == 1
            {
                break;
            }
        }
    })
    .await
    .expect("sender projection repair timed out");
    assert_eq!(message_count(&hub, &sender_id), 1);
}

#[tokio::test]
async fn forked_historical_user_messages_do_not_recreate_sender_copies() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    let hub = Hub::new(config, store);
    let make = |name: &str| NewRequest {
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        policy: Some(PermissionPolicy::ApproveAll),
        ..NewRequest::default()
    };
    let sender = hub.new_session(make("sender")).await.expect("sender");
    let child = hub.new_session(make("child")).await.expect("child");
    child.meta.lock().unwrap().parent_id = Some("parent".into());
    child.meta.lock().unwrap().fork_seq = Some(1);
    let provenance = json!({
        "kind": "session_message",
        "from": sender.id,
        "fromName": "sender",
        "to": child.id,
        "_acpmuxMessage": {
            "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
            "text": "inherited",
            "messageId": "historical-delivery",
            "at": 1234,
            "recordSenderCopy": true
        }
    });
    hub.append(
        &child,
        "mux",
        "user_message",
        json!({"promptId": "historical", "_meta": {"provenance": provenance.clone()}}),
    );
    hub.append(&child, "mux", "forked", json!({"parentId": "parent", "forkSeq": 1}));
    recover_message_events(&hub, &child);
    assert_eq!(message_count(&hub, &child.id), 0);
    assert_eq!(message_count(&hub, &sender.id), 0);

    // New child traffic after the fork marker remains recoverable and gets both projections.
    hub.append(
        &child,
        "mux",
        "user_message",
        json!({"promptId": "current", "_meta": {"provenance": provenance}}),
    );
    recover_message_events(&hub, &child);
    assert_eq!(message_count(&hub, &child.id), 1);
    assert_eq!(message_count(&hub, &sender.id), 1);
}

/// The memory store, whose next `fail` appends of a `_acpmux/message` record fail as a
/// full or unwritable disk would.
struct RefusingStore {
    inner: Box<dyn crate::store::Store>,
    fail: std::sync::atomic::AtomicUsize,
}

impl crate::store::Store for RefusingStore {
    fn list(&self) -> anyhow::Result<Vec<crate::store::SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<crate::store::SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &crate::store::SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &crate::store::EventRecord) -> anyhow::Result<()> {
        use std::sync::atomic::Ordering::SeqCst;
        if record.kind == "_acpmux/message"
            && self.fail.fetch_update(SeqCst, SeqCst, |n| n.checked_sub(1)).is_ok()
        {
            anyhow::bail!("no space left on device");
        }
        self.inner.append(id, record)
    }
    fn events(
        &self,
        id: &str,
        after: u64,
        limit: usize,
    ) -> anyhow::Result<Vec<crate::store::EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

/// A copy the store refused is not published: the one copy clients and peers hear is the
/// one the journal holds, under its own seq, after the append is retried.
#[tokio::test]
async fn a_message_copy_the_store_refuses_is_never_published() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let inner = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    let store = RefusingStore { inner, fail: std::sync::atomic::AtomicUsize::new(1) };
    let hub = Hub::new(config, Box::new(store));
    let receiver = hub
        .new_session(NewRequest {
            name: Some("receiver".into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        })
        .await
        .expect("receiver");
    let mut events = hub.subscribe();
    let sender = json!({"name": "sender", "sessionId": "sender-1", "host": "local"});
    let send = || {
        hub.append_message_event(
            &receiver,
            sender.clone(),
            "once".into(),
            "delivery-1".into(),
            1234,
        )
    };
    assert!(!send(), "the store refused the first copy");
    assert!(send(), "the retry is stored");
    assert!(send(), "a third append finds the stored copy");
    let mut heard = Vec::new();
    while let Ok(event) = events.try_recv() {
        if event.session_id == receiver.id && event.record.kind == "_acpmux/message" {
            heard.push(event.record.seq);
        }
    }
    assert_eq!(message_count(&hub, &receiver.id), 1);
    let stored = hub
        .events_page(&receiver.id, 0, None, 500, None, false, &EventFilter::parse(None).unwrap())
        .expect("event page")
        .events
        .into_iter()
        .find(|record| record.kind == "_acpmux/message")
        .expect("stored copy")
        .seq;
    assert_eq!(heard, vec![stored], "only the stored copy is published");
}

/// A lazy load of the receiver recovers its message before the store's load installs the
/// sender: the sender's copy is appended once the sender is read, not dropped.
#[tokio::test]
async fn recovery_before_the_sender_loads_still_records_its_copy() {
    let dir = std::env::temp_dir().join(format!("message-late-sender-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Local;
    let original = Hub::new(config.clone(), crate::store::open(&config.store, &dir).unwrap());
    let sender = original
        .new_session(NewRequest {
            name: Some("sender".into()),
            cwd: Some(std::env::temp_dir()),
            policy: Some(PermissionPolicy::ApproveAll),
            ..NewRequest::default()
        })
        .await
        .expect("sender");
    let sender_id = sender.id.clone();
    original.detach_child(&sender).await;
    original.store.flush().unwrap();
    // The first daemon's shutdown seal: the journal's lock passes to the restarted one.
    original.seal();
    // The restarted daemon has not read its saved sessions yet.
    let restarted = Hub::new_loading(
        config.clone(),
        crate::store::open(&config.store, &dir).unwrap(),
        crate::mailbox::Mailbox::open(dir.join("mailbox")).unwrap(),
    );
    assert!(resolve_exact(&restarted, &sender_id).is_none());
    let message = MessageContext {
        sender: json!({"name": "sender", "sessionId": sender_id, "host": "local"}),
        sender_session: sender_id.clone(),
        text: "late".into(),
        message_id: "late-delivery-1".into(),
        at: 1234,
        record_sender_copy: true,
    };
    let mut events = restarted.subscribe();
    append_or_repair(&restarted, &sender_id, &message, Some("receiver-1"));
    tokio::time::timeout(std::time::Duration::from_secs(10), async {
        loop {
            let event = events.recv().await.expect("hub event");
            if event.session_id == sender_id
                && event.record.kind == "_acpmux/message"
                && event.record.msg["messageId"] == "late-delivery-1"
            {
                break;
            }
        }
    })
    .await
    .expect("the sender's copy is appended once it loads");
    assert_eq!(message_count(&restarted, &sender_id), 1);
    std::fs::remove_dir_all(&dir).ok();
}

fn memory_hub() -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all"
    }))
    .expect("config");
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/nonexistent")).expect("store");
    Hub::new(config, store)
}

async fn session(hub: &Arc<Hub>, name: &str) -> Arc<Session> {
    hub.new_session(NewRequest {
        name: Some(name.into()),
        cwd: Some(std::env::temp_dir()),
        policy: Some(PermissionPolicy::ApproveAll),
        ..NewRequest::default()
    })
    .await
    .expect("session")
}

/// A record addressed to another session (a fork's inherited prefix, after an import
/// dropped its marker) recreates no copy; one addressed to this session does.
#[tokio::test]
async fn a_record_addressed_to_another_session_recreates_no_copy() {
    let hub = memory_hub();
    let sender = session(&hub, "sender").await;
    let imported = session(&hub, "imported").await;
    let record = |to: &str, id: &str| {
        json!({"promptId": id, "_meta": {"provenance": {
            "kind": "session_message", "from": sender.id, "fromName": "sender", "to": to,
            "_acpmuxMessage": {
                "sender": {"name": "sender", "sessionId": sender.id, "host": "local"},
                "text": "hello", "messageId": id, "at": 1234, "recordSenderCopy": true
            }
        }}})
    };
    let original_receiver = uuid::Uuid::now_v7().to_string();
    hub.append(&imported, "mux", "user_message", record(&original_receiver, "inherited"));
    hub.append(
        &imported,
        "mux",
        "user_message",
        record(&format!("acp:{original_receiver}"), "inherited-2"),
    );
    // Addressed by name, as a local provenance may be: the copy's receiver id says whose.
    let mut named = record("receiver", "inherited-named");
    named["_meta"]["provenance"]["_acpmuxMessage"]["receiverId"] = json!(original_receiver);
    hub.append(&imported, "mux", "user_message", named);
    recover_message_events(&hub, &imported);
    assert_eq!(message_count(&hub, &imported.id), 0);
    assert_eq!(message_count(&hub, &sender.id), 0);
    hub.append(&imported, "mux", "user_message", record(&imported.id, "own"));
    recover_message_events(&hub, &imported);
    assert_eq!(message_count(&hub, &imported.id), 1);
    assert_eq!(message_count(&hub, &sender.id), 1);
}

/// A person's or terminal's message (`from: "cli"`, `"term_1234"`) is no session's message;
/// an agent's (`acp:<id>`) is.
#[tokio::test]
async fn only_a_session_sender_makes_a_session_message() {
    let hub = memory_hub();
    let receiver = session(&hub, "receiver").await;
    let agent = session(&hub, "agent").await;
    let context = |from: &str| {
        let opts = PromptOptions {
            provenance: Some(json!({"kind": "agent_message", "from": from,
                    "fromName": "someone", "to": format!("acp:{}", receiver.id),
                    "msgId": "m", "threadId": "t"})),
            ..PromptOptions::default()
        };
        message_context(&hub, &receiver, &[json!({"type": "text", "text": "hi"})], &opts, "p")
    };
    assert!(context("cli").is_none());
    assert!(context("term_1234").is_none());
    let from_agent = context(&format!("acp:{}", agent.id)).expect("an agent's message");
    assert_eq!(from_agent.sender_session, agent.id);
}
