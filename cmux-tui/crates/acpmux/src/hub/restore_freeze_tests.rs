//! A chat whose log can not be read at load stays frozen (`queue.rs` `restore_queue`).

use super::*;

/// A memory store whose event reads fail once `unreadable` is set.
struct UnreadableStore {
    inner: Box<dyn Store>,
    unreadable: Arc<AtomicBool>,
}

impl Store for UnreadableStore {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.inner.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        self.inner.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        anyhow::ensure!(!self.unreadable.load(Ordering::SeqCst), "log unreadable");
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

/// HQ#5075: a chat whose move began here and whose log can not be read when the daemon starts
/// again is not freed to take prompts: whether it moved is unknown, so it stays frozen.
#[test]
fn a_chat_whose_log_is_unreadable_at_load_stays_frozen() {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let unreadable = Arc::new(AtomicBool::new(false));
    let hub = Hub::new(config, Box::new(UnreadableStore { inner, unreadable: unreadable.clone() }));
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "unreadable-log", "name": "unreadable",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.append(&session, "mux", "transfer_out", json!({"transferId": "xfer"}));

    unreadable.store(true, Ordering::SeqCst);
    hub.restore_queue(&session);
    assert!(session.moving().is_some(), "an unreadable log freed a chat that may have moved");

    // A later load that reads the log restores exactly what it says.
    unreadable.store(false, Ordering::SeqCst);
    hub.restore_queue(&session);
    assert_eq!(session.moving().as_deref(), Some("xfer"));
}

/// The fail-closed mark is no move: no abort or commit names it (an abort would free the chat,
/// a commit would close it), and the watchdog never watches it.
#[tokio::test]
async fn the_unreadable_log_mark_is_no_move_to_end_or_watch() {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let inner = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let unreadable = Arc::new(AtomicBool::new(false));
    let hub = Arc::new(Hub::new(
        config,
        Box::new(UnreadableStore { inner, unreadable: unreadable.clone() }),
    ));
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "unreadable-mark", "name": "mark",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(session.id.clone(), session.clone());
    unreadable.store(true, Ordering::SeqCst);
    hub.restore_queue(&session);
    let mark = session.moving().expect("frozen");
    assert!(!transfer_out::names_a_move(&mark), "the watchdog would watch {mark}");
    unreadable.store(false, Ordering::SeqCst);

    let named = json!({"sessionId": session.id, "transferId": mark});
    let aborted = hub.transfer_request("_acpmux/transfer_abort", &named).await;
    assert!(aborted.is_err(), "an abort named the fail-closed mark: {aborted:?}");
    let committed = hub.transfer_request("_acpmux/transfer_commit", &named).await;
    assert!(committed.is_err(), "a commit named the fail-closed mark: {committed:?}");
    assert_eq!(session.moving().as_deref(), Some(mark.as_str()), "it unfroze");
    assert_ne!(session.status(), SessionStatus::Closed, "it closed");
    assert!(!transfer_out::names_a_move(transfer_out::MOVED_AWAY));
    assert!(transfer_out::names_a_move("01a18c4c-f606-71c1-89dd-58599de4cb0c"));
}

/// A chat attached with `waitLogs:false` can answer before its background log restore. Once the
/// queue is rebuilt, one queue snapshot wakes that attachment; restoring the same log again emits
/// no duplicate snapshot.
#[test]
fn restoring_a_queue_publishes_one_snapshot_for_an_early_attach() {
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "early-attach", "name": "early",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    hub.append(
        &session,
        "mux",
        "queued",
        json!({
            "promptId": "p1", "turnId": "t1", "text": "queued after restart", "client": "acpmux"
        }),
    );
    hub.append(&session, "mux", "queue_paused", json!({"held": ["p1"]}));
    assert_eq!(hub.session_summary(&session)["queued"], 0, "early attach sees no queue");
    let before_restore = session.seq.load(Ordering::SeqCst);
    let mut events = hub.subscribe();
    hub.restore_queue(&session);
    let event = events.try_recv().expect("restore publishes the queue snapshot");
    assert_eq!(event.record.kind, "queue_restored");
    assert!(event.record.seq > before_restore);
    assert!(event.record.msg.get("order").is_none(), "a notice must not replay stale order");
    assert_eq!(hub.session_summary(&session)["queued"], 1);
    assert_eq!(hub.session_summary(&session)["queue"][0]["promptId"], "p1");
    assert!(session.queue()[0].held, "the restored held prompt remains held");
    let mut snapshots = Vec::new();
    hub.store
        .scan_kinds(&session.id, &["queue_restored"], &mut |event| {
            snapshots.push(event.msg);
            true
        })
        .unwrap();
    assert_eq!(snapshots.len(), 1);
    assert!(snapshots[0].get("order").is_none());
    hub.restore_queue(&session);
    let mut count = 0;
    hub.store
        .scan_kinds(&session.id, &["queue_restored"], &mut |_| {
            count += 1;
            true
        })
        .unwrap();
    assert_eq!(count, 1);
}
