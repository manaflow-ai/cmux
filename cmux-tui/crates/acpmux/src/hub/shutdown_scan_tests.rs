//! An explicit shutdown stops provider retries chat by chat, and each stop reads the chat's log
//! back to its last turn boundary, synchronously (`shutdown.rs` `shutdown_sessions`). On a large
//! store that pass took minutes, nothing yielded, and the daemon's own shutdown deadline could not
//! end it: a NIGHTLY daemon sat with its lock held and its socket already removed (2026-11-02).

use super::*;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};
use anyhow::Result;
use std::time::{Duration, Instant};

/// A memory store whose backward scans pass `LINES` lines of a large log first, `LINE` each, as
/// a file store reads them: each line goes through `skip`, so a scan can be cut short.
struct SlowScan(MemoryStore);

const LINES: usize = 80;
const LINE: Duration = Duration::from_millis(50);

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
        for seq in (1..=LINES as u64).rev() {
            std::thread::sleep(LINE);
            if skip(b"in", b"agent_message_chunk") {
                continue;
            }
            let record = EventRecord {
                seq,
                at: seq,
                dir: "in".into(),
                kind: "agent_message_chunk".into(),
                msg: json!({}),
                host_seq: None,
            };
            if !visit(record) {
                return Ok(());
            }
        }
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

/// Twenty chats whose stops each read 4 s of log would hold the shutdown 80 s, and one alone 4 s:
/// it ends within the daemon's shutdown budget instead.
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
