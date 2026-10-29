//! What a request wrote is noted on its own task only, and a failed log is never answered as
//! saved (`cargo test -p acpmux request_writes`).

use std::sync::Arc;

use super::*;
use crate::store::{EventRecord, MemoryStore, SessionMeta, Store};

#[tokio::test]
async fn request_writes_notes_the_last_record_of_each_log_on_its_task() {
    let ((), writes) = scope(Box::pin(async {
        note_log("a", 3);
        note_log("a", 7);
        note_log("a", 5);
        note_log("b", 1);
        // Another task's writes are not this request's.
        tokio::spawn(async { note_log("c", 9) }).await.unwrap();
    }))
    .await;
    assert_eq!(writes.logs.get("a"), Some(&7));
    assert_eq!(writes.logs.get("b"), Some(&1));
    assert_eq!(writes.logs.get("c"), None);
    assert!(!writes.failed);
}

#[tokio::test]
async fn request_writes_outside_a_request_notes_nothing() {
    // Notes made with no request on the task are dropped, not kept for a later request.
    note_log("a", 1);
    note_failed();
    let ((), writes) = scope(Box::pin(async {})).await;
    assert!(writes.logs.is_empty(), "{writes:?}");
    assert!(!writes.failed, "{writes:?}");
}

/// A store whose appends all fail, as a log that failed refuses every later record.
struct FailingStore(MemoryStore);

impl Store for FailingStore {
    fn list(&self) -> anyhow::Result<Vec<SessionMeta>> {
        self.0.list()
    }
    fn load(&self, id: &str) -> anyhow::Result<Option<SessionMeta>> {
        self.0.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> anyhow::Result<()> {
        self.0.save(meta)
    }
    fn append(&self, _id: &str, _record: &EventRecord) -> anyhow::Result<()> {
        anyhow::bail!("the log failed")
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> anyhow::Result<Vec<EventRecord>> {
        self.0.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.0.delete(id)
    }
}

fn hub_on(store: Box<dyn Store>) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, store)
}

fn chat(hub: &Arc<Hub>, id: &str) -> Arc<Session> {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap();
    let session = hub.make_session(meta);
    hub.sessions.lock().unwrap().insert(id.to_owned(), session.clone());
    session
}

/// Review aa3529b1 item C: once a log failed, a later append fails in `append_at` and noted
/// nothing, so its request answered Ok with nothing saved. Now the request is not saved.
#[tokio::test]
async fn request_writes_a_failed_append_is_not_saved() {
    let hub = hub_on(Box::new(FailingStore(MemoryStore::default())));
    let session = chat(&hub, "s1");
    let ((), writes) = scope(Box::pin(async {
        hub.append(&session, "mux", "queue_order", json!({"order": []}));
    }))
    .await;
    assert!(writes.failed, "{writes:?}");
    assert!(!hub.wait_written(writes).await, "a failed append was answered as saved");
}

#[tokio::test]
async fn request_writes_a_stored_append_is_saved() {
    let hub = hub_on(Box::new(MemoryStore::default()));
    let session = chat(&hub, "s1");
    let ((), writes) = scope(Box::pin(async {
        hub.append(&session, "mux", "queue_order", json!({"order": []}));
    }))
    .await;
    assert_eq!(writes.logs.get("s1"), Some(&session.seq.load(Ordering::SeqCst)));
    assert!(hub.wait_written(writes).await);
}

/// Review aa3529b1 item B: a family prompt's records are appended on the turn's task; the
/// request notes the target session's records so far once the prompt is accepted.
#[tokio::test]
async fn request_writes_note_session_notes_records_another_task_appended() {
    let hub = hub_on(Box::new(MemoryStore::default()));
    let session = chat(&hub, "s1");
    let ((), writes) = scope(Box::pin(async {
        let (h, s) = (hub.clone(), session.clone());
        tokio::spawn(async move {
            h.append(&s, "mux", "queued", json!({}));
            h.append(&s, "mux", "queued", json!({}));
        })
        .await
        .unwrap();
        note_session(&session);
    }))
    .await;
    let last = session.seq.load(Ordering::SeqCst);
    assert!(last >= 2, "{last}");
    assert_eq!(writes.logs.get("s1"), Some(&last));
}

#[tokio::test]
async fn request_writes_a_decision_from_the_asking_task_is_noted() {
    let ((), writes) = scope(Box::pin(async {
        let (tx, rx) = oneshot::channel();
        let asker = tokio::spawn(async move { tx.send(Some(4)).unwrap() });
        note_decision("a", rx).await;
        asker.await.unwrap();
        // The asking task is gone: nothing to wait for, and no hang.
        let (tx, rx) = oneshot::channel::<Option<u64>>();
        drop(tx);
        note_decision("b", rx).await;
    }))
    .await;
    assert_eq!(writes.logs.get("a"), Some(&4));
    assert_eq!(writes.logs.get("b"), None);
    assert!(!writes.failed);
    let ((), writes) = scope(Box::pin(async {
        let (tx, rx) = oneshot::channel();
        tx.send(None).unwrap();
        note_decision("a", rx).await;
    }))
    .await;
    assert!(writes.failed, "a decision whose append failed was taken as saved");
}

#[test]
fn request_writes_an_unsaved_answer() {
    let ok = || Ok(json!({"stopReason": "end_turn"}));
    // Saved: the answer is the handler's.
    assert_eq!(
        answer("_acpmux/queue_edit", ok(), true).unwrap(),
        json!({"stopReason": "end_turn"})
    );
    // Not saved: an error with its reason...
    let e = answer("_acpmux/queue_edit", ok(), false).unwrap_err();
    assert_eq!(e.data, Some(json!({"reason": "log.failed"})));
    // ...but a prompt and a new session keep their Ok, marked.
    for name in [method::SESSION_PROMPT, method::SESSION_NEW] {
        let v = answer(name, ok(), false).unwrap();
        assert_eq!(v["_meta"]["acpmux"]["saved"], false, "{v}");
        assert_eq!(v["stopReason"], "end_turn");
    }
    let marked =
        answer(method::SESSION_PROMPT, Ok(json!({"_meta": {"acpmux": {"turnId": "t"}}})), false)
            .unwrap();
    assert_eq!(marked, json!({"_meta": {"acpmux": {"turnId": "t", "saved": false}}}));
    assert_eq!(answer(method::SESSION_NEW, Ok(json!(null)), false).unwrap(), json!(null));
    // An error stays the handler's error.
    let refused = answer("x", Err(RpcError::invalid_params("bad")), false).unwrap_err();
    assert_eq!(refused.data, None);
}
