//! An explicit shutdown stops provider retries chat by chat, and each stop reads the chat's log
//! back to its last turn boundary, synchronously (`shutdown.rs` `shutdown_sessions`). On a large
//! store that pass took minutes, nothing yielded, and the daemon's own shutdown deadline could not
//! end it: a NIGHTLY daemon sat with its lock held and its socket already removed (2026-11-02).

use super::*;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};
use anyhow::Result;
use std::time::{Duration, Instant};

/// A memory store whose backward scans take `SCAN` each, as a large log on disk does.
struct SlowScan(MemoryStore);

const SCAN: Duration = Duration::from_millis(200);

impl Store for SlowScan {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> Result<()> {
        self.0.append(id, record)
    }
    fn flush_session(&self, id: &str) -> Result<()> {
        self.0.flush_session(id)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.0.delete(id)
    }
    fn scan_back(
        &self,
        id: &str,
        after: u64,
        before: u64,
        skip: &dyn Fn(&[u8], &[u8]) -> bool,
        visit: &mut dyn FnMut(EventRecord) -> bool,
    ) -> Result<()> {
        std::thread::sleep(SCAN);
        self.0.scan_back(id, after, before, skip, visit)
    }
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "idle chat", "harness": "codex",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

/// Twenty chats whose stops take 200 ms each would hold the shutdown 4 s: it ends within the
/// daemon's shutdown budget instead.
#[tokio::test]
async fn an_explicit_shutdown_ends_within_its_budget_however_slow_the_retry_scans() {
    let mut cfg: crate::config::Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let hub = Hub::new(cfg, Box::new(SlowScan(MemoryStore::default())));
    for i in 0..20 {
        hub.insert_test_session(meta(&format!("chat-{i}")));
    }
    let started = Instant::now();
    hub.shutdown_all().await;
    let took = started.elapsed();
    assert!(took < Duration::from_secs(3), "the shutdown took {took:?}");
}
