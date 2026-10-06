//! The tap acknowledges a host entry only when that entry's own record is
//! stored: another task's append failure must not mark it unlogged (which
//! breaks the agent host link).

use super::*;
use crate::store::MemoryStore;

fn session(hub: &Arc<Hub>) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": "s1", "name": "s1", "harness": "fake", "cwd": "/tmp",
        "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .expect("session meta");
    hub.make_session(meta)
}

#[test]
fn another_tasks_append_failure_does_not_unlog_this_entry() {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let _guard = rt.enter();
    let hub = Hub::new(Config::default(), Box::new(MemoryStore::default()));
    let session = session(&hub);
    let tap = hub.session_tap(&session);
    let held = session.append_lock.lock().unwrap();
    let entry = std::thread::spawn({
        let tap = tap.clone();
        move || {
            tap(
                Direction::In,
                &Message::Notification { method: "x/y".into(), params: None },
                Some(1),
            )
        }
    });
    // Test-only fixed wait: the tap has started and waits for the append lock.
    std::thread::sleep(std::time::Duration::from_millis(200));
    // Another task's append of this session failed meanwhile.
    session.append_errors.fetch_add(1, Ordering::SeqCst);
    drop(held);
    assert!(entry.join().unwrap(), "a failure of another record marked this stored entry unlogged");
}

/// A store that refuses records of the method `fail/me`.
#[derive(Default)]
struct RefusingStore(MemoryStore);

impl Store for RefusingStore {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.0.save(meta)
    }
    fn append(&self, id: &str, record: &EventRecord) -> anyhow::Result<()> {
        if record.kind == "fail/me" {
            anyhow::bail!("refused");
        }
        self.0.append(id, record)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.0.delete(id)
    }
}

/// The entry's own record not stored: unlogged (the link must not ack it).
/// A purged session keeps nothing, so its entries count as handled.
#[test]
fn the_entrys_own_store_result_decides_and_a_purged_session_counts_as_stored() {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let _guard = rt.enter();
    let hub = Hub::new(Config::default(), Box::new(RefusingStore::default()));
    let session = session(&hub);
    let tap = hub.session_tap(&session);
    let entry = |method: &str| {
        tap(Direction::In, &Message::Notification { method: method.into(), params: None }, Some(1))
    };
    assert!(!entry("fail/me"), "a refused record was reported stored");
    assert!(entry("x/y"), "a stored record was reported unlogged");
    session.purged.store(true, Ordering::SeqCst);
    assert!(entry("fail/me"), "a purged session's entry was reported unlogged");
}
