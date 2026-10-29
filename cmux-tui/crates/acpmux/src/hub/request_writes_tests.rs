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
    assert_eq!(answer(ok(), true, false).unwrap(), json!({"stopReason": "end_turn"}));
    assert_eq!(answer(ok(), true, true).unwrap(), json!({"stopReason": "end_turn"}));
    // Not saved: an error with its reason...
    let e = answer(ok(), false, false).unwrap_err();
    assert_eq!(e.data, Some(json!({"reason": "log.failed"})));
    // ...but a request that committed work a retry would redo keeps its Ok, marked.
    let v = answer(ok(), false, true).unwrap();
    assert_eq!(v["_meta"]["acpmux"]["saved"], false, "{v}");
    assert_eq!(v["stopReason"], "end_turn");
    let marked = answer(Ok(json!({"_meta": {"acpmux": {"turnId": "t"}}})), false, true).unwrap();
    assert_eq!(marked, json!({"_meta": {"acpmux": {"turnId": "t", "saved": false}}}));
    assert_eq!(answer(Ok(json!(null)), false, true).unwrap(), json!(null));
    // An error stays the handler's error.
    let refused = answer(Err(RpcError::invalid_params("bad")), false, true).unwrap_err();
    assert_eq!(refused.data, None);
}

/// Second review, item 3: whether a request keeps its Ok comes from what it committed, not its
/// method name, so every entrypoint that accepts a prompt or makes a session behaves the same.
#[tokio::test]
async fn request_writes_kept_is_noted_on_the_requests_task_only() {
    let ((), writes) = scope(Box::pin(async {})).await;
    assert!(!writes.kept());
    let ((), writes) = scope(Box::pin(async {
        // A prompt accepted on a spawned task is not this request's: its handler notes it.
        tokio::spawn(async { note_kept() }).await.unwrap();
    }))
    .await;
    assert!(!writes.kept());
    let ((), writes) = scope(Box::pin(async { note_kept() })).await;
    assert!(writes.kept());
}

/// A bookkeeping append through `unnoted` is neither noted nor marks the request failed, and
/// the request's own notes around it stay.
#[tokio::test]
async fn request_writes_unnoted_bookkeeping_leaves_the_requests_notes() {
    let ((), writes) = scope(Box::pin(async {
        note_log("a", 2);
        unnoted(|| {
            note_log("b", 5);
            note_failed();
        });
        note_log("a", 3);
    }))
    .await;
    assert_eq!(writes.logs.get("a"), Some(&3));
    assert_eq!(writes.logs.get("b"), None);
    assert!(!writes.failed);
}

/// Second review, item 4: showing an unread chat (`_acpmux/attach` visible, `_acpmux/view`)
/// logs its seen mark for the clients; that is bookkeeping, not what the answer acknowledges,
/// and must not make the chat switch wait for a log write.
#[tokio::test]
async fn request_writes_showing_an_unread_chat_is_not_waited_for() {
    let hub = hub_on(Box::new(MemoryStore::default()));
    let session = chat(&hub, "s1");
    // `_acpmux/attach` with `visible`, then `_acpmux/view`.
    for view in [false, true] {
        session.meta.lock().unwrap().unread = true;
        let before = session.seq.load(Ordering::SeqCst);
        let ((), writes) = scope(Box::pin(async {
            if view {
                hub.set_visible(&session, true);
            } else {
                hub.attach_count(&session, 1, true);
            }
        }))
        .await;
        assert!(session.seq.load(Ordering::SeqCst) > before, "the seen mark is logged");
        assert!(writes.logs.is_empty(), "a seen mark made the answer wait: {writes:?}");
    }
}

/// A store whose log progress the test holds: queued and not written until the test says.
struct HeldStore {
    inner: MemoryStore,
    progress: Arc<std::sync::Mutex<Option<tokio::sync::watch::Sender<crate::store::Progress>>>>,
}

impl Store for HeldStore {
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
        self.inner.events(id, after, limit)
    }
    fn progress(&self, _id: &str) -> Option<tokio::sync::watch::Receiver<crate::store::Progress>> {
        self.progress.lock().unwrap().as_ref().map(tokio::sync::watch::Sender::subscribe)
    }
    fn delete(&self, id: &str) -> anyhow::Result<()> {
        self.inner.delete(id)
    }
}

/// Waits for a request's write while the store forgets the log (its session deleted): the
/// answer is `saved` when the session is `deleted`, and not saved when it still exists.
async fn wait_while_the_log_is_forgotten(deleted: bool) -> bool {
    let progress = crate::store::Progress { queued: 100, written: 0, failed: false };
    let held = Arc::new(std::sync::Mutex::new(Some(tokio::sync::watch::channel(progress).0)));
    let hub = hub_on(Box::new(HeldStore { inner: MemoryStore::default(), progress: held.clone() }));
    let session = chat(&hub, "s1");
    let ((), writes) = scope(Box::pin(async {
        hub.append(&session, "mux", "queue_order", json!({"order": []}));
    }))
    .await;
    assert!(!writes.logs.is_empty());
    if deleted {
        session.purged.store(true, Ordering::SeqCst);
        hub.sessions.lock().unwrap().remove("s1");
    }
    let waiting = tokio::spawn({
        let hub = hub.clone();
        async move { hub.wait_written(writes).await }
    });
    // The wait subscribes to the log's progress before the store forgets it.
    while held.lock().unwrap().as_ref().is_some_and(|tx| tx.receiver_count() == 0) {
        tokio::task::yield_now().await;
    }
    held.lock().unwrap().take();
    waiting.await.unwrap()
}

/// Second review, item 5: a request whose session is deleted while it waits answered a false
/// `log.failed` (its log's progress closed). Nothing of a deleted session is kept.
#[tokio::test]
async fn request_writes_a_session_deleted_while_waiting_is_not_a_failed_log() {
    assert!(wait_while_the_log_is_forgotten(true).await, "a deleted chat answered log.failed");
    assert!(!wait_while_the_log_is_forgotten(false).await, "a live chat's lost log was saved");
}
