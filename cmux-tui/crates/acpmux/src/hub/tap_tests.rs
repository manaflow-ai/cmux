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
        move || tap(Direction::In, &Message::Notification { method: "x/y".into(), params: None }, Some(1))
    });
    // Test-only fixed wait: the tap has started and waits for the append lock.
    std::thread::sleep(std::time::Duration::from_millis(200));
    // Another task's append of this session failed meanwhile.
    session.append_errors.fetch_add(1, Ordering::SeqCst);
    drop(held);
    assert!(entry.join().unwrap(), "a failure of another record marked this stored entry unlogged");
}
