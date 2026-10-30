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
