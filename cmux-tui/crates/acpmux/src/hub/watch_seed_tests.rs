//! Failure-injection coverage for the first watched Claude page's durable native-history marker.
use super::*;
use crate::config::{Config, StoreMode};
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};
use anyhow::Result;
use std::sync::atomic::{AtomicBool, Ordering};

#[derive(Default)]
struct Faults {
    marker: AtomicBool,
    flush: AtomicBool,
    save: AtomicBool,
}

/// Each failure happens once. Forward all other calls to the actual memory store.
struct SeedStore {
    memory: MemoryStore,
    faults: Arc<Faults>,
}

impl Store for SeedStore {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.memory.list()
    }

    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.memory.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        if self.faults.save.swap(false, Ordering::SeqCst) {
            anyhow::bail!("injected metadata-save failure");
        }
        self.memory.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        if record.kind == "native_history" && self.faults.marker.swap(false, Ordering::SeqCst) {
            anyhow::bail!("injected native_history append failure");
        }
        self.memory.append(id, record)
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        if self.faults.flush.swap(false, Ordering::SeqCst) {
            anyhow::bail!("injected journal fsync failure");
        }
        self.memory.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.memory.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.memory.delete(id)
    }
}

fn persisted_offset(hub: &Hub, session: &Session) -> u64 {
    hub.store.load(&session.id).unwrap().unwrap().watching.unwrap().offset
}

fn markers(hub: &Hub, session: &Session) -> usize {
    hub.store
        .events(&session.id, 0, usize::MAX)
        .unwrap()
        .iter()
        .filter(|record| record.kind == "native_history")
        .count()
}

/// The marker, its file-system sync and its metadata checkpoint are one ordered
/// operation. Retry after any failure and restart without duplicating the seed.
#[tokio::test]
async fn native_history_seed_survives_append_flush_and_checkpoint_failures() {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let faults = Arc::new(Faults::default());
    let store = Box::new(SeedStore { memory: MemoryStore::default(), faults: faults.clone() });
    let hub = Hub::new(cfg, store);
    let session = hub
        .new_session(crate::hub::NewRequest {
            cwd: Some(std::env::temp_dir()),
            ..Default::default()
        })
        .await
        .unwrap();
    {
        let mut meta = session.meta.lock().unwrap();
        meta.watching = Some(Watching {
            family: "claude".to_owned(),
            file: std::env::temp_dir().join("test-native-history-seed.jsonl"),
            offset: 0,
            codex_items: false,
            open: None,
        });
    }
    hub.save_meta(&session);
    let (before, mark) = (1024, "v1:3:5:2048:512:sha".to_owned());

    // A lost journal append is never followed by a saved nonzero source cursor.
    faults.marker.store(true, Ordering::SeqCst);
    assert!(!hub.commit_watch_page(&session, before, mark.clone()).await);
    assert_eq!(session.meta().watching.unwrap().offset, 0);
    assert_eq!(persisted_offset(&hub, &session), 0);
    assert_eq!(markers(&hub, &session), 0);

    // The append succeeded but fsync refused: leave the cursor unchanged.
    faults.flush.store(true, Ordering::SeqCst);
    assert!(!hub.commit_watch_page(&session, before, mark.clone()).await);
    assert_eq!(persisted_offset(&hub, &session), 0);
    assert_eq!(markers(&hub, &session), 1);

    // The marker is already present and sync succeeds, but metadata save fails.
    faults.save.store(true, Ordering::SeqCst);
    assert!(!hub.commit_watch_page(&session, before, mark.clone()).await);
    assert_eq!(persisted_offset(&hub, &session), 0);
    assert_eq!(markers(&hub, &session), 1);

    // Simulate process restart: the persistent metadata still says offset zero.
    // The next seed must reuse the existing marker and finish the checkpoint.
    let stored = hub.store.load(&session.id).unwrap().unwrap();
    session.meta.lock().unwrap().watching = stored.watching;
    assert!(hub.commit_watch_page(&session, before, mark).await);
    assert_eq!(persisted_offset(&hub, &session), before);
    assert_eq!(markers(&hub, &session), 1, "seed marker was duplicated on retry");
    hub.shutdown_all().await;
}
